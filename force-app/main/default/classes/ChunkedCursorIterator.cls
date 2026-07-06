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

  // Active database cursor state. Intentionally NOT transient: a Database.Cursor /
  // PaginationCursor serializes to a lightweight server-side handle (e.g.
  // {"queryId":"..."}), so retaining it lets a deserialized iterator resume by
  // reusing the existing server-side cursor instead of re-opening one. A re-open
  // would re-charge DailyApexCursorRowsLimit by the full row span (and consume
  // another DailyApexCursorLimit slot) on every resume. Genuine server-side
  // expiry is recovered by self-healing (see fetchWithSelfHealing).
  /**
   * @description The active standard Database.Cursor.
   */
  @TestVisible
  private Database.Cursor standardCursor { get; private set; }
  /**
   * @description The active Database.PaginationCursor.
   */
  @TestVisible
  private Database.PaginationCursor paginationCursor { get; private set; }
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
    private String accessLevelMode;
    private String permissionSetId;
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
    // Store mode + permission set explicitly (no AccessLevel string parsing) so
    // the execution context is reconstructed faithfully after serialization.
    this.accessLevelMode = options.accessMode;
    this.permissionSetId = options.permissionSetId;
    this.operationAccessLevel = options.accessLevel;
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
    this.accessLevelMode = params.accessLevelMode;
    this.permissionSetId = params.permissionSetId;
    this.operationAccessLevel = ChunkedCursorOptions.resolveAccessLevel(
      params.accessLevelMode,
      params.permissionSetId
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
   * Note: as a side effect, when no more chunks remain this releases the active
   * cursor (see close()) to avoid holding a concurrent cursor slot. Re-entering
   * iteration afterwards (e.g. via seek()) transparently re-opens the cursor.
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
   * @description Reports whether this transaction still has query-row headroom to
   * fetch at least one more chunk before hitting the per-transaction SOQL row
   * limit (50k). Distinct from hasNext(): hasNext() asks whether records remain;
   * hasRowsLeft() asks whether the current transaction can afford to fetch them.
   * Intended for `while (iter.hasNext() && iter.hasRowsLeft())` loops that yield
   * to a chained job when the budget runs low.
   * @return True if remaining query rows are enough for another chunk.
   */
  public Boolean hasRowsLeft() {
    return (Limits.getLimitQueryRows() - Limits.getQueryRows()) >=
      this.chunkSize;
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

      advancePosition(records, fetchSize);

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

  private void advancePosition(List<SObject> records, Integer fetchSize) {
    if (
      this.selectedCursorType == CursorType.PAGINATION &&
      this.nextPaginationIndex != null
    ) {
      this.position = this.nextPaginationIndex;
    } else {
      // Guarantee forward progress. If a standard cursor returns an empty batch
      // (e.g. rows deleted after the cursor snapshot) advance by the requested
      // size so iteration cannot stall in an infinite loop.
      Integer actualCount = (records != null) ? records.size() : fetchSize;
      this.position += (actualCount > 0) ? actualCount : fetchSize;
    }

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
      params.accessLevelMode = this.accessLevelMode;
      params.permissionSetId = this.permissionSetId;
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
    if (this.sObjectTypeName == null) {
      return null;
    }
    // Resolve the token directly instead of Schema.getGlobalDescribe(), which
    // describes every object in the org and is far more expensive.
    System.Type resolvedType = System.Type.forName(this.sObjectTypeName);
    return (resolvedType != null)
      ? ((SObject) resolvedType.newInstance()).getSObjectType()
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
