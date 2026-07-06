@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs')
private class CursorDatatableControllerTest {
  private static final String QUERY = 'SELECT Id, Name FROM Account ORDER BY Name';

  @TestSetup
  static void setup() {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 5; i++) {
      accounts.add(new Account(Name = 'Test Account ' + i));
    }
    insert accounts;
  }

  @IsTest
  static void testStartSessionReturnsFirstChunk() {
    Test.startTest();
    CursorDatatableController.FetchResult result = CursorDatatableController.startSession(
      QUERY,
      2,
      'Account'
    );
    Test.stopTest();

    System.assertEquals(2, result.records.size(), 'First chunk should hold 2');
    System.assertEquals(5, result.totalRecords);
    System.assertEquals(true, result.hasMore);
    System.assert(
      String.isNotBlank(result.iteratorState),
      'Serialized state should be returned to the client'
    );
  }

  @IsTest
  static void testFullRoundTripThroughSerializedState() {
    Test.startTest();
    CursorDatatableController.FetchResult result = CursorDatatableController.startSession(
      QUERY,
      2,
      'Account'
    );

    Integer processed = result.records.size();
    Integer guard = 0;
    // Drive the same stateless round-trip the LWC performs.
    while (result.hasMore && guard < 10) {
      result = CursorDatatableController.fetchNextChunk(result.iteratorState);
      processed += result.records.size();
      guard++;
    }
    Test.stopTest();

    System.assertEquals(
      5,
      processed,
      'Every record should be paged exactly once'
    );
    System.assertEquals(false, result.hasMore);
  }

  @IsTest
  static void testFetchNextChunkRejectsBlankState() {
    Test.startTest();
    try {
      CursorDatatableController.fetchNextChunk('');
      System.assert(false, 'Blank state should throw');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    Test.stopTest();
  }

  @IsTest
  static void testStartSessionRejectsInvalidSObjectType() {
    Test.startTest();
    try {
      CursorDatatableController.startSession(QUERY, 2, 'NotARealObject__x');
      System.assert(false, 'Invalid SObject type should throw');
    } catch (AuraHandledException e) {
      System.assert(true);
    }
    Test.stopTest();
  }
}
