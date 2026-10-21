# Concurrency — The Write Queue, RegistryMutator, PersistenceActor

Sewn's write path is serialized through a very small set of concurrency
primitives. There are three, and that is the whole story:

| Primitive | Where | Serializes |
|-----------|-------|-----------|
| `SewnCore`'s `WriteJob` FIFO queue | `Sources/Sewn/Core/SewnCore.swift` | Every index put and owner-wide remove (put / removeAll) |
| `RegistryMutator` (actor) | `Sources/Sewn/Core/Mutators/RegistryMutator.swift` | Billing-stat writes and Thread node tracking |
| `PersistenceActor` (actor) | `Sources/Sewn/Utilities/Persistence/PersistenceActor.swift` | Disk I/O for one file |

> **Historical note.** `TableMutator`, `PersonalHNSWMutator`, and the standalone
> `IndexQueue` actor are gone. They existed to protect a local HNSW graph and PQ
> index; both moved to Thread. The `IndexQueue`'s job — one heavy write in flight
> at a time — now lives inside the `SewnCore` actor as the `WriteJob` queue.

---

## The Core Problem: Last-Write-Wins

Without serialization, concurrent writes to the same persisted state produce
this race:

```
Request A:  load registry → mutate → save registry [A's version]
Request B:            load registry → mutate → save registry [B's version, overwrites A]
```

A's mutation is silently dropped. No error, no panic, no log. For billing state
that means an owner's earnings quietly fail to accumulate.

The fix is uniform: route every mutation through an actor, which Swift's runtime
serializes for you.

---

## The WriteJob Queue

`Sources/Sewn/Core/SewnCore.swift`

```swift
private enum WriteJob {
    case put([SewnCore.BatchPutItem], SewnRequest)
    case removeAll(ownerId: String, request: SewnRequest, CheckedContinuation<Int, Never>)
}
private var pending: [WriteJob] = []
private var isProcessing = false
```

### Why it exists

Actor isolation alone is not enough. `putBatch` and `removeAll` both fan out to
Thread, and a `removeAll` that interleaves mid-`putBatch` can remove documents
the put is still writing — Thread would see the operations out of order. The
queue provides the ordering guarantee: **at most one heavy write in flight, in
submission order.**

### Public API

```swift
func enqueuePut(_ items: [SewnCore.BatchPutItem], request: SewnRequest)    // fire-and-forget
func removeAll(ownerId: String, request: SewnRequest) async -> Int         // awaitable
```

`enqueuePut` returns immediately; the job runs when the queue drains to it.
`removeAll` suspends the caller so a purge handler can return an accurate
count. Per-document removes (`_removeBatch`, from `/v1/modify`) are not queued.

### The drain loop and put coalescing

```swift
private func enqueue(_ job: WriteJob) {
    pending.append(job)
    SewnMetrics.indexQueueDepth.record(Double(pending.count))
    guard !isProcessing else { return }   // ← a second drain can never start
    isProcessing = true
    Task { await self.drain() }
}
```

`drain()` does something the old `IndexQueue` did not: it **merges consecutive
put jobs**.

```swift
private static let maxCoalesceItems = 100

// inside drain():
if case .put(let firstItems, let baseReq) = pending[0] {
    var merged = firstItems
    var consumed = 1
    while consumed < pending.count && merged.count < Self.maxCoalesceItems {
        guard case .put(let nextItems, let nextReq) = pending[consumed],
              Self.canCoalesce(nextReq, into: baseReq) else { break }
        merged.append(contentsOf: nextItems)
        consumed += 1
    }
    pending.removeFirst(consumed)
    await execute(.put(merged, baseReq))
}
```

Four constraints hold the merge together (`canCoalesce` checks the first three),
and all four matter:

1. **Same `ownerId`** — a merged job carries one `SewnRequest`, so mixing owners
   would attribute documents to the wrong person.
2. **Same `group.id`** — likewise for group placement.
3. **Same `callerApp`** — on a shared stack the merged batch goes to one app's
   Thread.
4. **`maxCoalesceItems = 100`** — bounds the fan-out payload. gRPC accepts up to
   100 MB, but a single unbounded batch would also hold the queue for its whole
   duration.

The loop `break`s rather than skipping, so ordering is never reordered — a
`removeAll` between two puts stops the merge.

### Actor reentrancy is the mechanism

When `execute(job)` suspends on a fan-out, new jobs arriving from concurrent HTTP
requests accumulate in `pending` on the actor's queue. They cannot execute,
because `isProcessing` is still `true`. When `execute` resumes, the `while` loop
picks up the next job immediately — no polling, no sleep.

### The removeAll continuation

```swift
func removeAll(ownerId: String, request: SewnRequest) async -> Int {
    await withCheckedContinuation { continuation in
        enqueue(.removeAll(ownerId: ownerId, request: request, continuation))
    }
}
```

The continuation travels inside the job. `execute` resumes it only after the work
actually completes — after every earlier job in the queue has finished.

> Note the current return value: `_removeAll` broadcasts
> `fanoutRemove(documentIds: [], ownerId:)` and returns **0**, because Sewn no
> longer keeps a local document list to count. Thread does the filtering. Any
> caller that reports a purged count to a user is reporting zero.

### Metrics

`SewnMetrics.indexQueueDepth` (`sewn.index.queue_depth`) is recorded on every
enqueue and every dequeue, and zeroed when the queue drains. If it grows without
bound, ingestion is outpacing Thread. `sewn.index.queue_items` is declared but
never recorded.

---

## RegistryMutator

`Sources/Sewn/Core/Mutators/RegistryMutator.swift`

Two responsibilities, which is worth internalizing because the name suggests one:

1. **Billing stats** — `SewnRegistry.documentStats` earnings and performance.
2. **Thread node tracking** — the live fleet used for fan-out routing.

Document, group, and ownership data is **not** here. Thread owns it.

### The debounced save is the durability mechanism

Billing writes are hot-path: every inference accumulates earnings and
performance. Rewriting the whole property list each time would be absurd, so
mutations mark the registry dirty and one rewrite follows a second later,
whatever accumulated.

So the flow is:

```
accumulateEarnings / accumulatePerformance
    │
    ├─ loadedRegistry()          — cache.load, first access only
    ├─ registry.addEarnings(…)   — mutate the local copy
    ├─ cache.update(registry)    — in-memory snapshot is now current
    └─ scheduleSave()            — one saveAsync a second later
```

```swift
private func scheduleSave() {
    registryDirty = true
    guard flushTask == nil else { return }   // coalesce; don't stack flush tasks
    flushTask = Task {
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        self.flushIfDirty()
    }
}
```

The `flushTask == nil` guard collapses many rapid mutations into one disk write
per second. Note the `catch { return }` — a cancelled sleep does **not** flush.

### flushForShutdown()

```swift
func flushForShutdown() async {
    guard let registry = cache.snapshot else { return }
    await cache.saveNow(registry)
    registryDirty = false
    flushTask?.cancel()
    flushTask     = nil
}
```

`SewnCore.shutdown()` calls it, so a clean shutdown writes what the pending flush
would have. Skipping it loses at most the last second of billing stats.

### nonisolated snapshot

```swift
nonisolated var snapshot: SewnRegistry? { cache.snapshot }
nonisolated func seed(_ initial: SewnRegistry) { cache.seed(initial) }
```

Route handlers that only read billing stats call `snapshot` — synchronous, no
actor hop, a shared read lock inside `ReadWriteValue`. Many concurrent requests
read simultaneously without blocking each other or the mutator.

### Thread node tracking

```swift
private var nodes: [UUID: ThreadNode] = [:]
private var ownerThreadMap: [String: Set<UUID>] = [:]
```

| Method | Behavior |
|--------|----------|
| `registerNode(_:)` | Stores the node; applies `THREAD_HOST_OVERRIDE` when set; ignores a node id already registered for another app; evicts a stale entry of the same app at the same host/port |
| `heartbeatNode(threadId:)` | Refreshes `lastSeen` |
| `updateNodeAvailability(threadId:accepting:)` | Toggles `acceptingStorage` |
| `removeNode(threadId:)` | Session closed |
| `registeredNode(threadId:)` | The node, active or not — the registration service's ownership check |
| `activeNodes(in:)` / `availableForStorage(in:)` / `allNodes(in:)` | Fan-out target sets, filtered by a `NodeScope` |
| `recordOwnerThread(ownerId:threadId:)` | Owner → node affinity after a successful index |
| `threadNodesForOwner(_:scopedNodes:)` | Affinity lookup; falls back to the scoped nodes when unknown |

A node is active for **60 seconds** after its last heartbeat; `allNodes(in:)`
prunes nodes unseen for **300 seconds**.

---

## PersistenceActor

`Sources/Sewn/Utilities/Persistence/PersistenceActor.swift`

One actor per logical file. `FilePersistence.save` is not thread-safe — two
concurrent calls on the same URL race on `data.write(to:)` and on the
`fileExists → createFile` branch. The actor gives serial execution without
blocking a thread.

```swift
actor PersistenceActor {
    func save<T: Codable>(_ value: T)     // serialized write
    func restore<T: Codable>() -> T?      // serialized read, sees the latest committed state
    func purge()                          // deletes the backing file
}
```

`restore()` runs on the same executor as `save()`, so it waits for any in-flight
save — `load` after a `saveAsync` always sees the newer value.

### Live instances

| Owner | File |
|-------|------|
| `SewnCache<SewnRegistry>` in `RegistryMutator` | `registry` |
| `SewnCache<SinatraRegistry>` in `Sinatra` | `sinatra/registry` |
| `Gita` | `wallet_registry` (via `FilePersistence` directly) |
| `SewnCore.Document` / conversation helpers | `documents/{id}`, `conversations/{id}` |
| `Personality` | `personalities` |

**Never share one `PersistenceActor` between two files.** A restore of file A
would queue behind an unrelated save of file B.

---

## Actor Call Flow — One Index Request

```
POST /v1/embeddings
    │
    ├─ TextChunker + TagGenerator          (synchronous, no actor)
    │
    ├─ await sewn.enqueuePut(items, request:)     ← fire-and-forget
    │   │
    │   └─ (when the FIFO drains to this job, possibly merged with neighbours)
    │       └─ putBatch(items, request:)
    │           └─ fanoutIndex(partitions:request:)   → ONE Thread node
    │                └─ on success: registryMutator.recordOwnerThread(…)
    │
    └─ Response already sent to the client
```

Embedding, PQ training, and HNSW insertion all happen on the Thread node. Sewn's
share of the work is chunking, tagging, placement, and remembering where it went.

---

## Rules for New Code

1. **Route every index put and owner-wide remove through `enqueuePut` /
   `removeAll`.** Calling `putBatch` or `_removeAll` directly bypasses the
   ordering guarantee.
2. **Never mutate `SewnRegistry` outside `RegistryMutator`.** There is no
   legitimate reason to.
3. **Every new billing mutation calls `scheduleSave()` after `cache.update`.**
   Mutating `cache` without scheduling a save produces state that silently
   vanishes on restart.
4. **Shutdown saves with `saveNow`,** never `saveAsync`.
5. **One `PersistenceActor` per file.**
6. **Read hot paths through `nonisolated` snapshots,** not by hopping to the
   actor.
7. **Preserve the coalescing constraints.** If you widen the merge in `drain()`,
   `ownerId` and `group.id` equality are what keep documents attributed
   correctly.
