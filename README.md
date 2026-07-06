# ChunkedCursorIterator for Salesforce Apex

A serializable and resilient custom iterator implementation for Apex database cursors. It supports `Database.Cursor` and `Database.PaginationCursor`, implementing the `Iterable<List<SObject>>` and `Iterator<List<SObject>>` interfaces.

---

## Technical Capabilities

- **State Serialization**: Captures query, position, chunk size, bind variables, and access level. Enables persistence of iteration state across execution boundaries (e.g., Queueable chaining, Batch Apex).
- **Automatic Error Recovery (Self-Healing)**: Catches cursor-related exceptions (e.g., `FatalCursorException`, `TransientCursorException`) and re-initializes the underlying cursor using the serialized state, resuming execution from the last recorded index.
- **Target Type Cast Enforcement**: Accepts `Schema.SObjectType` configurations to instantiate typed lists (`List<Account>`) instead of generic `List<SObject>`.
- **Dataset Partitioning**: Splits the remaining record range into independent single-chunk iterator instances via the `.partition()` method to support parallel asynchronous execution.
- **Dynamic Binding**: Accepts query bind variable maps to support dynamic SOQL binding.
- **Automatic Resource Release**: Automatically nullifies cursor references when `hasNext()` evaluates to `false` or when the iterator is exhausted.

---

## System Prerequisites and Deployment

### Prerequisites

- Salesforce CLI (`sf` command-line utility)
- Authenticated target Salesforce environment

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

## Configuration: `ChunkedCursorOptions`

Iterators are configured through the `ChunkedCursorOptions` builder. Construct it
with the required query and chunk size, then chain optional settings. Every setter
returns the same `ChunkedCursorOptions` instance for fluent chaining.

```apex
ChunkedCursorOptions options = new ChunkedCursorOptions(
    'SELECT Id, Name FROM Account ORDER BY Name',
    200
  )
  .setSObjectType(Account.SObjectType)
  .setUserMode()
  .setCursorType(ChunkedCursorIterator.CursorType.PAGINATION);

ChunkedCursorIterator iter = new ChunkedCursorIterator(options);
```

| Builder Method                                              | Description                                                                                                                                                                            |
| :---------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `new ChunkedCursorOptions(String query, Integer chunkSize)` | Required. Throws `IllegalArgumentException` on a blank query or a chunk size `<= 0`. Defaults to `USER_MODE` and the `STANDARD` cursor type.                                           |
| `setBindMap(Map<String, Object> bindMap)`                   | Supplies bind variables for the dynamic SOQL query.                                                                                                                                    |
| `setSObjectType(Schema.SObjectType sObjectType)`            | Enables typed list instantiation (e.g. `List<Account>`) instead of a generic `List<SObject>`.                                                                                          |
| `setUserMode()`                                             | Runs the query in `USER_MODE` (enforces FLS, CRUD, and sharing). This is the default.                                                                                                  |
| `setSystemMode()`                                           | Runs the query in `SYSTEM_MODE` (bypasses FLS/CRUD; sharing still applies).                                                                                                            |
| `setPermissionSetId(String permissionSetId)`                | Applies a permission set on top of the base mode. The serialization-safe way to elevate access.                                                                                        |
| `setAccessLevel(System.AccessLevel accessLevel)`            | Sets the access level from a prebuilt `System.AccessLevel`. Prefer the mode/permission-set setters, since a permission set embedded in an `AccessLevel` may not survive serialization. |
| `setCursorType(ChunkedCursorIterator.CursorType type)`      | Selects `STANDARD` or `PAGINATION`. Defaults to `STANDARD`.                                                                                                                            |

---

## Syntax and Usage Examples

### Standard Chunked Iteration

```apex
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    new ChunkedCursorOptions('SELECT Id, Name FROM Account ORDER BY Name', 200)
        .setSObjectType(Account.SObjectType)
);

for (List<SObject> chunk : iter) {
    List<Account> accounts = (List<Account>) chunk;
    // Process chunk elements
}
```

### Minimal Convenience Constructor

For the common case, skip the builder. This defaults to a `STANDARD` cursor in
`USER_MODE` and returns generic `List<SObject>` chunks.

```apex
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    'SELECT Id FROM Contact',
    1000
);
```

### Configured Pagination Cursor

```apex
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    new ChunkedCursorOptions('SELECT Id, Name, StageName FROM Opportunity', 500)
        .setAccessLevel(AccessLevel.USER_MODE)
        .setSObjectType(Opportunity.SObjectType)
        .setCursorType(ChunkedCursorIterator.CursorType.PAGINATION)
);
```

### Dynamic SOQL Bind Variables

```apex
Map<String, Object> binds = new Map<String, Object>{ 'minAmount' => 10000 };
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    new ChunkedCursorOptions('SELECT Id FROM Opportunity WHERE Amount >= :minAmount', 100)
        .setBindMap(binds)
);
```

### Elevated Access via Permission Set

```apex
ChunkedCursorIterator iter = new ChunkedCursorIterator(
    new ChunkedCursorOptions('SELECT Id, Name FROM Account', 200)
        .setUserMode()
        .setPermissionSetId(permissionSetId)
        .setSObjectType(Account.SObjectType)
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
      // Typed cast requires the iterator to have been built with
      // setSObjectType(Account.SObjectType).
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

- `ChunkedCursorIterator(String query, Integer chunkSize)` — convenience constructor; `STANDARD` cursor, `USER_MODE`, untyped chunks.
- `ChunkedCursorIterator(ChunkedCursorOptions options)` — full configuration via the [`ChunkedCursorOptions`](#configuration-chunkedcursoroptions) builder.

### Method Summary

| Method Signature               | Return Type                   | Description                                                                                                                                                                    |
| :----------------------------- | :---------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `iterator()`                   | `Iterator<List<SObject>>`     | Returns the iterator instance for use in a `for` loop.                                                                                                                         |
| `hasNext()`                    | `Boolean`                     | Evaluates if the current pointer position is less than the total records, or if iterations remaining is greater than zero.                                                     |
| `next()`                       | `List<SObject>`               | Retrieves the next subset of records based on configured chunk size. Automatically re-initializes the cursor if a cursor error is encountered.                                 |
| `seek(Integer targetPosition)` | `void`                        | Resets the pointer position to `targetPosition`. Validates that the index is between `0` and the total record count.                                                           |
| `partition()`                  | `List<ChunkedCursorIterator>` | Generates a list of independent iterator instances starting at sequential offsets matching the configured chunk size. Sets the maximum iteration limit of each partition to 1. |
| `close()`                      | `void`                        | Nullifies local references to standard and pagination cursor objects.                                                                                                          |

### Read-Only Properties

Exposed directly as properties (`get; private set;`), not accessor methods:

- `selectedCursorType`: The configured `CursorType` enum (`STANDARD` or `PAGINATION`).
- `position`: The current pointer index (`Integer`).
- `chunkSize`: The configured chunk size (`Integer`).
- `totalRecords`: The total number of records matching the query (`Integer`).

---

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option.
