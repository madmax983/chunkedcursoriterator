/**
 * @description Controller for the cursorDatatable LWC. Exposes AuraEnabled methods
 * to initialize and fetch paginated record chunks using ChunkedCursorIterator.
 *
 * Security model: the iterator runs in USER_MODE, so every fetch enforces the
 * running user's FLS, CRUD, and sharing. The serialized iterator state is round
 * tripped through the client as an optimization only; because access is bounded
 * by USER_MODE, a client that tampers with the state can never read records it
 * could not already read. Do NOT reuse this pattern with SYSTEM_MODE or an
 * elevated permission set while trusting client-supplied state.
 */
public with sharing class CursorDatatableController {
  /**
   * @description Data wrapper structure returned to the LWC client containing records
   * and serialized iterator session state.
   */
  public class FetchResult {
    @AuraEnabled
    public List<SObject> records;
    @AuraEnabled
    public String iteratorState;
    @AuraEnabled
    public Boolean hasMore;
    @AuraEnabled
    public Integer totalRecords;
  }

  /**
   * @description Initializes the ChunkedCursorIterator session and retrieves the first page of data.
   * @param query The dynamic SOQL query.
   * @param chunkSize The page size.
   * @param sObjectType The API name of the target SObject type.
   * @return The initial FetchResult containing the first chunk and serialized state.
   */
  @AuraEnabled(cacheable=false)
  public static FetchResult startSession(
    String query,
    Integer chunkSize,
    String sObjectType
  ) {
    // Resolve the token without Schema.getGlobalDescribe() (which describes every
    // object in the org). Guard against names that resolve to a non-SObject type.
    Schema.SObjectType token;
    try {
      System.Type resolvedType = System.Type.forName(sObjectType);
      Object instance = (resolvedType != null)
        ? resolvedType.newInstance()
        : null;
      if (instance instanceof SObject) {
        token = ((SObject) instance).getSObjectType();
      }
    } catch (Exception e) {
      token = null;
    }
    if (token == null) {
      throw new AuraHandledException('Invalid SObject Type: ' + sObjectType);
    }

    ChunkedCursorIterator iterator = new ChunkedCursorIterator(
      new ChunkedCursorOptions(query, chunkSize)
        .setUserMode()
        .setSObjectType(token)
    );

    FetchResult result = new FetchResult();
    result.records = iterator.hasNext() ? iterator.next() : new List<SObject>();
    result.iteratorState = JSON.serialize(iterator);
    result.hasMore = iterator.hasNext();
    result.totalRecords = iterator.totalRecords;
    return result;
  }

  /**
   * @description Deserializes the iterator session state to fetch the next page of records.
   * @param iteratorState The serialized JSON string representing the ChunkedCursorIterator.
   * @return The FetchResult containing the next record chunk and updated serialized state.
   */
  @AuraEnabled(cacheable=false)
  public static FetchResult fetchNextChunk(String iteratorState) {
    if (String.isBlank(iteratorState)) {
      throw new AuraHandledException('Iterator state cannot be null or empty.');
    }

    ChunkedCursorIterator iterator = (ChunkedCursorIterator) JSON.deserialize(
      iteratorState,
      ChunkedCursorIterator.class
    );

    FetchResult result = new FetchResult();
    result.records = iterator.hasNext() ? iterator.next() : new List<SObject>();
    result.iteratorState = JSON.serialize(iterator);
    result.hasMore = iterator.hasNext();
    result.totalRecords = iterator.totalRecords;
    return result;
  }
}
