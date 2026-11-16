# Persistence

Thread persists all state as binary property-list snapshots under its data directory (`~/Documents/thread-db` by default; see Data Directory). There is no WAL and no memory-mapped store — durability is debounced, rate-limited full-file saves with startup reconciliation sweeps.

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

- **Hot path (put)** — `TableMutator` and `RegistryMutator` update in-memory caches immediately and ask for a full-file save a second after a burst; the table and graph ask together. `ThreadCache` keeps one background write per file in flight: it writes the snapshot as it is when the write starts (never an older value), skips a value already on disk, folds the asks made meanwhile into one more write, and then rests nine times as long as the write took. A 660 MB table on an external drive at 28 MB/s (24 s a write) is written about every 4 minutes instead of queueing a copy of itself behind every write; a small one on an internal disk still lands within a second or two.
- **Cold path (remove, access update, group rename, shutdown)** — saved immediately (`saveNow`).
- All disk I/O routes through a per-cache `PersistenceActor` so concurrent saves never race on the same file.
- **Nothing is migrated, but one layout step.** A file that is absent or no longer decodes reads as absent, and the node starts it fresh. The exception is a flat `documents/` folder from before the shards: at start-up it is renamed `documents-flat/` and a fresh `documents/` is started, two operations. Its files are never listed, moved or deleted: on exFAT through macOS's FSKit driver a folder of ~230k entries takes over ten minutes to list and ~10 s per change, while a file in it opens by name in milliseconds. A registered document missed in its shard is copied in by name at start-up (eight at a time, ~30 min once for 59k documents on an external drive), and a parts file the first time a search needs it. Only an id found in neither place is dropped. Once every node on the data directory has started, `documents-flat/` holds only copies and stale files and can be deleted whole.
- **Abandoned saves go.** A process stopped mid-write leaves its atomic save's whole temporary copy (`<name>.sb-<random>`) at the root; `FilePersistence.configure` removes those untouched for ten minutes.

---

## Startup Reconciliation

`Database.initializeTable()` closes the crash window between saves (up to a few minutes for a large table on a slow disk):

1. Restore `table-<nodeId>` and `graph-<nodeId>`.
2. **Sweep 1** — table documents absent from the registry are removed from the table and detached from the graph.
3. **Sweep 2** — registry documents with no table index (crash between a registry save and the table's) are dropped from the registry, so re-ingest is not skipped by the dedup check. Their files stay: `documents/` is shared by co-located nodes, and re-ingest rewrites them.

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
