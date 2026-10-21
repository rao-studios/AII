# GRPC

Thread's gRPC layer has two responsibilities: exposing search and index services directly (reachable by any gRPC client on `--grpc-port`), and maintaining a persistent bidirectional session stream with Sewn so traffic can flow through the mothership.

---

## Services

### ThreadQuery

Handles search, indexing, and document removal.

| RPC | Description |
|---|---|
| `Search` | Hybrid KG + PQ search. Accepts `query_text` (Thread embeds) or `query_embedding` (precomputed); optional `entities` for graph matching. Response carries a graph trace. |
| `Index` | Embed and index a batch of documents. Returns immediately; background write queue drains async. An item may describe its partitions itself (`partitions`, parallel to `texts`): a supplied `embedding` is used as-is — Thread does not embed that text — and is kept in `-parts`; a supplied `url` becomes that partition's address instead of the document's. Every partition of a document must share one dimensionality, a multiple of 16 (one PQ codebook slices them all); a text search skips any document stored at another width. |
| `Remove` | Remove specific document IDs, or all documents for an owner when `document_ids` is empty. |

Implementation: [ThreadQueryServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadQueryServiceImpl.swift)

### ThreadLibrary

Paginated document library.

| RPC | Description |
|---|---|
| `Library` | Paginated list of groups for an owner. `after_id` is a cursor; `limit` controls page size. |
| `Documents` / `ExportCorpus` | Full document content — partition texts in stored order. With `include_embeddings`, `partitions` also carries each partition's id, url and kept vector (present only where the caller supplied it at index time). |

Implementation: [ThreadLibraryServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadLibraryServiceImpl.swift)

### ThreadGraph

Knowledge-graph queries.

| RPC | Description |
|---|---|
| `Query` | Resolve seed entities by name and/or free-text similarity (Thread embeds `query`), traverse up to `hops` edges (0–3), return entities, relationships, linked documents, and graph stats. |

Implementation: [ThreadGraphServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadGraphServiceImpl.swift)

### ThreadUpdate

Group and document edits, and counts.

| RPC | Description |
|---|---|
| `UpdateGroup` | Access, label, and (with `update_metadata`) description and tags of a group the caller owns. |
| `UpdateDocument` | A document's access, or its move to another of the caller's groups. The group it left goes when that leaves it empty. |
| `Stats` | The caller's lane's counts; every lane's for the stack identity. |
| `RemoveGroups` | Deletes groups the caller owns in its lane: every document filed in each (unlinked; purged when the caller was its last owner), then the group, also an empty one. **Direct only**: it has no Session arm, and a trusted (session) caller is refused — a group delete is never fanned out. |

Implementation: [ThreadUpdateServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadUpdateServiceImpl.swift)

---

## Sewn Session — How It Works

When `--mothership-host` is provided, `MothershipRegistrationClient` starts and runs for the process lifetime.

### Phase 1 — Register

`register` RPC: Thread sends its UUID, HTTP host, gRPC port, and HTTP port. Sewn records the node and returns an acceptance signal. Thread retries every 5 s until accepted.

### Phase 2 — Session stream

`session` RPC: Thread opens a bidirectional stream and holds it open. Traffic flows in both directions over this single connection:

- **Thread → Sewn**: periodic pings every 30 s to keep the stream alive.
- **Sewn → Thread**: request payloads (search, index, remove, library, documents, graph, update, stats) wrapped in `ThreadSessionMessage`.

`MothershipRequestDispatcher` reads the `payload` oneof from each incoming message, calls the matching service impl, and writes the response back with the same `correlationID`.

### Phase 3 — Availability updates

`updateAvailability` RPC: one-shot call Thread makes when its storage capacity changes (e.g. after a large batch completes). Sewn uses this to steer new index requests toward nodes that are accepting storage.

### Reconnection

If the session stream drops, `MothershipRegistrationClient` sleeps 5 s and restarts the registration loop from Phase 1.

---

## Session Message Envelope

Every payload over the `session` stream is wrapped in `ThreadSessionMessage`:

```protobuf
message ThreadSessionMessage {
  string correlation_id = 1;   // ties each request to its response
  string thread_id       = 2;   // set by Thread so Sewn can route back to the right stream

  oneof payload {
    ThreadSessionPing            ping                      = 3;
    ThreadSessionPong            pong                      = 4;
    ThreadSearchRequest          search_request            = 5;
    ThreadSearchResponse         search_response           = 6;
    ThreadIndexRequest           index_request             = 7;
    ThreadIndexResponse          index_response            = 8;
    ThreadRemoveRequest          remove_request            = 9;
    ThreadRemoveResponse         remove_response           = 10;
    ThreadLibraryRequest         library_request           = 11;
    ThreadLibraryResponse        library_response          = 12;
    // 13–22 reserved (retired ThreadHNSW arms)
    ThreadUpdateGroupRequest     update_group_request      = 23;
    ThreadUpdateGroupResponse    update_group_response     = 24;
    ThreadUpdateDocumentRequest  update_document_request   = 25;
    ThreadUpdateDocumentResponse update_document_response  = 26;
    ThreadStatsRequest           stats_request             = 27;
    ThreadStatsResponse          stats_response            = 28;
    ThreadGraphQueryRequest      graph_request             = 29;
    ThreadGraphQueryResponse     graph_response            = 30;
    ThreadDocumentsRequest       documents_request         = 31;
    ThreadDocumentsResponse      documents_response        = 32;
  }
}
```

---

## Adding a New RPC

1. Add the message and RPC definition to `Protos/thread.proto` (shared by Sewn and Thread through Seam).
2. For an RPC Sewn may carry, add its request and response as `ThreadSessionMessage` oneof arms too.
3. Regenerate Swift stubs (`Scripts/generate-seam.sh`).
4. Implement the handler in the relevant `ServiceImpl` file: the direct-port method (it reads the caller's secret from the metadata) and the `caller: LaneCaller` one.
5. For a carried RPC: name the arms in Seam's `PayloadName`, add the session call to Seam's `ThreadQueryClient`, the `case` to `MothershipRequestDispatcher` (answer a failure, never return nil — Sewn would wait out its timeout), and Sewn's fan-out.

A destructive call that must stay on the caller's own authenticated connection gets no arm and no fan-out, and its handler refuses a `.trusted` caller — as `RemoveGroups` does.

---

## Key Files

| File | Purpose |
|---|---|
| [thread.proto](../../../../Protos/thread.proto) | Proto definitions for all messages and services |
| [MothershipRegistrationClient.swift](../../../../Sources/Seam/Client/MothershipRegistrationClient.swift) | Register, session loop, reconnection |
| [MothershipRequestDispatcher.swift](../../../../Sources/Thread/GRPC/MothershipRequestDispatcher.swift) | Route session messages to service impls |
| [ThreadGRPCServer.swift](../../../../Sources/Thread/GRPC/ThreadGRPCServer.swift) | gRPC server startup and service registration |
| [ThreadQueryServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadQueryServiceImpl.swift) | Search / Index / Remove |
| [ThreadLibraryServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadLibraryServiceImpl.swift) | Library pagination |
| [ThreadGraphServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadGraphServiceImpl.swift) | Graph query |
| [ThreadUpdateServiceImpl.swift](../../../../Sources/Thread/GRPC/ThreadUpdateServiceImpl.swift) | Group / document updates, stats |
