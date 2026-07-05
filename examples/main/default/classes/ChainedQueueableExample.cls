/**
 * @description Example class demonstrating how to chain Queueable jobs using ChunkedCursorIterator.
 * Demonstrates state serialization and self-healing cursors across transaction boundaries.
 */
public inherited sharing class ChainedQueueableExample implements Queueable {
    
    private ChunkedCursorIterator iterator;

    /**
     * @description Constructor to initialize the queueable job with a ChunkedCursorIterator instance.
     * @param iterator The iterator managing the cursor state.
     */
    public ChainedQueueableExample(ChunkedCursorIterator iterator) {
        this.iterator = iterator;
    }

    /**
     * @description Executes the queueable job. Processes a single chunk of records,
     * updates the iterator state, and chains the next queueable execution if more records remain.
     * @param context The Queueable execution context.
     */
    public void execute(QueueableContext context) {
        // 1. Check if the iterator has remaining records to process.
        if (iterator.hasNext()) {
            // 2. Fetch the next chunk of records. 
            // If the transaction boundary reset the transient database cursor, next() automatically self-heals.
            List<SObject> recordChunk = iterator.next();
            
            // 3. Process the records within the current transaction limits.
            processRecords(recordChunk);
            
            // 4. If more chunks are available, enqueue the next job passing the updated iterator state.
            // Salesforce automatically serializes the 'iterator' instance variable.
            if (iterator.hasNext() && !Test.isRunningTest()) {
                System.enqueueJob(new ChainedQueueableExample(iterator));
            }
        }
    }

    /**
     * @description Processing method representing business logic.
     * @param records The chunk of records to process.
     */
    private void processRecords(List<SObject> records) {
        for (SObject record : records) {
            System.debug('Processing record: ' + record.Id);
            // Implement business logic here (e.g., updates, calls to external services)
        }
    }
}
