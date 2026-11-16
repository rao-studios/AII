# Persistence

Thread persists all state as binary property-list snapshots under its data directory (`~/Documents/thread-db` by default; see Data Directory). There is no WAL and no memory-mapped store — durability is debounced full-file saves with startup reconciliation sweeps.

---

## Files (per node UUID)

| File | Contents |
|---|---|
| `table-<nodeId>` | `PartitionTable` — PQ codebooks, lean slots, entity linkage |
| `graph-<nodeId>` | `GraphStore` — entities, relationships and predicates (adjacency rebuilt on decode) |
| `registry-<nodeId>` | `ThreadRegistry` — ownership, groups, access, stats |
| `documents/{shard}/{id}` | `Database.Document` |
| `documents/{shard}/{id}-parts` | `[PartitionData]` — partition text/url/owner, loaded on demand; plus the caller-supplied embedding (fp32, little-endian) for partitions indexed with one, which the PQ table cannot reproduce |
| `node-id` | Persisted node UUID |

`{shard}` is two hex digits of the id's FNV-1a hash (`DocumentFiles`): 256 folders, the same in every process. One folder of every document made each name the disk does not hold (a save's temporary name, a missing file at start-up) a scan of the whole folder on a disk whose folders are unindexed, exFAT: lookups of seconds at 57k documents.

---

## Durability Model

- **Hot path (put)** — `TableMutator` and `RegistryMutator` update in-memory caches immediately and schedule a **1-second debounced** full-file save; the table and graph share one debounce so they flush together. `ThreadCache` keeps one background write per file in flight: it writes the snapshot as it is when the write starts (never an older value), skips a value already on disk, and folds the asks made meanwhile into one more write, so a save slower than the debounce (a large table) never queues copies of itself.
- **Cold path (remove, access update, group rename, shutdown)** — saved immediately (`saveNow`).
- All disk I/O routes through a per-cache `PersistenceActor` so concurrent saves never race on the same file.
- **Nothing is migrated, but one layout move.** A file that is absent or no longer decodes reads as absent, and the node starts it fresh. The exception is a flat `documents/` folder from before the shards: at start-up, before the registry loads, it is renamed `documents-flat/` and its files move into a fresh, sharded `documents/` (an emptied exFAT folder keeps its size). A move that stops resumes at the next start, and while files wait there the registry drops no document it cannot find.
- **Abandoned saves go.** A process stopped mid-write leaves its atomic save's whole temporary copy (`<name>.sb-<random>`) at the root; `FilePersistence.configure` removes those untouched for ten minutes.

---

## Startup Reconciliation

`Database.initializeTable()` closes the small crash window the debounce leaves open:

1. Restore `table-<nodeId>` and `graph-<nodeId>`.
2. **Sweep 1** — table documents absent from the registry are removed from the table and detached from the graph.
3. **Sweep 2** — registry documents with no table index (crash inside the debounce window) are dropped from the registry, so re-ingest is not skipped by the dedup check. Their files stay: `documents/` is shared by co-located nodes, and re-ingest rewrites them.

---

## Data Directory

Snapshot files, the knowledge graph, documents and `node-id` all live under one root, `FilePersistence.getDefaultURL()`: `~/Documents/thread-db` by default, `<AII_HOME>/aii/thread/db` on the shared stack, or whatever `AIIServer thread --data-dir <path>` / the `THREAD_DATA_DIR` environment variable names (the flag wins; tilde is expanded and the directory is created on startup). Mary launches Thread with `--data-dir ~/Documents/maryOS/thread-db`. Do not delete or move these files while the server is running.

---

## Key Files

| File | Purpose |
|---|---|
| [FilePersistence.swift](../../../../Sources/Thread/Utilities/Persistence/FilePersistence.swift) | Plist encode/decode, atomic writes, purge |
| [PersistenceActor.swift](../../../../Sources/Thread/Utilities/Persistence/PersistenceActor.swift) | Actor wrapper for file I/O serialization |
| [ThreadCache.swift](../../../../Sources/Thread/Utilities/Database/ThreadCache.swift) | Lock-protected snapshot + serialized saves |
| [NodeIdentity.swift](../../../../Sources/Thread/Utilities/Persistence/NodeIdentity.swift) | Stable per-process node UUID (used in Sewn registration) |
