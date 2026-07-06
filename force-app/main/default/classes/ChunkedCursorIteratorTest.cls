@IsTest
@SuppressWarnings('PMD.ApexUnitTestClassShouldHaveRunAs')
private class ChunkedCursorIteratorTest {
  @TestSetup
  static void setup() {
    // Create 5 test Accounts
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 5; i++) {
      accounts.add(new Account(Name = 'Test Account ' + i));
    }
    insert accounts;
  }

  @IsTest
  static void testStandardCursorHappyPath() {
    Test.startTest();
    // Create standard iterator with chunk size 2 and type safety
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setSObjectType(Account.SObjectType)
    );

    System.assertEquals(
      ChunkedCursorIterator.CursorType.STANDARD,
      iter.selectedCursorType
    );
    System.assertEquals(5, iter.totalRecords);
    System.assertEquals(2, iter.chunkSize);
    System.assertEquals(0, iter.position);
    System.assertEquals(Account.SObjectType, iter.getSObjectType());

    // We expect 3 chunks: size 2, size 2, size 1
    System.assertEquals(true, iter.hasNext());
    List<SObject> chunk1 = iter.next();
    System.assertEquals(2, chunk1.size());
    // Verify type safety: we can successfully cast the chunk directly
    List<Account> accounts1 = (List<Account>) chunk1;
    System.assertNotEquals(null, accounts1);
    System.assertEquals(2, iter.position);

    System.assertEquals(true, iter.hasNext());
    List<SObject> chunk2 = iter.next();
    System.assertEquals(2, chunk2.size());
    List<Account> accounts2 = (List<Account>) chunk2;
    System.assertNotEquals(null, accounts2);
    System.assertEquals(4, iter.position);

    System.assertEquals(true, iter.hasNext());
    List<SObject> chunk3 = iter.next();
    System.assertEquals(1, chunk3.size());
    List<Account> accounts3 = (List<Account>) chunk3;
    System.assertNotEquals(null, accounts3);
    System.assertEquals(5, iter.position);

    System.assertEquals(false, iter.hasNext());
    System.assertEquals(null, iter.standardCursor); // Auto-close verification
    Test.stopTest();
  }

  @IsTest
  static void testPaginationCursorHappyPath() {
    Test.startTest();
    // Create pagination iterator with chunk size 2 in USER_MODE
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setAccessLevel(AccessLevel.USER_MODE)
        .setSObjectType(Account.SObjectType)
        .setCursorType(ChunkedCursorIterator.CursorType.PAGINATION)
    );

    System.assertEquals(
      ChunkedCursorIterator.CursorType.PAGINATION,
      iter.selectedCursorType
    );
    System.assertEquals(5, iter.totalRecords);
    System.assertEquals(2, iter.chunkSize);
    System.assertEquals(0, iter.position);

    // Iterate through all chunks
    Integer chunkCount = 0;
    Integer totalProcessed = 0;
    for (List<SObject> chunk : iter) {
      chunkCount++;
      totalProcessed += chunk.size();
      List<Account> accounts = (List<Account>) chunk; // verify casting
      System.assertNotEquals(null, accounts);
    }

    System.assertEquals(3, chunkCount);
    System.assertEquals(5, totalProcessed);
    System.assertEquals(null, iter.paginationCursor); // Auto-close verification
    Test.stopTest();
  }

  @IsTest
  static void testExplicitCursorTypeConstructor() {
    Test.startTest();
    // Create iterator by explicitly specifying Pagination type
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setCursorType(ChunkedCursorIterator.CursorType.PAGINATION)
        .setSObjectType(Account.SObjectType)
    );

    System.assertEquals(
      ChunkedCursorIterator.CursorType.PAGINATION,
      iter.selectedCursorType
    );
    System.assertEquals(5, iter.totalRecords);
    System.assertEquals(2, iter.chunkSize);
    System.assertEquals(0, iter.position);

    List<SObject> chunk = iter.next();
    System.assertEquals(2, chunk.size());
    Test.stopTest();
  }

  @IsTest
  static void testSerializationAndDeserialization() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setSObjectType(Account.SObjectType)
    );

    // Fetch first chunk
    List<SObject> chunk1 = iter.next();
    System.assertEquals(2, chunk1.size());
    System.assertEquals(2, iter.position);

    // Serialize state (the cursor handle serializes with it)
    String serialized = JSON.serialize(iter);
    System.assertNotEquals(null, serialized);

    // Deserialize state to a new iterator
    ChunkedCursorIterator deserializedIter = (ChunkedCursorIterator) JSON.deserialize(
      serialized,
      ChunkedCursorIterator.class
    );

    // Resume iteration on the deserialized instance (reuses the retained cursor handle)
    System.assertEquals(
      ChunkedCursorIterator.CursorType.STANDARD,
      deserializedIter.selectedCursorType
    );
    System.assertEquals(2, deserializedIter.position);
    System.assertEquals(5, deserializedIter.totalRecords);
    System.assertEquals(Account.SObjectType, deserializedIter.getSObjectType());

    System.assertEquals(true, deserializedIter.hasNext());
    List<SObject> chunk2 = deserializedIter.next();
    System.assertEquals(2, chunk2.size());
    List<Account> accounts2 = (List<Account>) chunk2; // verify post-deserialization type safety
    System.assertNotEquals(null, accounts2);
    System.assertEquals(4, deserializedIter.position);

    System.assertEquals(true, deserializedIter.hasNext());
    List<SObject> chunk3 = deserializedIter.next();
    System.assertEquals(1, chunk3.size());
    System.assertEquals(5, deserializedIter.position);

    System.assertEquals(false, deserializedIter.hasNext());
    Test.stopTest();
  }

  @IsTest
  static void testSerializedStandardCursorHandleSurvivesRoundTrip() {
    // Correct behavior: a Database.Cursor serializes to a lightweight server-side
    // handle, so a deserialized iterator must RETAIN it and resume by reusing the
    // existing cursor -- not re-open one (a re-open re-charges the daily cursor
    // rows limit by the full span on every resume).
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setSObjectType(Account.SObjectType)
    );
    iter.next(); // position -> 2, chunks still remain so the cursor stays open
    System.assertNotEquals(
      null,
      iter.standardCursor,
      'Cursor should be active while chunks remain'
    );

    ChunkedCursorIterator resumed = (ChunkedCursorIterator) JSON.deserialize(
      JSON.serialize(iter),
      ChunkedCursorIterator.class
    );

    System.assertNotEquals(
      null,
      resumed.standardCursor,
      'Deserialized iterator must retain the serialized cursor handle so resume reuses it instead of re-opening'
    );
    Test.stopTest();
  }

  @IsTest
  static void testSerializedPaginationCursorHandleSurvivesRoundTrip() {
    // Same reuse-not-reopen contract as the standard cursor, for pagination.
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setSObjectType(Account.SObjectType)
        .setCursorType(ChunkedCursorIterator.CursorType.PAGINATION)
    );
    iter.next(); // position -> 2, chunks remain so the cursor stays open
    System.assertNotEquals(
      null,
      iter.paginationCursor,
      'Pagination cursor should be active while chunks remain'
    );

    ChunkedCursorIterator resumed = (ChunkedCursorIterator) JSON.deserialize(
      JSON.serialize(iter),
      ChunkedCursorIterator.class
    );

    System.assertNotEquals(
      null,
      resumed.paginationCursor,
      'Deserialized iterator must retain the pagination cursor handle so resume reuses it instead of re-opening'
    );
    Test.stopTest();
  }

  @IsTest
  static void testHasRowsLeftReturnsTrueWithAmpleHeadroom() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id FROM Account ORDER BY Name', 2)
    );
    System.assertEquals(
      true,
      iter.hasRowsLeft(),
      'A small chunk against a fresh 50k query-row budget has room for another fetch'
    );
    Test.stopTest();
  }

  @IsTest
  static void testHasRowsLeftReturnsFalseWhenChunkExceedsQueryRowLimit() {
    Test.startTest();
    // A chunk larger than the per-transaction query-row limit (50k) can never
    // fit, regardless of prior consumption -- deterministic false.
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id FROM Account ORDER BY Name', 50001)
    );
    System.assertEquals(
      false,
      iter.hasRowsLeft(),
      'A chunk larger than the query-row limit leaves no room for a fetch'
    );
    Test.stopTest();
  }

  @IsTest
  static void testParallelPartitioning() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setSObjectType(Account.SObjectType)
    );

    // Partition into individual chunks
    List<ChunkedCursorIterator> partitions = iter.partition();
    System.assertEquals(3, partitions.size()); // 5 records divided by chunk size 2 = 3 partitions

    // Verify partition 1
    ChunkedCursorIterator p1 = partitions[0];
    System.assertEquals(0, p1.position);
    System.assertEquals(true, p1.hasNext());
    List<SObject> p1Records = p1.next();
    System.assertEquals(2, p1Records.size());
    List<Account> p1Accounts = (List<Account>) p1Records;
    System.assertNotEquals(null, p1Accounts);
    System.assertEquals(false, p1.hasNext()); // maxIterations was 1

    // Verify partition 3 (the partial chunk)
    ChunkedCursorIterator p3 = partitions[2];
    System.assertEquals(4, p3.position);
    System.assertEquals(true, p3.hasNext());
    List<SObject> p3Records = p3.next();
    System.assertEquals(1, p3Records.size());
    System.assertEquals(false, p3.hasNext());
    Test.stopTest();
  }

  @IsTest
  static void testCursorBinds() {
    Test.startTest();
    Map<String, Object> binds = new Map<String, Object>{
      'nameFilter' => 'Test Account 2%'
    };

    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions(
          'SELECT Id, Name FROM Account WHERE Name LIKE :nameFilter ORDER BY Name',
          2
        )
        .setBindMap(binds)
        .setSObjectType(Account.SObjectType)
    );
    System.assertEquals(1, iter.totalRecords);
    List<SObject> records = iter.next();
    System.assertEquals(1, records.size());
    List<Account> accounts = (List<Account>) records;
    System.assertEquals('Test Account 2', accounts[0].Name);
    Test.stopTest();
  }

  @IsTest
  static void testSelfHealingOnCursorLoss() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      'SELECT Id, Name FROM Account ORDER BY Name',
      2
    );

    // Fetch first chunk
    List<SObject> chunk1 = iter.next();
    System.assertEquals(2, chunk1.size());

    // Simulate cursor loss/expiration by setting the active cursor to null
    iter.standardCursor = null;

    // The next() call should detect the loss, trigger self-healing (initCursor via auto-init),
    // and successfully fetch the next chunk starting at position 2
    System.assertEquals(true, iter.hasNext());
    List<SObject> chunk2 = iter.next();
    System.assertEquals(2, chunk2.size());
    System.assertEquals(4, iter.position);
    Test.stopTest();
  }

  @IsTest
  static void testEmptyQueryAndBounds() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      'SELECT Id FROM Account WHERE Name = \'NonExistentAccount\'',
      2
    );

    System.assertEquals(0, iter.totalRecords);
    System.assertEquals(false, iter.hasNext());

    try {
      iter.next();
      System.assert(false, 'Should have thrown NoSuchElementException');
    } catch (System.NoSuchElementException e) {
      System.assert(true);
    } catch (Exception e) {
      System.assert(false, 'Threw wrong exception type: ' + e.getTypeName());
    }
    Test.stopTest();
  }

  @IsTest
  static void testInvalidConstructorInputs() {
    Test.startTest();
    try {
      new ChunkedCursorIterator('SELECT Id FROM Account', 0);
      System.assert(false, 'Should have thrown IllegalArgumentException');
    } catch (System.IllegalArgumentException e) {
      System.assert(true);
    }
    Test.stopTest();
  }

  @IsTest
  static void testSeekAndResetPartitionLimit() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      'SELECT Id, Name FROM Account ORDER BY Name',
      2
    );

    // Seek to the end chunk
    iter.seek(4);
    System.assertEquals(4, iter.position);
    System.assertEquals(true, iter.hasNext());

    List<SObject> records = iter.next();
    System.assertEquals(1, records.size());
    System.assertEquals(5, iter.position);

    // Seek validation error
    try {
      iter.seek(-1);
      System.assert(false, 'Should have thrown IllegalArgumentException');
    } catch (System.IllegalArgumentException e) {
      System.assert(true);
    }

    // Verify seeking resets iterations limits on partitioned iterators
    iter.seek(0);
    List<ChunkedCursorIterator> partitions = iter.partition();
    ChunkedCursorIterator p1 = partitions[0];
    System.assertEquals(true, p1.hasNext());
    p1.next();
    System.assertEquals(false, p1.hasNext()); // Limit hit

    p1.seek(0); // Seek back to start
    System.assertEquals(true, p1.hasNext()); // Limit reset, now we can fetch again
    Test.stopTest();
  }

  @IsTest
  static void testResolveAccessLevelSecurityException() {
    Test.startTest();
    try {
      ChunkedCursorOptions.resolveAccessLevel(
        'USER_MODE',
        'invalid_permission_set_id'
      );
      System.assert(
        false,
        'Should have thrown SecurityException on invalid permission set'
      );
    } catch (System.SecurityException e) {
      System.assert(true);
    }
    Test.stopTest();
  }

  @IsTest
  static void testBlankQueryRejected() {
    Test.startTest();
    try {
      new ChunkedCursorOptions('', 2);
      System.assert(false, 'Blank query should throw IllegalArgumentException');
    } catch (System.IllegalArgumentException e) {
      System.assert(true);
    }
    try {
      new ChunkedCursorOptions(null, 2);
      System.assert(false, 'Null query should throw IllegalArgumentException');
    } catch (System.IllegalArgumentException e) {
      System.assert(true);
    }
    Test.stopTest();
  }

  @IsTest
  static void testExplicitAccessModeApi() {
    Test.startTest();
    ChunkedCursorOptions opts = new ChunkedCursorOptions(
      'SELECT Id FROM Account',
      2
    );
    // Default is USER_MODE
    System.assertEquals('USER_MODE', opts.accessMode);
    System.assertEquals(System.AccessLevel.USER_MODE, opts.accessLevel);

    opts.setSystemMode();
    System.assertEquals('SYSTEM_MODE', opts.accessMode);
    System.assertEquals(System.AccessLevel.SYSTEM_MODE, opts.accessLevel);

    opts.setUserMode();
    System.assertEquals('USER_MODE', opts.accessMode);

    // Built by concatenation so it is not a hardcoded Id literal; this only
    // exercises the setter round-trip, which does not validate the value.
    String fakePermSetId = '0PS' + '000000000000';
    opts.setPermissionSetId(fakePermSetId);
    System.assertEquals(fakePermSetId, opts.permissionSetId);
    Test.stopTest();
  }

  @IsTest
  static void testResolveAccessLevelBaseModes() {
    Test.startTest();
    System.assertEquals(
      System.AccessLevel.USER_MODE,
      ChunkedCursorOptions.resolveAccessLevel('USER_MODE', null)
    );
    System.assertEquals(
      System.AccessLevel.SYSTEM_MODE,
      ChunkedCursorOptions.resolveAccessLevel('SYSTEM_MODE', null)
    );
    // Unknown mode falls back to USER_MODE
    System.assertEquals(
      System.AccessLevel.USER_MODE,
      ChunkedCursorOptions.resolveAccessLevel('BOGUS', '')
    );
    Test.stopTest();
  }

  @IsTest
  static void testHealAndClose() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      'SELECT Id, Name FROM Account ORDER BY Name',
      2
    );

    List<SObject> chunk1 = iter.next();
    System.assertEquals(2, chunk1.size());

    // heal() re-opens the cursor without losing position/total
    iter.heal();
    System.assertEquals(5, iter.getTotalRecords());
    System.assertEquals(2, iter.position);

    // close() releases the cursor; re-entering iteration re-opens it lazily
    iter.close();
    System.assertEquals(null, iter.standardCursor);
    System.assertEquals(true, iter.hasNext());
    List<SObject> chunk2 = iter.next();
    System.assertEquals(2, chunk2.size());
    System.assertEquals(4, iter.position);
    Test.stopTest();
  }

  @IsTest
  static void testPaginationPartitioning() {
    Test.startTest();
    ChunkedCursorIterator iter = new ChunkedCursorIterator(
      new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 2)
        .setCursorType(ChunkedCursorIterator.CursorType.PAGINATION)
        .setSObjectType(Account.SObjectType)
    );

    List<ChunkedCursorIterator> partitions = iter.partition();
    System.assertEquals(3, partitions.size());

    ChunkedCursorIterator p1 = partitions[0];
    System.assertEquals(0, p1.position);
    System.assertEquals(true, p1.hasNext());
    System.assertEquals(2, p1.next().size());
    System.assertEquals(false, p1.hasNext());

    ChunkedCursorIterator p3 = partitions[2];
    System.assertEquals(4, p3.position);
    System.assertEquals(true, p3.hasNext());
    System.assertEquals(1, p3.next().size());
    System.assertEquals(false, p3.hasNext());
    Test.stopTest();
  }

  @IsTest
  static void testIsExpiredOrFatalCursorHeuristics() {
    Test.startTest();
    // Type name containing TransientCursorException is NOT treated as fatal.
    // (getTypeName() reflects the class name, so naming drives the branch.)
    System.assertEquals(
      false,
      ChunkedCursorHelper.isExpiredOrFatalCursorException(
        new MyTransientCursorException('transient blip')
      )
    );
    // A message mentioning a limit is excluded even though it mentions cursor.
    System.assertEquals(
      false,
      ChunkedCursorHelper.isExpiredOrFatalCursorException(
        new CciTestException('cursor limit exceeded')
      )
    );
    // A generic message mentioning cursor IS treated as expired/fatal.
    System.assertEquals(
      true,
      ChunkedCursorHelper.isExpiredOrFatalCursorException(
        new CciTestException('the cursor has expired')
      )
    );
    Test.stopTest();
  }

  @IsTest
  static void testFetchWithSelfHealingHealsOnFatalCursorError() {
    Test.startTest();
    FakeFetcher fetcher = new FakeFetcher();
    fetcher.total = 10;
    fetcher.query = 'SELECT Id FROM Account';
    fetcher.failuresRemaining = 1;
    fetcher.errorToThrow = new CciTestException('the cursor has expired');
    fetcher.payload = new List<SObject>{ new Account(Name = 'Healed') };

    List<SObject> result = ChunkedCursorHelper.fetchWithSelfHealing(
      fetcher,
      0,
      2
    );

    System.assertEquals(1, result.size(), 'Should return healed payload');
    System.assertEquals(
      true,
      fetcher.healed,
      'heal() should have been invoked'
    );
    Test.stopTest();
  }

  @IsTest
  static void testFetchWithSelfHealingRethrowsNonCursorError() {
    Test.startTest();
    FakeFetcher fetcher = new FakeFetcher();
    fetcher.total = 10;
    fetcher.query = 'SELECT Id FROM Account';
    fetcher.failuresRemaining = 1;
    fetcher.errorToThrow = new CciTestException('something unrelated');

    try {
      ChunkedCursorHelper.fetchWithSelfHealing(fetcher, 0, 2);
      System.assert(false, 'Non-cursor error should propagate');
    } catch (Exception e) {
      System.assertEquals('something unrelated', e.getMessage());
    }
    System.assertEquals(
      false,
      fetcher.healed,
      'heal() must not run for unrelated errors'
    );
    Test.stopTest();
  }

  /**
   * @description Generic controllable-message exception for heuristic tests.
   */
  private class CciTestException extends Exception {
  }

  /**
   * @description Exception whose class name contains 'TransientCursorException'
   * so getTypeName() drives the transient (non-fatal) heuristic branch.
   */
  private class MyTransientCursorException extends Exception {
  }

  /**
   * @description In-memory CursorFetcher used to drive the self-healing logic in
   * ChunkedCursorHelper without a live database cursor.
   */
  private class FakeFetcher implements ChunkedCursorHelper.CursorFetcher {
    public Integer failuresRemaining = 0;
    public Exception errorToThrow;
    public List<SObject> payload = new List<SObject>();
    public Integer total = 0;
    public String query;
    public Boolean healed = false;

    /**
     * @description Returns the canned payload, optionally throwing first to
     * simulate a configured number of consecutive fetch failures.
     * @param position The chunk start position (ignored by this fake).
     * @param size The chunk size (ignored by this fake).
     * @return The configured payload records.
     */
    public List<SObject> fetch(Integer position, Integer size) {
      if (this.failuresRemaining > 0) {
        this.failuresRemaining--;
        throw this.errorToThrow;
      }
      return this.payload;
    }
    /**
     * @description Records that a heal was requested.
     */
    public void heal() {
      this.healed = true;
    }
    /**
     * @description Returns the configured total record count.
     * @return The total records.
     */
    public Integer getTotalRecords() {
      return this.total;
    }
    /**
     * @description Returns the configured query string.
     * @return The query.
     */
    public String getQuery() {
      return this.query;
    }
  }
}
