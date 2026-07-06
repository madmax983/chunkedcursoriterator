/**
 * @description Configuration options for constructing a ChunkedCursorIterator.
 */
public inherited sharing class ChunkedCursorOptions {
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
  public ChunkedCursorIterator.CursorType selectedCursorType {
    get;
    private set;
  }
  /**
   * @description The concrete SObject type token for returned lists.
   */
  public Schema.SObjectType sObjectType { get; private set; }

  /**
   * @description Basic constructor for Options with required fields.
   * @param query The dynamic SOQL query.
   * @param chunkSize The size of each chunk.
   */
  public ChunkedCursorOptions(String query, Integer chunkSize) {
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
  public ChunkedCursorOptions setBindMap(Map<String, Object> bindMap) {
    this.bindMap = bindMap;
    return this;
  }

  /**
   * @description Sets the Salesforce execution AccessLevel context.
   * @param accessLevel The access level context (USER_MODE or SYSTEM_MODE).
   * @return The current Options instance.
   */
  public ChunkedCursorOptions setAccessLevel(System.AccessLevel accessLevel) {
    this.accessLevel = accessLevel;
    return this;
  }

  /**
   * @description Sets the database cursor type.
   * @param cursorType The cursor type (STANDARD or PAGINATION).
   * @return The current Options instance.
   */
  public ChunkedCursorOptions setCursorType(
    ChunkedCursorIterator.CursorType cursorType
  ) {
    this.selectedCursorType = cursorType;
    return this;
  }

  /**
   * @description Sets the SObject type for returned results, ensuring type safety.
   * @param sObjectType The SObject type token (e.g. Account.SObjectType).
   * @return The current Options instance.
   */
  public ChunkedCursorOptions setSObjectType(Schema.SObjectType sObjectType) {
    this.sObjectType = sObjectType;
    return this;
  }

  /**
   * @description Extracts the permission set ID from the string representation of an AccessLevel.
   * @param str The AccessLevel string representation.
   * @return The extracted 15 or 18 character permission set ID, or null.
   */
  public static String extractPermissionSetId(String str) {
    if (String.isBlank(str)) {
      return null;
    }
    Pattern p = Pattern.compile('(?i)0PS[a-zA-Z0-9]{12,15}');
    Matcher m = p.matcher(str);
    return m.find() ? m.group(0) : null;
  }

  /**
   * @description Extracts the permission set ID from an AccessLevel.
   * @param accessLevel The System.AccessLevel.
   * @return The extracted permission set ID or null.
   */
  public static String extractPermissionSetId(System.AccessLevel accessLevel) {
    return accessLevel != null
      ? extractPermissionSetId(String.valueOf(accessLevel))
      : null;
  }

  /**
   * @description Resolves execution AccessLevel from mode and permission set ID.
   * @param accessLevelMode The mode string (USER_MODE or SYSTEM_MODE).
   * @param permissionSetId The optional permission set ID.
   * @return Resolved AccessLevel.
   */
  public static System.AccessLevel resolveAccessLevel(
    String accessLevelMode,
    String permissionSetId
  ) {
    System.AccessLevel baseLevel = (accessLevelMode == 'SYSTEM_MODE')
      ? System.AccessLevel.SYSTEM_MODE
      : System.AccessLevel.USER_MODE;
    if (String.isNotBlank(permissionSetId)) {
      try {
        return baseLevel.withPermissionSetId(permissionSetId);
      } catch (Exception e) {
        return baseLevel;
      }
    }
    return baseLevel;
  }

  /**
   * @description Returns the access level mode string.
   * @param str The AccessLevel string representation.
   * @return The mode string (SYSTEM_MODE or USER_MODE).
   */
  public static String getAccessLevelMode(String str) {
    return str != null && str.contains('SYSTEM_MODE')
      ? 'SYSTEM_MODE'
      : 'USER_MODE';
  }

  /**
   * @description Returns the access level mode string.
   * @param accessLevel The System.AccessLevel.
   * @return The mode string (SYSTEM_MODE or USER_MODE).
   */
  public static String getAccessLevelMode(System.AccessLevel accessLevel) {
    return accessLevel != null &&
      String.valueOf(accessLevel).contains('SYSTEM_MODE')
      ? 'SYSTEM_MODE'
      : 'USER_MODE';
  }

  /**
   * @description Returns the concrete SObject name.
   * @param sObjectType The Schema.SObjectType.
   * @return The API name of the SObject or null.
   */
  public static String getSObjectTypeName(Schema.SObjectType sObjectType) {
    return sObjectType != null
      ? sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getName()
      : null;
  }
}
