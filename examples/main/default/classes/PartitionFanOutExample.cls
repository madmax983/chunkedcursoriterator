/**
 * @description Example class demonstrating how to partition a ChunkedCursorIterator
 * and fan out the resulting chunks across multiple parallel Queueable execution threads.
 */
public inherited sharing class PartitionFanOutExample {

    public class QueueableLimitException extends Exception {}

    /**
     * @description Orchestrates the partitioning and parallel execution of a dataset.
     * Takes a query and chunk size, partitions the dataset, and enqueues a Queueable job for each partition.
     * @param query The dynamic SOQL query string.
     * @param chunkSize The record count limit per partition chunk.
     */
    public static void executeParallelProcessing(String query, Integer chunkSize) {
        // 1. Initialize the parent ChunkedCursorIterator to define the total scope of the dataset.
        ChunkedCursorIterator parentIterator = new ChunkedCursorIterator(query, chunkSize);

        // 2. Partition the remaining records into independent single-chunk iterator instances.
        // Each partition instance has maxIterations set to 1 and starts at the correct offset position.
        List<ChunkedCursorIterator> partitions = parentIterator.partition();

        // 3. Enforce the Salesforce transaction limit for queueables (5 for synchronous, 1 for asynchronous).
        Integer remainingLimit = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
        if (partitions.size() > remainingLimit) {
            throw new QueueableLimitException(
                'Partition count (' + partitions.size() + ') exceeds the remaining transaction queueable limit (' + remainingLimit + '). ' +
                'Reduce query scope or increase chunk size to prevent partial enqueue failures.'
            );
        }

        // 4. Iterate through each partition and enqueue a separate Queueable thread.
        // This distributes the processing load in parallel within the org's asynchronous limits.
        for (ChunkedCursorIterator partition : partitions) {
            // We reuse the ChainedQueueableExample since its execution logic processes a single partition chunk.
            System.enqueueJob(new ChainedQueueableExample(partition));
        }
    }
}
