# ChunkedCursorIterator for Salesforce Apex

A serializable and resilient custom iterator implementation for Apex database cursors. It supports `Database.Cursor` and `Database.PaginationCursor`, implementing the `Iterable<List<SObject>>` and `Iterator<List<SObject>>` interfaces.

---

## Technical Capabilities

*   **State Serialization**: Captures query, position, chunk size, bind variables, and access level. Enables persistence of iteration state across execution boundaries (e.g., Queueable chaining, Batch Apex).
*   **Automatic Error Recovery (Self-Healing)**: Catches cursor-related exceptions (e.g., `FatalCursorException`, `TransientCursorException`) and re-initializes the underlying cursor using the serialized state, resuming execution from the last recorded index.
*   **Target Type Cast Enforcement**: Accepts `Schema.SObjectType` configurations to instantiate typed lists (`List<Account>`) instead of generic `List<SObject>`.
*   **Dataset Partitioning**: Splits the remaining record range into independent single-chunk iterator instances via the `.partition()` method to support parallel asynchronous execution.
*   **Dynamic Binding**: Accepts query bind variable maps to support dynamic SOQL binding.
*   **Automatic Resource Release**: Automatically nullifies cursor references when `hasNext()` evaluates to `false` or when the iterator is exhausted.

---

## System Prerequisites and Deployment

### Prerequisites

*   Salesforce CLI (`sf` command-line utility)
*   Authenticated target Salesforce environment

### Deployment Command

Deploy the source components to the default org:

```bash
sf project deploy start
```

Deploy to a specific target org:

```bash
sf project deploy start --target-org <org-alias>
```

---

## Syntax and Usage Examples

### Standard Chunked Iteration

```apex
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    'SELECT Id, Name FROM Account ORDER BY Name', 
    200, 
    Account.SObjectType
);

for (List<SObject> chunk : iter) {
    List<Account> accounts = (List<Account>) chunk;
    // Process chunk elements
}
```

### Configured Pagination Cursor

```apex
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    'SELECT Id, Name, StageName FROM Opportunity', 
    500, 
    AccessLevel.USER_MODE,
    Opportunity.SObjectType
);
```

### Dynamic SOQL Bind Variables

```apex
Map<String, Object> binds = new Map<String, Object>{ 'minAmount' => 10000 };
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    'SELECT Id FROM Opportunity WHERE Amount >= :minAmount',
    binds,
    100
);
```

### Queueable Chaining State Preservation

```apex
public class AccountProcessingQueueable implements Queueable {
    private ChunkedCursorIterator iter;

    public AccountProcessingQueueable(ChunkedCursorIterator iter) {
        this.iter = iter;
    }

    public void execute(QueueableContext context) {
        if (iter.hasNext()) {
            List<Account> accounts = (List<Account>) iter.next();
            // Execute operations on accounts chunk
            
            if (iter.hasNext()) {
                System.enqueueJob(new AccountProcessingQueueable(iter));
            }
        }
    }
}
```

### Parallel Dataset Partitioning

```apex
ChunkedCursorIterator parentIter = new ChunkedCursorIterator(
    'SELECT Id FROM Contact',
    1000
);

List<ChunkedCursorIterator> parallelJobs = parentIter.partition();

for (ChunkedCursorIterator job : parallelJobs) {
    System.enqueueJob(new ContactProcessorQueueable(job));
}
```

---

## Class Interface Reference

### Constructor Summary

*   `ChunkedCursorIterator(String query, Integer chunkSize)`
*   `ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize)`
*   `ChunkedCursorIterator(String query, Integer chunkSize, Schema.SObjectType sObjectType)`
*   `ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, Schema.SObjectType sObjectType)`
*   `ChunkedCursorIterator(String query, Integer chunkSize, System.AccessLevel accessLevel)`
*   `ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, System.AccessLevel accessLevel)`
*   `ChunkedCursorIterator(String query, Integer chunkSize, System.AccessLevel accessLevel, Schema.SObjectType sObjectType)`
*   `ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, System.AccessLevel accessLevel, Schema.SObjectType sObjectType)`
*   `ChunkedCursorIterator(String query, Integer chunkSize, CursorType type)`
*   `ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, CursorType type)`
*   `ChunkedCursorIterator(String query, Integer chunkSize, CursorType type, Schema.SObjectType sObjectType)`
*   `ChunkedCursorIterator(String query, Map<String, Object> bindMap, Integer chunkSize, CursorType type, Schema.SObjectType sObjectType)`

### Method Summary

| Method Signature | Return Type | Description |
| :--- | :--- | :--- |
| `hasNext()` | `Boolean` | Evaluates if the current pointer position is less than the total records, or if iterations remaining is greater than zero. |
| `next()` | `List<SObject>` | Retrieves the next subset of records based on configured chunk size. Automatically calls cursor re-initialization if a cursor error is encountered. |
| `seek(Integer targetPosition)` | `void` | Resets the pointer position to `targetPosition`. Validates that the index is between `0` and the total record count. |
| `partition()` | `List<ChunkedCursorIterator>` | Generates a list of independent iterator instances starting at sequential offsets matching the configured chunk size. Sets the maximum iteration limit of each partition to 1. |
| `close()` | `void` | Nullifies local references to standard and pagination cursor objects. |
| `setSObjectType(Schema.SObjectType sObjectType)` | `ChunkedCursorIterator` | Configures the target type name used for list instantiations. |
| `getSObjectType()` | `Schema.SObjectType` | Resolves and returns the configured `Schema.SObjectType` token. |

### Property Getters

*   `getType()`: Returns the configured `CursorType` enum (`STANDARD` or `PAGINATION`).
*   `getPosition()`: Returns the current pointer index (`Integer`).
*   `getChunkSize()`: Returns the configured chunk size (`Integer`).
*   `getTotalRecords()`: Returns the total records cache size (`Integer`).
