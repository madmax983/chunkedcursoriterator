/**
 * @description Helper utility class for ChunkedCursorIterator to reduce class complexity.
 */
public inherited sharing class ChunkedCursorHelper {
  /**
   * @description Interface defining database cursor fetch and recovery operations.
   */
  public interface CursorFetcher {
    /**
     * @description Fetches a page of records from the database.
     * @param position The offset index.
     * @param size The number of records to fetch.
     * @return List of SObjects fetched.
     */
    List<SObject> fetch(Integer position, Integer size);
    /**
     * @description Re-opens the database cursor to heal it.
     */
    void heal();
    /**
     * @description Gets the total records currently available.
     * @return Total record count.
     */
    Integer getTotalRecords();
    /**
     * @description Gets the dynamic query string.
     * @return Dynamic query string.
     */
    String getQuery();
  }

  /**
   * @description Safely creates standard cursor.
   * @param query Dynamic SOQL query.
   * @param bindMap Dynamic query binds.
   * @param accessLevel AccessLevel context.
   * @return Database.Cursor.
   */
  public static Database.Cursor createStandardCursor(
    String query,
    Map<String, Object> bindMap,
    System.AccessLevel accessLevel
  ) {
    if (Limits.getApexCursors() >= Limits.getLimitApexCursors()) {
      throw new System.LimitException('Apex Cursors daily limit reached.');
    }
    return (bindMap != null && !bindMap.isEmpty())
      ? Database.getCursorWithBinds(query, bindMap, accessLevel)
      : Database.getCursor(query, accessLevel);
  }

  /**
   * @description Safely creates pagination cursor.
   * @param query Dynamic SOQL query.
   * @param bindMap Dynamic query binds.
   * @param accessLevel AccessLevel context.
   * @return Database.PaginationCursor.
   */
  public static Database.PaginationCursor createPaginationCursor(
    String query,
    Map<String, Object> bindMap,
    System.AccessLevel accessLevel
  ) {
    if (
      Limits.getApexPaginationCursors() >=
      Limits.getLimitApexPaginationCursors()
    ) {
      throw new System.LimitException(
        'Apex Pagination Cursors daily limit reached.'
      );
    }
    return (bindMap != null && !bindMap.isEmpty())
      ? Database.getPaginationCursorWithBinds(query, bindMap, accessLevel)
      : Database.getPaginationCursor(query, accessLevel);
  }

  /**
   * @description Exception heuristics for expired or corrupt server cursor state.
   * @param e Exception thrown during fetch.
   * @return True if exception represents an expired or fatal cursor issue.
   */
  public static Boolean isExpiredOrFatalCursorException(Exception e) {
    String typeName = e.getTypeName();
    String message = e.getMessage();
    return typeName.contains('CursorException') ||
      typeName.contains('FatalException') ||
      (message != null && message.containsIgnoreCase('cursor'));
  }

  /**
   * @description Constructs a typed list of SObjects from the raw SObject list if a type is configured.
   * @param records The list of records to cast.
   * @param sObjectTypeName The SObject API name.
   * @return Concrete typed list or generic list.
   */
  public static List<SObject> castToTypedList(
    List<SObject> records,
    String sObjectTypeName
  ) {
    if (sObjectTypeName == null || records == null) {
      return records;
    }
    List<SObject> typedList = (List<SObject>) System.Type.forName(
        'List<' + sObjectTypeName + '>'
      )
      .newInstance();
    typedList.addAll(records);
    return typedList;
  }

  /**
   * @description Data structure holding pagination fetch outputs.
   */
  public class PaginationFetchResult {
    /**
     * @description The list of fetched SObjects.
     */
    public List<SObject> records { get; private set; }
    /**
     * @description The next pagination index.
     */
    public Integer nextIndex { get; private set; }

    /**
     * @description Basic constructor.
     * @param records List of records.
     * @param nextIndex Next pagination index.
     */
    public PaginationFetchResult(List<SObject> records, Integer nextIndex) {
      this.records = records;
      this.nextIndex = nextIndex;
    }
  }

  /**
   * @description Fetches a page of records using a PaginationCursor.
   * @param cursor The active PaginationCursor.
   * @param start The starting index.
   * @param size The number of records to fetch.
   * @return A PaginationFetchResult with records and next index.
   */
  public static PaginationFetchResult fetchPaginationPage(
    Database.PaginationCursor cursor,
    Integer start,
    Integer size
  ) {
    Database.CursorFetchResult fetchResult = cursor.fetchPage(start, size);
    if (fetchResult != null) {
      return new PaginationFetchResult(
        fetchResult.getRecords(),
        fetchResult.getNextIndex()
      );
    }
    return new PaginationFetchResult(new List<SObject>(), start + size);
  }

  /**
   * @description Executes fetching with built-in retry and self-healing.
   * @param fetcher The cursor fetcher instance.
   * @param position The position index.
   * @param fetchSize The number of records to fetch.
   * @return List of fetched SObjects.
   */
  public static List<SObject> fetchWithSelfHealing(
    CursorFetcher fetcher,
    Integer position,
    Integer fetchSize
  ) {
    try {
      return fetchWithRetry(fetcher, position, fetchSize);
    } catch (Exception e) {
      if (isExpiredOrFatalCursorException(e) && fetcher.getQuery() != null) {
        fetcher.heal();
        Integer total = fetcher.getTotalRecords();
        if (position < total) {
          return fetchWithRetry(
            fetcher,
            position,
            Math.min(fetchSize, total - position)
          );
        }
        return new List<SObject>();
      }
      throw e;
    }
  }

  /**
   * @description Internal helper performing fetching with transient cursor retry loop.
   * @param fetcher The cursor fetcher instance.
   * @param position The position index.
   * @param fetchSize The number of records to fetch.
   * @return List of fetched SObjects.
   */
  private static List<SObject> fetchWithRetry(
    CursorFetcher fetcher,
    Integer position,
    Integer fetchSize
  ) {
    Integer attempts = 0;
    while (true) {
      try {
        return fetcher.fetch(position, fetchSize);
      } catch (System.TransientCursorException e) {
        if (++attempts >= 3) {
          throw e;
        }
      }
    }
    return new List<SObject>();
  }
}
