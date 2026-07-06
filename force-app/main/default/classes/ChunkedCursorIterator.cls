/**
 * @description A unified, resilient, and serializable custom iterator for Salesforce Apex Cursors.
 * Supports both Database.Cursor (up to 50M rows) and Database.PaginationCursor (up to 100K rows).
 * Implements Iterable and Iterator for seamless use in for-each loops, queueables, and parallel workflows.
 */
@SuppressWarnings('PMD.CognitiveComplexity, PMD.CyclomaticComplexity')
public inherited sharing class ChunkedCursorIterator implements Iterable<List<SObject>>, Iterator<List<SObject>> {
  public enum CursorType {
    STANDARD,
    PAGINATION
  }

  // Core state variables (serialized)
  private CursorType selectedCursorType;
  private Integer position;
  private Integer chunkSize;
  private Integer totalRecords;

  // Active database cursor state (transient as cursor resources cannot span transactions/serialization)
  @TestVisible
  private transient Database.Cursor standardCursor;
  @TestVisible
  private transient Database.PaginationCursor paginationCursor;
  @TestVisible
  private transient Integer nextPaginationIndex;

  // Iteration limits for partitioning
  private Integer maxIterations;
  private Integer iterationsRemaining;

  // Self-healing metadata (serialized to enable database-level recovery on deserialization/expiration)
  private String query;
  private Map<String, Object> bindMap;
  @TestVisible
  private transient System.AccessLevel operationAccessLevel;
  private String accessLevelMode;
  private String permissionSetId;

  // Type safety configuration (serialized as String to ensure lightweight and consistent serialization)
  private String sObjectTypeName;

  // ==========================================
  // Inner Classes (Configuration & State)
  // ==========================================

  /**
   * @description Configuration options for constructing a ChunkedCursorIterator.
   */
  public class Options {
    /**
     * @description The dynamic SOQL query string.
     */
    public String query { get; private set; }
    /**
     * @description The size of each chunk.
     */
    public Integer chunkSize { get; private set; }
    /**
     * @description The map of bind variables for dynamic query execution.
     */
    public Map<String, Object> bindMap { get; private set; }
    /**
     * @description The access level context (USER_MODE or SYSTEM_MODE).
     */
    public System.AccessLevel accessLevel { get; private set; }
    /**
     * @description The type of database cursor to utilize.
     */
    public CursorType selectedCursorType { get; private set; }
    /**
     * @description The concrete SObject type token for returned lists.
     */
    public Schema.SObjectType sObjectType { get; private set; }

    /**
     * @description Basic constructor for Options with required fields.
     * @param query The dynamic SOQL query.
     * @param chunkSize The size of each chunk.
     */
    public Options(String query, Integer chunkSize) {
      if (chunkSize == null || chunkSize <= 0) {
        throw new System.IllegalArgumentException(
          'Chunk size must be greater than zero.'
        );
      }
      this.query = query;
      this.chunkSize = chunkSize;
      this.accessLevel = System.AccessLevel.USER_MODE;
      this.selectedCursorType = ChunkedCursorIterator.CursorType.STANDARD;
    }

    /**
     * @description Sets the bind map variables for query execution.
     * @param bindMap The bind variable map.
     * @return The current Options instance.
     */
    public Options setBindMap(Map<String, Object> bindMap) {
      this.bindMap = bindMap;
      return this;
    }

    /**
     * @description Sets the Salesforce execution AccessLevel context.
     * @param accessLevel The access level context (USER_MODE or SYSTEM_MODE).
     * @return The current Options instance.
     */
    public Options setAccessLevel(System.AccessLevel accessLevel) {
      this.accessLevel = accessLevel;
      return this;
    }

    /**
     * @description Sets the database cursor type.
     * @param cursorType The cursor type (STANDARD or PAGINATION).
     * @return The current Options instance.
     */
    public Options setCursorType(CursorType cursorType) {
      this.selectedCursorType = cursorType;
      return this;
    }

    /**
     * @description Sets the SObject type for returned results, ensuring type safety.
     * @param sObjectType The SObject type token (e.g. Account.SObjectType).
     * @return The current Options instance.
     */
    public Options setSObjectType(Schema.SObjectType sObjectType) {
      this.sObjectType = sObjectType;
      return this;
    }
  }

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
    this(new Options(query, chunkSize));
  }

  /**
   * @description Advanced constructor to initialize the cursor iterator with options.
   * @param options The configuration Options instance.
   */
  public ChunkedCursorIterator(Options options) {
    if (options == null) {
      throw new System.IllegalArgumentException('Options cannot be null.');
    }
    this.query = options.query;
    this.bindMap = options.bindMap;
    this.chunkSize = options.chunkSize;
    this.operationAccessLevel = options.accessLevel;
    if (options.accessLevel != null) {
      String str = String.valueOf(options.accessLevel);
      this.accessLevelMode = str.contains('SYSTEM_MODE')
        ? 'SYSTEM_MODE'
        : 'USER_MODE';
      this.permissionSetId = extractPermissionSetId(str);
    } else {
      this.accessLevelMode = 'USER_MODE';
      this.permissionSetId = null;
    }
    this.selectedCursorType = options.selectedCursorType;
    this.sObjectTypeName = (options.sObjectType != null)
      ? options.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
          .getName()
      : null;
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
    if (params.selectedAccessLevel != null) {
      String str = String.valueOf(params.selectedAccessLevel);
      this.accessLevelMode = str.contains('SYSTEM_MODE')
        ? 'SYSTEM_MODE'
        : 'USER_MODE';
      this.permissionSetId = extractPermissionSetId(str);
    } else {
      this.accessLevelMode = 'USER_MODE';
      this.permissionSetId = null;
    }
    this.sObjectTypeName = params.sObjectTypeName;
  }

  // ==========================================
  // Fluent Configuration & Helpers
  // ==========================================

  /**
   * @description Sets the SObject type for the returned list, ensuring type safety.
   * @param sObjectType The SObject type token (e.g. Account.SObjectType).
   * @return The same ChunkedCursorIterator instance.
   */
  public ChunkedCursorIterator setSObjectType(Schema.SObjectType sObjectType) {
    this.sObjectTypeName = (sObjectType != null)
      ? sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getName()
      : null;
    return this;
  }

  /**
   * @description Gets the configured SObject type.
   * @return The SObjectType or null.
   */
  public Schema.SObjectType getSObjectType() {
    if (this.sObjectTypeName == null) {
      return null;
    }
    return Schema.getGlobalDescribe().get(this.sObjectTypeName);
  }

  // Resolves access level mode string to System.AccessLevel enum, preserving custom Permission Sets if supported
  @TestVisible
  private System.AccessLevel getAccessLevel() {
    if (this.operationAccessLevel != null) {
      return this.operationAccessLevel;
    }
    System.AccessLevel baseLevel = (this.accessLevelMode == 'SYSTEM_MODE')
      ? System.AccessLevel.SYSTEM_MODE
      : System.AccessLevel.USER_MODE;
    if (String.isNotBlank(this.permissionSetId)) {
      try {
        this.operationAccessLevel = baseLevel.withPermissionSetId(
          this.permissionSetId
        );
      } catch (Exception e) {
        // Fallback to base mode if the environment does not support/enable permission set access levels (e.g. scratch org tests)
        this.operationAccessLevel = baseLevel;
      }
    } else {
      this.operationAccessLevel = baseLevel;
    }
    return this.operationAccessLevel;
  }

  private static String extractPermissionSetId(String str) {
    if (String.isBlank(str)) {
      return null;
    }
    Integer idx = str.indexOfIgnoreCase('0PS');
    if (idx == -1) {
      return null;
    }
    if (str.length() >= idx + 18) {
      String potentialId = str.substring(idx, idx + 18);
      if (potentialId.isAlphanumeric()) {
        return potentialId;
      }
    }
    if (str.length() >= idx + 15) {
      String potentialId = str.substring(idx, idx + 15);
      if (potentialId.isAlphanumeric()) {
        return potentialId;
      }
    }
    return null;
  }

  // ==========================================
  // Cursor Initialization
  // ==========================================

  private void initCursor() {
    System.AccessLevel accessLevel = getAccessLevel();
    if (this.selectedCursorType == CursorType.PAGINATION) {
      initPaginationCursor(accessLevel);
    } else {
      initStandardCursor(accessLevel);
    }
  }

  private void initPaginationCursor(System.AccessLevel accessLevel) {
    if (
      Limits.getApexPaginationCursors() >=
      Limits.getLimitApexPaginationCursors()
    ) {
      throw new System.LimitException(
        'Apex Pagination Cursors daily limit reached.'
      );
    }
    if (this.bindMap != null && !this.bindMap.isEmpty()) {
      this.paginationCursor = Database.getPaginationCursorWithBinds(
        this.query,
        this.bindMap,
        accessLevel
      );
    } else {
      this.paginationCursor = Database.getPaginationCursor(
        this.query,
        accessLevel
      );
    }
    this.totalRecords = this.paginationCursor.getNumRecords();
  }

  private void initStandardCursor(System.AccessLevel accessLevel) {
    if (Limits.getApexCursors() >= Limits.getLimitApexCursors()) {
      throw new System.LimitException('Apex Cursors daily limit reached.');
    }
    if (this.bindMap != null && !this.bindMap.isEmpty()) {
      this.standardCursor = Database.getCursorWithBinds(
        this.query,
        this.bindMap,
        accessLevel
      );
    } else {
      this.standardCursor = Database.getCursor(this.query, accessLevel);
    }
    this.totalRecords = this.standardCursor.getNumRecords();
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
    if (this.iterationsRemaining != null && this.iterationsRemaining <= 0) {
      close();
      return false;
    }
    Boolean hasMore = this.position < this.totalRecords;
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
    // Ensure cursor is initialized before checking hasNext() and calculating fetch size.
    // Handles post-deserialization and explicit closure states.
    ensureCursorInitialized();

    if (!hasNext()) {
      throw new System.NoSuchElementException('Iterator has no more elements.');
    }

    Integer fetchSize = Math.min(
      this.chunkSize,
      this.totalRecords - this.position
    );
    List<SObject> records = fetchRecordsWithSelfHealing(fetchSize);

    // Safety: Always advance position by next index (for pagination) or requested fetchSize (for standard)
    advancePosition(fetchSize);

    // Construct the typed list if sObjectTypeName is provided
    List<SObject> resultList = castToTypedList(records);

    // Auto-close cursor when iterator is exhausted to release connection slot
    if (!hasNext()) {
      close();
    }

    return resultList != null ? resultList : new List<SObject>();
  }

  /**
   * @description Fetches records with a retry mechanism for transient cursor exceptions
   * and self-healing for expired/fatal cursor exceptions.
   * @param fetchSize The number of records to fetch.
   * @return The list of fetched SObjects.
   */
  private List<SObject> fetchRecordsWithSelfHealing(Integer fetchSize) {
    List<SObject> records = null;
    Integer attempts = 0;
    final Integer maxRetries = 3;

    while (true) {
      try {
        records = fetchPageWithCursor(this.position, fetchSize);
        break; // Success
      } catch (System.TransientCursorException e) {
        attempts++;
        if (attempts >= maxRetries) {
          throw e; // Rethrow if retries exhausted
        }
      } catch (Exception e) {
        if (isExpiredOrFatalCursorException(e) && this.query != null) {
          records = attemptSelfHealing(e);
          break;
        }
        throw e;
      }
    }
    return records;
  }

  /**
   * @description Attempts self-healing by re-initializing the cursor and querying records.
   * @param originalException The original exception that triggered the self-healing.
   * @return The list of fetched SObjects.
   */
  private List<SObject> attemptSelfHealing(Exception originalException) {
    try {
      initCursor(); // Re-open query cursor and update totalRecords
      if (this.position >= this.totalRecords) {
        return new List<SObject>();
      }
      // Recalculate fetchSize in case of shrinking database records
      Integer newFetchSize = Math.min(
        this.chunkSize,
        this.totalRecords - this.position
      );
      return fetchPageWithCursor(this.position, newFetchSize);
    } catch (Exception healingEx) {
      throw originalException; // Rethrow original exception if recovery fails
    }
  }

  /**
   * @description Advances the cursor position pointer and updates iteration metrics.
   * @param fetchSize The size of the chunk fetched.
   */
  private void advancePosition(Integer fetchSize) {
    if (this.selectedCursorType == CursorType.PAGINATION) {
      this.position = this.nextPaginationIndex != null
        ? this.nextPaginationIndex
        : (this.position + fetchSize);
    } else {
      this.position += fetchSize;
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
    if (this.sObjectTypeName == null || records == null) {
      return records;
    }
    List<SObject> typedList = (List<SObject>) System.Type.forName(
        'List<' + this.sObjectTypeName + '>'
      )
      .newInstance();
    typedList.addAll(records);
    return typedList;
  }

  // Ensures the cursor is initialized (particularly after deserialization where transient fields are null)
  private void ensureCursorInitialized() {
    if (
      this.selectedCursorType == CursorType.PAGINATION &&
      this.paginationCursor == null
    ) {
      initCursor();
    } else if (
      this.selectedCursorType == CursorType.STANDARD &&
      this.standardCursor == null
    ) {
      initCursor();
    }
  }

  // Helper method to route record fetching, with lazy auto-initialization for deserialized states
  private List<SObject> fetchPageWithCursor(Integer start, Integer size) {
    if (this.selectedCursorType == CursorType.PAGINATION) {
      if (this.paginationCursor == null) {
        initCursor();
      }
      Database.CursorFetchResult fetchResult = this.paginationCursor.fetchPage(
        start,
        size
      );
      if (fetchResult != null) {
        Integer nextIdx = fetchResult.getNextIndex();
        this.nextPaginationIndex = (nextIdx == 0) ? this.totalRecords : nextIdx;
        return fetchResult.getRecords();
      }
      this.nextPaginationIndex = start + size;
      return new List<SObject>();
    } else {
      if (this.standardCursor == null) {
        initCursor();
      }
      return this.standardCursor.fetch(start, size);
    }
  }

  // Exception heuristics for expired or corrupt server cursor state
  private Boolean isExpiredOrFatalCursorException(Exception e) {
    String typeName = e.getTypeName();
    String message = e.getMessage();
    return typeName.contains('FatalCursorException') ||
      typeName.contains('FatalException') ||
      typeName.contains('CursorException') ||
      (message != null && message.containsIgnoreCase('cursor'));
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
    if (targetPosition < 0 || targetPosition > this.totalRecords) {
      throw new System.IllegalArgumentException(
        'Seek position must be between 0 and totalRecords.'
      );
    }
    this.position = targetPosition;
    if (this.maxIterations != null) {
      this.iterationsRemaining = this.maxIterations;
    }
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
      params.selectedAccessLevel = getAccessLevel();
      params.sObjectTypeName = this.sObjectTypeName;
      partitions.add(new ChunkedCursorIterator(params));
    }
    return partitions;
  }

  /**
   * @description Explicitly releases the cursor resources to avoid hitting the concurrent cursor limit.
   */
  public void close() {
    this.standardCursor = null;
    this.paginationCursor = null;
  }

  // ==========================================
  // Getters / State Inspection
  // ==========================================

  /**
   * @description Gets the cursor type (STANDARD or PAGINATION).
   * @return The CursorType.
   */
  public CursorType getType() {
    return this.selectedCursorType;
  }

  /**
   * @description Gets the current position pointer index.
   * @return The current position index.
   */
  public Integer getPosition() {
    return this.position;
  }

  /**
   * @description Gets the record chunk size.
   * @return The chunk size limit.
   */
  public Integer getChunkSize() {
    return this.chunkSize;
  }

  /**
   * @description Gets the total records matching the cursor query.
   * @return The total record count.
   */
  public Integer getTotalRecords() {
    return this.totalRecords;
  }

  /**
   * @description Gets the standard database cursor if active.
   * @return The standard cursor instance or null.
   */
  public Database.Cursor getStandardCursor() {
    return this.standardCursor;
  }

  /**
   * @description Gets the pagination database cursor if active.
   * @return The pagination cursor instance or null.
   */
  public Database.PaginationCursor getPaginationCursor() {
    return this.paginationCursor;
  }
}
