@isTest
private class ChunkedCursorIteratorTest {

    @testSetup
    static void setup() {
        // Create 5 test Accounts
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accounts.add(new Account(Name = 'Test Account ' + i));
        }
        insert accounts;
    }

    @isTest
    static void testStandardCursorHappyPath() {
        Test.startTest();
        // Create standard iterator with chunk size 2 and type safety
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id, Name FROM Account ORDER BY Name', 
            2,
            Account.SObjectType
        );

        System.assertEquals(ChunkedCursorIterator.CursorType.STANDARD, iter.getType());
        System.assertEquals(5, iter.getTotalRecords());
        System.assertEquals(2, iter.getChunkSize());
        System.assertEquals(0, iter.getPosition());
        System.assertEquals(Account.SObjectType, iter.getSObjectType());

        // We expect 3 chunks: size 2, size 2, size 1
        System.assertEquals(true, iter.hasNext());
        List<SObject> chunk1 = iter.next();
        System.assertEquals(2, chunk1.size());
        // Verify type safety: we can successfully cast the chunk directly
        List<Account> accounts1 = (List<Account>) chunk1;
        System.assertEquals(2, iter.getPosition());

        System.assertEquals(true, iter.hasNext());
        List<SObject> chunk2 = iter.next();
        System.assertEquals(2, chunk2.size());
        List<Account> accounts2 = (List<Account>) chunk2;
        System.assertEquals(4, iter.getPosition());

        System.assertEquals(true, iter.hasNext());
        List<SObject> chunk3 = iter.next();
        System.assertEquals(1, chunk3.size());
        List<Account> accounts3 = (List<Account>) chunk3;
        System.assertEquals(5, iter.getPosition());

        System.assertEquals(false, iter.hasNext());
        System.assertEquals(null, iter.getStandardCursor()); // Auto-close verification
        Test.stopTest();
    }

    @isTest
    static void testPaginationCursorHappyPath() {
        Test.startTest();
        // Create pagination iterator with chunk size 2 in USER_MODE
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id, Name FROM Account ORDER BY Name', 
            2,
            AccessLevel.USER_MODE,
            Account.SObjectType
        );

        System.assertEquals(ChunkedCursorIterator.CursorType.PAGINATION, iter.getType());
        System.assertEquals(5, iter.getTotalRecords());
        System.assertEquals(2, iter.getChunkSize());
        System.assertEquals(0, iter.getPosition());

        // Iterate through all chunks
        Integer chunkCount = 0;
        Integer totalProcessed = 0;
        for (List<SObject> chunk : iter) {
            chunkCount++;
            totalProcessed += chunk.size();
            List<Account> accounts = (List<Account>) chunk; // verify casting
        }

        System.assertEquals(3, chunkCount);
        System.assertEquals(5, totalProcessed);
        System.assertEquals(null, iter.getPaginationCursor()); // Auto-close verification
        Test.stopTest();
    }

    @isTest
    static void testExplicitCursorTypeConstructor() {
        Test.startTest();
        // Create iterator by explicitly specifying Pagination type
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id, Name FROM Account ORDER BY Name', 
            2,
            ChunkedCursorIterator.CursorType.PAGINATION,
            Account.SObjectType
        );

        System.assertEquals(ChunkedCursorIterator.CursorType.PAGINATION, iter.getType());
        System.assertEquals(5, iter.getTotalRecords());
        System.assertEquals(2, iter.getChunkSize());
        System.assertEquals(0, iter.getPosition());
        
        List<SObject> chunk = iter.next();
        System.assertEquals(2, chunk.size());
        Test.stopTest();
    }

    @isTest
    static void testSerializationAndDeserialization() {
        Test.startTest();
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id, Name FROM Account ORDER BY Name', 
            2,
            Account.SObjectType
        );

        // Fetch first chunk
        List<SObject> chunk1 = iter.next();
        System.assertEquals(2, chunk1.size());
        System.assertEquals(2, iter.getPosition());

        // Serialize state (verifies transient fields are handled properly)
        String serialized = JSON.serialize(iter);
        System.assertNotEquals(null, serialized);

        // Deserialize state to a new iterator
        ChunkedCursorIterator deserializedIter = (ChunkedCursorIterator) JSON.deserialize(
            serialized, 
            ChunkedCursorIterator.class
        );

        // Resume iteration on the deserialized instance (verifies auto-healing of null cursors)
        System.assertEquals(ChunkedCursorIterator.CursorType.STANDARD, deserializedIter.getType());
        System.assertEquals(2, deserializedIter.getPosition());
        System.assertEquals(5, deserializedIter.getTotalRecords());
        System.assertEquals(Account.SObjectType, deserializedIter.getSObjectType());

        System.assertEquals(true, deserializedIter.hasNext());
        List<SObject> chunk2 = deserializedIter.next();
        System.assertEquals(2, chunk2.size());
        List<Account> accounts2 = (List<Account>) chunk2; // verify post-deserialization type safety
        System.assertEquals(4, deserializedIter.getPosition());

        System.assertEquals(true, deserializedIter.hasNext());
        List<SObject> chunk3 = deserializedIter.next();
        System.assertEquals(1, chunk3.size());
        System.assertEquals(5, deserializedIter.getPosition());

        System.assertEquals(false, deserializedIter.hasNext());
        Test.stopTest();
    }

    @isTest
    static void testParallelPartitioning() {
        Test.startTest();
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id, Name FROM Account ORDER BY Name', 
            2,
            Account.SObjectType
        );

        // Partition into individual chunks
        List<ChunkedCursorIterator> partitions = iter.partition();
        System.assertEquals(3, partitions.size()); // 5 records divided by chunk size 2 = 3 partitions

        // Verify partition 1
        ChunkedCursorIterator p1 = partitions[0];
        System.assertEquals(0, p1.getPosition());
        System.assertEquals(true, p1.hasNext());
        List<SObject> p1Records = p1.next();
        System.assertEquals(2, p1Records.size());
        List<Account> p1Accounts = (List<Account>) p1Records;
        System.assertEquals(false, p1.hasNext()); // maxIterations was 1

        // Verify partition 3 (the partial chunk)
        ChunkedCursorIterator p3 = partitions[2];
        System.assertEquals(4, p3.getPosition());
        System.assertEquals(true, p3.hasNext());
        List<SObject> p3Records = p3.next();
        System.assertEquals(1, p3Records.size());
        System.assertEquals(false, p3.hasNext());
        Test.stopTest();
    }

    @isTest
    static void testCursorBinds() {
        Test.startTest();
        Map<String, Object> binds = new Map<String, Object>{ 'nameFilter' => 'Test Account 2%' };
        
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id, Name FROM Account WHERE Name LIKE :nameFilter ORDER BY Name',
            binds,
            2,
            Account.SObjectType
        );
        System.assertEquals(1, iter.getTotalRecords());
        List<SObject> records = iter.next();
        System.assertEquals(1, records.size());
        List<Account> accounts = (List<Account>) records;
        System.assertEquals('Test Account 2', accounts[0].Name);
        Test.stopTest();
    }

    @isTest
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
        System.assertEquals(4, iter.getPosition());
        Test.stopTest();
    }

    @isTest
    static void testEmptyQueryAndBounds() {
        Test.startTest();
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id FROM Account WHERE Name = \'NonExistentAccount\'',
            2
        );

        System.assertEquals(0, iter.getTotalRecords());
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

    @isTest
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

    @isTest
    static void testSeekAndResetPartitionLimit() {
        Test.startTest();
        ChunkedCursorIterator iter = new ChunkedCursorIterator(
            'SELECT Id, Name FROM Account ORDER BY Name', 
            2
        );

        // Seek to the end chunk
        iter.seek(4);
        System.assertEquals(4, iter.getPosition());
        System.assertEquals(true, iter.hasNext());

        List<SObject> records = iter.next();
        System.assertEquals(1, records.size());
        System.assertEquals(5, iter.getPosition());

        // Seek validation error
        try {
            iter.seek(-1);
            System.assert(false, 'Should have thrown IllegalArgumentException');
        } catch (System.IllegalArgumentException e) {
            System.assert(true);
        }
        
        // Verify seeking resets iterations limits on partitioned iterators
        List<ChunkedCursorIterator> partitions = iter.partition();
        ChunkedCursorIterator p1 = partitions[0];
        System.assertEquals(true, p1.hasNext());
        p1.next();
        System.assertEquals(false, p1.hasNext()); // Limit hit
        
        p1.seek(0); // Seek back to start
        System.assertEquals(true, p1.hasNext()); // Limit reset, now we can fetch again
        Test.stopTest();
    }
}
