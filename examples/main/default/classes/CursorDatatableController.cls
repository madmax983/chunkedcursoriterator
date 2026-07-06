/**
 * @description Controller for the cursorDatatable LWC. Exposes AuraEnabled methods
 * to initialize and fetch paginated record chunks using ChunkedCursorIterator.
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
    Schema.SObjectType token = Schema.getGlobalDescribe().get(sObjectType);
    if (token == null) {
      throw new AuraHandledException('Invalid SObject Type: ' + sObjectType);
    }

    ChunkedCursorIterator iterator = new ChunkedCursorIterator(
      new ChunkedCursorOptions(query, chunkSize)
        .setAccessLevel(System.AccessLevel.USER_MODE)
        .setSObjectType(token)
    );

    FetchResult result = new FetchResult();
    result.records = iterator.hasNext() ? iterator.next() : new List<SObject>();
    result.iteratorState = ChunkedCursorHelper.signState(
      JSON.serialize(iterator)
    );
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
    String verifiedState = ChunkedCursorHelper.verifyAndExtractState(
      iteratorState
    );

    ChunkedCursorIterator iterator = (ChunkedCursorIterator) JSON.deserialize(
      verifiedState,
      ChunkedCursorIterator.class
    );

    FetchResult result = new FetchResult();
    result.records = iterator.hasNext() ? iterator.next() : new List<SObject>();
    result.iteratorState = ChunkedCursorHelper.signState(
      JSON.serialize(iterator)
    );
    result.hasMore = iterator.hasNext();
    result.totalRecords = iterator.totalRecords;
    return result;
  }
}
