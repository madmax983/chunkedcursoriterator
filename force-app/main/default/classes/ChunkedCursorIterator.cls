/**
 * @description A unified, resilient, and serializable custom iterator for Salesforce Apex Cursors.
 * Supports both Database.Cursor (up to 50M rows) and Database.PaginationCursor (up to 100K rows).
 * Implements Iterable and Iterator for seamless use in for-each loops, queueables, and parallel workflows.
 */
public inherited sharing class ChunkedCursorIterator 
    implements Iterable<List<SObject>>, Iterator<List<SObject>> {
    
    public enum CursorType { STANDARD, PAGINATION }
    
    // Core state variables (serialized)
    private CursorType selectedCursorType;
    private Integer position;
    private Integer chunkSize;
    private Integer totalRecords;
    
    // Active database cursor state (transient as cursor resources cannot span transactions/serialization)
    @TestVisible private transient Database.Cursor standardCursor;
    @TestVisible private transient Database.PaginationCursor paginationCursor;
    @TestVisible private transient Integer nextPaginationIndex;
    
    // Iteration limits for partitioning
    private Integer maxIterations;
    private Integer iterationsRemaining;
    
    // Self-healing metadata (serialized to enable database-level recovery on deserialization/expiration)
    private String query;
    private Map<String, Object> bindMap;
    @TestVisible private transient System.AccessLevel operationAccessLevel;
    private String accessLevelMode;
    private String permissionSetId;
    
    // Type safety configuration (serialized as String to ensure lightweight and consistent serialization)
    private String sObjectTypeName;

    // ==========================================
    // Constructors (Standard Cursors)
    // ==========================================

    public ChunkedCursorIterator(String query, Integer chunkSize) {
        this(query, null, chunkSize, System.AccessLevel.USER_MODE, CursorType.STANDARD, null);
    }
    
    public ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize) {
        this(query, bindMap, chunkSize, System.AccessLevel.USER_MODE, CursorType.STANDARD, null);
    }

    public ChunkedCursorIterator(String query, Integer chunkSize, Schema.SObjectType sObjectType) {
        this(query, null, chunkSize, System.AccessLevel.USER_MODE, CursorType.STANDARD, sObjectType);
    }

    public ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, Schema.SObjectType sObjectType) {
        this(query, bindMap, chunkSize, System.AccessLevel.USER_MODE, CursorType.STANDARD, sObjectType);
    }

    // ==========================================
    // Constructors (Pagination Cursors)
    // ==========================================

    public ChunkedCursorIterator(String query, Integer chunkSize, System.AccessLevel accessLevel) {
        this(query, null, chunkSize, accessLevel, CursorType.PAGINATION, null);
    }

    public ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, System.AccessLevel accessLevel) {
        this(query, bindMap, chunkSize, accessLevel, CursorType.PAGINATION, null);
    }

    public ChunkedCursorIterator(String query, Integer chunkSize, System.AccessLevel accessLevel, Schema.SObjectType sObjectType) {
        this(query, null, chunkSize, accessLevel, CursorType.PAGINATION, sObjectType);
    }

    public ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, System.AccessLevel accessLevel, Schema.SObjectType sObjectType) {
        this(query, bindMap, chunkSize, accessLevel, CursorType.PAGINATION, sObjectType);
    }

    // ==========================================
    // Constructors (Explicit Cursor Type Configuration)
    // ==========================================

    public ChunkedCursorIterator(String query, Integer chunkSize, CursorType selectedCursorType) {
        this(query, null, chunkSize, System.AccessLevel.USER_MODE, selectedCursorType, null);
    }

    public ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, CursorType selectedCursorType) {
        this(query, bindMap, chunkSize, System.AccessLevel.USER_MODE, selectedCursorType, null);
    }

    public ChunkedCursorIterator(String query, Integer chunkSize, CursorType selectedCursorType, Schema.SObjectType sObjectType) {
        this(query, null, chunkSize, System.AccessLevel.USER_MODE, selectedCursorType, sObjectType);
    }

    public ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, CursorType selectedCursorType, Schema.SObjectType sObjectType) {
        this(query, bindMap, chunkSize, System.AccessLevel.USER_MODE, selectedCursorType, sObjectType);
    }

    // Master constructor for fresh initialization
    private ChunkedCursorIterator(
        String query, 
        Map<String, Object> bindMap, 
        Integer chunkSize, 
        System.AccessLevel selectedAccessLevel, 
        CursorType selectedCursorType,
        Schema.SObjectType sObjectType
    ) {
        if (chunkSize == null || chunkSize <= 0) {
            throw new System.IllegalArgumentException('Chunk size must be greater than zero.');
        }
        this.query = query;
        this.bindMap = bindMap;
        this.chunkSize = chunkSize;
        this.operationAccessLevel = selectedAccessLevel;
        if (selectedAccessLevel != null) {
            String str = String.valueOf(selectedAccessLevel);
            this.accessLevelMode = str.contains('SYSTEM_MODE') ? 'SYSTEM_MODE' : 'USER_MODE';
            this.permissionSetId = extractPermissionSetId(str);
        } else {
            this.accessLevelMode = 'USER_MODE';
            this.permissionSetId = null;
        }
        this.selectedCursorType = selectedCursorType;
        this.sObjectTypeName = (sObjectType != null) ? sObjectType.getDescribe().getName() : null;
        this.position = 0;
        
        initCursor();
    }

    // Constructor for recreating partitioned/deserialized iterators
    private ChunkedCursorIterator(
        CursorType selectedCursorType,
        Database.Cursor standardCursor,
        Database.PaginationCursor paginationCursor,
        Integer position,
        Integer chunkSize,
        Integer totalRecords,
        Integer maxIterations,
        String query,
        Map<String, Object> bindMap,
        System.AccessLevel selectedAccessLevel,
        String sObjectTypeName
    ) {
        this.selectedCursorType = selectedCursorType;
        this.standardCursor = standardCursor;
        this.paginationCursor = paginationCursor;
        this.position = position;
        this.chunkSize = chunkSize;
        this.totalRecords = totalRecords;
        this.maxIterations = maxIterations;
        this.iterationsRemaining = maxIterations;
        this.query = query;
        this.bindMap = bindMap;
        this.operationAccessLevel = selectedAccessLevel;
        if (selectedAccessLevel != null) {
            String str = String.valueOf(selectedAccessLevel);
            this.accessLevelMode = str.contains('SYSTEM_MODE') ? 'SYSTEM_MODE' : 'USER_MODE';
            this.permissionSetId = extractPermissionSetId(str);
        } else {
            this.accessLevelMode = 'USER_MODE';
            this.permissionSetId = null;
        }
        this.sObjectTypeName = sObjectTypeName;
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
        this.sObjectTypeName = (sObjectType != null) ? sObjectType.getDescribe().getName() : null;
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
        System.AccessLevel baseLevel = (this.accessLevelMode == 'SYSTEM_MODE') ? System.AccessLevel.SYSTEM_MODE : System.AccessLevel.USER_MODE;
        if (String.isNotBlank(this.permissionSetId)) {
            try {
                this.operationAccessLevel = baseLevel.withPermissionSetId(this.permissionSetId);
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
        if (idx != -1) {
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
        }
        return null;
    }

    // ==========================================
    // Cursor Initialization
    // ==========================================

    private void initCursor() {
        System.AccessLevel accessLevel = getAccessLevel();
        if (this.selectedCursorType == CursorType.PAGINATION) {
            if (Limits.getApexPaginationCursors() >= Limits.getLimitApexPaginationCursors()) {
                throw new System.LimitException('Apex Pagination Cursors daily limit reached.');
            }
            if (this.bindMap != null && !this.bindMap.isEmpty()) {
                this.paginationCursor = Database.getPaginationCursorWithBinds(this.query, this.bindMap, accessLevel);
            } else {
                this.paginationCursor = Database.getPaginationCursor(this.query, accessLevel);
            }
            this.totalRecords = this.paginationCursor.getNumRecords();
        } else {
            if (Limits.getApexCursors() >= Limits.getLimitApexCursors()) {
                throw new System.LimitException('Apex Cursors daily limit reached.');
            }
            if (this.bindMap != null && !this.bindMap.isEmpty()) {
                this.standardCursor = Database.getCursorWithBinds(this.query, this.bindMap, accessLevel);
            } else {
                this.standardCursor = Database.getCursor(this.query, accessLevel);
            }
            this.totalRecords = this.standardCursor.getNumRecords();
        }
    }

    // ==========================================
    // Iterable & Iterator Interface Implementation
    // ==========================================

    public Iterator<List<SObject>> iterator() {
        return this;
    }
    
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

    public List<SObject> next() {
        // Ensure cursor is initialized before checking hasNext() and calculating fetch size.
        // Handles post-deserialization and explicit closure states.
        ensureCursorInitialized();

        if (!hasNext()) {
            throw new System.NoSuchElementException('Iterator has no more elements.');
        }
        
        Integer fetchSize = Math.min(this.chunkSize, this.totalRecords - this.position);
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
                // Self-healing check: if the cursor is fatal or expired, regenerate it
                if (isExpiredOrFatalCursorException(e) && this.query != null) {
                    try {
                        initCursor(); // Re-open query cursor and update totalRecords
                        if (this.position >= this.totalRecords) {
                            records = new List<SObject>();
                            break;
                        }
                        // Recalculate fetchSize in case of shrinking database records
                        fetchSize = Math.min(this.chunkSize, this.totalRecords - this.position);
                        records = fetchPageWithCursor(this.position, fetchSize);
                        break;
                    } catch (Exception healingEx) {
                        throw e; // Rethrow original exception if recovery fails
                    }
                } else {
                    throw e;
                }
            }
        }
        
        // Safety: Always advance position by next index (for pagination) or requested fetchSize (for standard)
        if (this.selectedCursorType == CursorType.PAGINATION) {
            this.position = this.nextPaginationIndex != null ? this.nextPaginationIndex : (this.position + fetchSize);
        } else {
            this.position += fetchSize;
        }
        
        if (this.iterationsRemaining != null) {
            this.iterationsRemaining--;
        }
        
        // Construct the typed list if sObjectTypeName is provided
        List<SObject> resultList = records;
        if (this.sObjectTypeName != null && records != null) {
            List<SObject> typedList = (List<SObject>) System.Type.forName('List<' + this.sObjectTypeName + '>').newInstance();
            typedList.addAll(records);
            resultList = typedList;
        }

        // Auto-close cursor when iterator is exhausted to release connection slot
        if (!hasNext()) {
            close();
        }
        
        return resultList != null ? resultList : new List<SObject>();
    }

    // Ensures the cursor is initialized (particularly after deserialization where transient fields are null)
    private void ensureCursorInitialized() {
        if (this.selectedCursorType == CursorType.PAGINATION && this.paginationCursor == null) {
            initCursor();
        } else if (this.selectedCursorType == CursorType.STANDARD && this.standardCursor == null) {
            initCursor();
        }
    }

    // Helper method to route record fetching, with lazy auto-initialization for deserialized states
    private List<SObject> fetchPageWithCursor(Integer start, Integer size) {
        if (this.selectedCursorType == CursorType.PAGINATION) {
            if (this.paginationCursor == null) {
                initCursor();
            }
            Database.CursorFetchResult fetchResult = this.paginationCursor.fetchPage(start, size);
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
            throw new System.IllegalArgumentException('Seek position must be between 0 and totalRecords.');
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
        for (Integer pos = this.position; pos < this.totalRecords; pos += this.chunkSize) {
            partitions.add(new ChunkedCursorIterator(
                this.selectedCursorType,
                null,
                null,
                pos,
                this.chunkSize,
                this.totalRecords,
                1, // maxIterations: fetch only this partition chunk
                this.query,
                this.bindMap,
                getAccessLevel(),
                this.sObjectTypeName
            ));
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

    public CursorType getType() {
        return this.selectedCursorType;
    }
    
    public Integer getPosition() {
        return this.position;
    }
    
    public Integer getChunkSize() {
        return this.chunkSize;
    }
    
    public Integer getTotalRecords() {
        return this.totalRecords;
    }

    public Database.Cursor getStandardCursor() {
        return this.standardCursor;
    }
    
    public Database.PaginationCursor getPaginationCursor() {
        return this.paginationCursor;
    }
}
