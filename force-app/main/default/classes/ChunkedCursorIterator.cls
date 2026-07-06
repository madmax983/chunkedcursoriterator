/**
 * @description A unified, resilient, and serializable custom iterator for Salesforce Apex Cursors.
 * Supports both Database.Cursor (up to 50M rows) and Database.PaginationCursor (up to 100K rows).
 * Implements Iterable and Iterator for seamless use in for-each loops, queueables, and parallel workflows.
 */
public inherited sharing class ChunkedCursorIterator implements Iterable<List<SObject>>, Iterator<List<SObject>>, ChunkedCursorHelper.CursorFetcher {
  public enum CursorType {
    STANDARD,
    PAGINATION
  }

  /**
   * @description The type of database cursor selected (STANDARD or PAGINATION).
   */
  public CursorType selectedCursorType { get; private set; }
  /**
   * @description The current position pointer index.
   */
  public Integer position { get; private set; }
  /**
   * @description The size of each chunk.
   */
  public Integer chunkSize { get; private set; }
  /**
   * @description The total number of records matching the query.
   */
  public Integer totalRecords { get; private set; }

  // Active database cursor state (transient as cursor resources cannot span transactions/serialization)
  /**
   * @description The active standard Database.Cursor.
   */
  @TestVisible
  private transient Database.Cursor standardCursor { get; private set; }
  /**
   * @description The active Database.PaginationCursor.
   */
  @TestVisible
  private transient Database.PaginationCursor paginationCursor {
    get;
    private set;
  }
  @TestVisible
  private transient Integer nextPaginationIndex;

  // Iteration limits for partitioning
  private Integer maxIterations;
  private Integer iterationsRemaining;

  // Self-healing metadata (serialized to enable database-level recovery on deserialization/expiration)
  private String query;
  private Map<String, Object> bindMap;
  @TestVisible
  private transient System.AccessLevel operationAccessLevel {
    get {
      if (this.operationAccessLevel == null) {
        this.operationAccessLevel = ChunkedCursorOptions.resolveAccessLevel(
          this.accessLevelMode,
          this.permissionSetId
        );
      }
      return this.operationAccessLevel;
    }
    private set;
  }
  private String accessLevelMode;
  private String permissionSetId;

  // Type safety configuration (serialized as String to ensure lightweight and consistent serialization)
  private String sObjectTypeName;
  private transient System.Type resolvedListType {
    get {
      if (this.resolvedListType == null && this.sObjectTypeName != null) {
        this.resolvedListType = System.Type.forName(
          'List<' + this.sObjectTypeName + '>'
        );
      }
      return this.resolvedListType;
    }
    private set;
  }

  // ==========================================
  // Inner Classes (Configuration & State)
  // ==========================================

  /**
   * @description Private class to group parameters for partitioned iterator recreation.
   */
  private class PartitionParams {
    private CursorType selectedCursorType;
    private Integer position;
    private Integer chunkSize;
    private Integer totalRecords;
    private Integer maxIterations;
    private String query;
    private Map<String, Object> bindMap;
    private System.AccessLevel selectedAccessLevel;
    private String sObjectTypeName;
  }

  // ==========================================
  // Constructors
  // ==========================================

  /**
   * @description Simple constructor to initialize a standard cursor.
   * @param query The dynamic SOQL query string.
   * @param chunkSize The record count limit per chunk.
   */
  public ChunkedCursorIterator(String query, Integer chunkSize) {
    this(new ChunkedCursorOptions(query, chunkSize));
  }

  /**
   * @description Advanced constructor to initialize the cursor iterator with options.
   * @param options The configuration Options instance.
   */
  public ChunkedCursorIterator(ChunkedCursorOptions options) {
    if (options == null) {
      throw new System.IllegalArgumentException('Options cannot be null.');
    }
    this.query = options.query;
    this.bindMap = options.bindMap;
    this.chunkSize = options.chunkSize;
    this.operationAccessLevel = options.accessLevel;
    this.accessLevelMode = ChunkedCursorOptions.getAccessLevelMode(
      options.accessLevel
    );
    this.permissionSetId = ChunkedCursorOptions.extractPermissionSetId(
      options.accessLevel
    );
    this.selectedCursorType = options.selectedCursorType;
    this.sObjectTypeName = ChunkedCursorOptions.getSObjectTypeName(
      options.sObjectType
    );
    this.position = 0;

    initCursor();
  }

  /**
   * @description Private constructor to recreate/restore a partition or deserialized state.
   * @param params The partition/state parameters object.
   */
  private ChunkedCursorIterator(PartitionParams params) {
    this.selectedCursorType = params.selectedCursorType;
    this.standardCursor = null;
    this.paginationCursor = null;
    this.position = params.position;
    this.chunkSize = params.chunkSize;
    this.totalRecords = params.totalRecords;
    this.maxIterations = params.maxIterations;
    this.iterationsRemaining = params.maxIterations;
    this.query = params.query;
    this.bindMap = params.bindMap;
    this.operationAccessLevel = params.selectedAccessLevel;
    this.accessLevelMode = ChunkedCursorOptions.getAccessLevelMode(
      params.selectedAccessLevel
    );
    this.permissionSetId = ChunkedCursorOptions.extractPermissionSetId(
      params.selectedAccessLevel
    );
    this.sObjectTypeName = params.sObjectTypeName;
  }

  // ==========================================
  // Fluent Configuration & Helpers
  // ==========================================

  private void initCursor() {
    System.AccessLevel accessLevel = this.operationAccessLevel;
    if (this.selectedCursorType == CursorType.PAGINATION) {
      this.paginationCursor = ChunkedCursorHelper.createPaginationCursor(
        this.query,
        this.bindMap,
        accessLevel
      );
      this.totalRecords = this.paginationCursor.getNumRecords();
    } else {
      this.standardCursor = ChunkedCursorHelper.createStandardCursor(
        this.query,
        this.bindMap,
        accessLevel
      );
      this.totalRecords = this.standardCursor.getNumRecords();
    }
  }

  // ==========================================
  // Iterable & Iterator Interface Implementation
  // ==========================================

  /**
   * @description Returns the iterator instance.
   * @return The current ChunkedCursorIterator instance.
   */
  public Iterator<List<SObject>> iterator() {
    return this;
  }

  /**
   * @description Checks if there are more chunks of records to fetch.
   * @return True if there are remaining records and iteration limits allow, false otherwise.
   */
  public Boolean hasNext() {
    Boolean hasMore =
      (this.iterationsRemaining == null || this.iterationsRemaining > 0) &&
      this.position < this.totalRecords;
    if (!hasMore) {
      close();
    }
    return hasMore;
  }

  /**
   * @description Fetches the next chunk of records, healing the cursor if it has expired.
   * @return A list containing the next chunk of SObjects.
   */
  public List<SObject> next() {
    if (!hasNext()) {
      throw new System.NoSuchElementException('Iterator has no more elements.');
    }
    try {
      Integer fetchSize = Math.min(
        this.chunkSize,
        this.totalRecords - this.position
      );
      List<SObject> records = fetchRecordsWithSelfHealing(fetchSize);

      advancePosition(records != null ? records.size() : fetchSize);

      return castToTypedList(records);
    } finally {
      if (!hasNext()) {
        close();
      }
    }
  }

  /**
   * @description Fetches records with a retry mechanism for transient cursor exceptions
   * and self-healing for expired/fatal cursor exceptions.
   * @param fetchSize The number of records to fetch.
   * @return The list of fetched SObjects.
   */
  private List<SObject> fetchRecordsWithSelfHealing(Integer fetchSize) {
    return ChunkedCursorHelper.fetchWithSelfHealing(
      this,
      this.position,
      fetchSize
    );
  }

  private void advancePosition(Integer actualCount) {
    this.position = (this.selectedCursorType == CursorType.PAGINATION &&
      this.nextPaginationIndex != null)
      ? this.nextPaginationIndex
      : (this.position + actualCount);

    if (this.iterationsRemaining != null) {
      this.iterationsRemaining--;
    }
  }

  /**
   * @description Constructs a typed list of SObjects from the raw SObject list if a type is configured.
   * @param records The SObject list to type-cast.
   * @return A list cast to the correct SObject concrete type.
   */
  private List<SObject> castToTypedList(List<SObject> records) {
    return ChunkedCursorHelper.castToTypedList(records, this.resolvedListType);
  }

  // ==========================================
  // Navigation and Partitioning Features
  // ==========================================

  /**
   * @description Seeks the iterator's position pointer directly to a specific record index.
   * Resets the partition limit to allow further iteration if applicable.
   * @param targetPosition The index to jump to (must be between 0 and totalRecords).
   */
  public void seek(Integer targetPosition) {
    if (
      Math.min(Math.max(0, targetPosition), this.totalRecords) != targetPosition
    ) {
      throw new System.IllegalArgumentException(
        'Seek position must be between 0 and totalRecords.'
      );
    }
    this.position = targetPosition;
    this.iterationsRemaining = this.maxIterations;
  }

  /**
   * @description Partitions the remaining cursor results into independent single-chunk iterator instances.
   * Ideal for parallel Queueable / Workflow step fan-out.
   * @return List of pre-configured single-chunk iterators starting at correct offsets.
   */
  public List<ChunkedCursorIterator> partition() {
    List<ChunkedCursorIterator> partitions = new List<ChunkedCursorIterator>();
    // Note: loop starts from the current position pointer, preserving unconsumed state,
    // and we pass null for active cursor states to avoid concurrent thread locking.
    for (
      Integer pos = this.position;
      pos < this.totalRecords;
      pos += this.chunkSize
    ) {
      PartitionParams params = new PartitionParams();
      params.selectedCursorType = this.selectedCursorType;
      params.position = pos;
      params.chunkSize = this.chunkSize;
      params.totalRecords = this.totalRecords;
      params.maxIterations = 1;
      params.query = this.query;
      params.bindMap = this.bindMap;
      params.selectedAccessLevel = this.operationAccessLevel;
      params.sObjectTypeName = this.sObjectTypeName;
      partitions.add(new ChunkedCursorIterator(params));
    }
    return partitions;
  }

  /**
   * @description Fetches a page of records from the database.
   * @param position Offset position.
   * @param size Number of records to fetch.
   * @return List of SObjects fetched.
   */
  public List<SObject> fetch(Integer position, Integer size) {
    if (this.selectedCursorType == CursorType.PAGINATION) {
      if (this.paginationCursor == null) {
        initCursor();
      }
      ChunkedCursorHelper.PaginationFetchResult result = ChunkedCursorHelper.fetchPaginationPage(
        this.paginationCursor,
        position,
        size
      );
      this.nextPaginationIndex = (result.nextIndex == 0)
        ? this.totalRecords
        : result.nextIndex;
      return result.records;
    }
    if (this.standardCursor == null) {
      initCursor();
    }
    return this.standardCursor.fetch(position, size);
  }

  /**
   * @description Heals the database cursor by re-initializing it.
   */
  public void heal() {
    initCursor();
  }

  /**
   * @description Gets the dynamic query string.
   * @return Dynamic query string.
   */
  public String getQuery() {
    return this.query;
  }

  @TestVisible
  private Schema.SObjectType getSObjectType() {
    return this.sObjectTypeName != null
      ? Schema.getGlobalDescribe().get(this.sObjectTypeName)
      : null;
  }

  /**
   * @description Gets the total number of records matching the query.
   * @return The total record count.
   */
  public Integer getTotalRecords() {
    return this.totalRecords;
  }

  /**
   * @description Explicitly releases the cursor resources to avoid hitting the concurrent cursor limit.
   */
  public void close() {
    this.standardCursor = null;
    this.paginationCursor = null;
  }
}
