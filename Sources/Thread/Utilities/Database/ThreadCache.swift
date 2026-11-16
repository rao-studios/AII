//
//  ThreadCache.swift
//  Thread
//
//  Created by Ritesh Pakala on 03/20/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

/// Generic read-through cache with synchronous lock-protected reads and off-actor,
/// race-safe disk persistence.
///
/// Encapsulates the repeated `LockedValue<Value?> + FilePersistence` pattern shared
/// by `TableMutator` and `RegistryMutator`:
///
///  - **Read**: `cache.snapshot` is synchronous and never hops an actor.
///  - **Mutate**: call `cache.update(newValue)` inside the owning actor after
///    modifying the value, then `cache.saveLatest()` to persist off-actor.
///  - **First load**: `await cache.load { .init() }` suspends the calling actor
///    during the disk read so other work can proceed concurrently.
///
/// All disk I/O is routed through a `PersistenceActor` — one per cache instance —
/// so no two writes of the backing file ever overlap.
///
/// PIN: EVERY WRITE IS OF THE LATEST VALUE, AND ONLY WHEN IT CHANGED. A write reads the snapshot
///      when it starts on the persistence actor, never a value captured when it was asked for, so
///      writes land in the order the value changed and a write asked for earlier can never
///      overwrite a later one. A value already on disk (seeded from it, or written and not
///      changed since) is not written again: a shutdown with nothing new costs nothing.
/// PIN: ONE BACKGROUND WRITE AT A TIME. `saveLatest` asks for a write; asks made while one runs
///      fold into the next, so a write slower than the asks (a large table) never queues a copy of
///      the value behind it. `saveNow` writes at once.
final class ThreadCache<Value: Codable & Sendable>: @unchecked Sendable {
    private struct Held {
        var value: Value?
        /// Bumped on every change to `value`.
        var stamp: UInt64 = 0
    }

    private struct Schedule {
        var requested = false
        var running = false
    }

    private let _store: ReadWriteValue<Held>
    private let persistence: FilePersistence
    private let io: PersistenceActor
    private let schedule = LockedValue(Schedule())
    /// The stamp of the value on disk; nil until one is known to be there.
    private let written = LockedValue<UInt64?>(nil)

    init(persistence: FilePersistence) {
        self._store = ReadWriteValue(Held())
        self.persistence = persistence
        self.io = PersistenceActor(persistence: persistence)
    }

    // MARK: - Read

    /// Synchronous, concurrent-read snapshot. Multiple callers may read simultaneously —
    /// only writes are exclusive. Safe to call from any context without an actor hop.
    /// Returns `nil` until `seed` or `load` has been called.
    var snapshot: Value? { _store.withReadLock { $0.value } }

    // MARK: - Write

    /// Seeds the snapshot synchronously at startup with the value on disk. Safe to call from a
    /// `nonisolated` context — no actor hop required.
    func seed(_ value: Value) {
        let stamp = _store.withWriteLock { held -> UInt64 in
            held.value = value
            held.stamp &+= 1
            return held.stamp
        }
        written.withLock { $0 = stamp }
    }

    /// Updates the in-memory snapshot. Call from inside the owning actor after
    /// mutating the value; the write lock is held for microseconds.
    func update(_ value: Value) {
        _store.withWriteLock {
            $0.value = value
            $0.stamp &+= 1
        }
    }

    /// Asks for the latest snapshot to be written in the background. The calling actor is
    /// freed immediately; asks made while a write runs fold into one more write.
    func saveLatest() {
        let start = schedule.withLock { state -> Bool in
            state.requested = true
            guard !state.running else { return false }
            state.running = true
            return true
        }
        guard start else { return }
        Task.detached { [self] in await drain() }
    }

    /// Writes the latest snapshot now, if it changed — use where the write must complete
    /// before the caller returns (removes, clears, graceful shutdown).
    func saveNow() async {
        await writeLatest()
    }

    private func drain() async {
        while schedule.withLock({ state -> Bool in
            if state.requested {
                state.requested = false
                return true
            }
            state.running = false
            return false
        }) {
            await writeLatest()
        }
    }

    /// Writes the snapshot as it is when the write starts, unless it is already on disk.
    private func writeLatest() async {
        await io.run { [self] in
            let (value, stamp) = _store.withReadLock { ($0.value, $0.stamp) }
            guard let value, written.withLock({ $0 }) != stamp else { return }
            if persistence.write(state: value) { written.withLock { $0 = stamp } }
        }
    }

    // MARK: - Load

    /// Returns the cached value if available; otherwise loads from disk through
    /// `PersistenceActor` — suspending the calling actor during I/O — then caches
    /// and returns the result.
    ///
    /// Race-safe: if a concurrent actor invocation populates the cache while this
    /// call is suspended, the first-written value wins. The `PersistenceActor` also
    /// ensures the load waits for any in-flight save to complete before reading.
    func load(makeDefault: @Sendable () -> Value) async -> Value {
        if let hit = _store.withReadLock({ $0.value }) { return hit }
        let restored: Value? = await io.restore()
        return _store.withWriteLock { held in
            if held.value == nil {
                held.value = restored ?? makeDefault()
                held.stamp &+= 1
                if restored != nil { let stamp = held.stamp; written.withLock { $0 = stamp } }
            }
            return held.value!
        }
    }

    // MARK: - Atomic Modify

    /// Atomically read-modify-write the cached value under the store lock.
    /// Returns the mutated value; follow with `saveLatest` or `saveNow` to persist it.
    ///
    /// - Parameters:
    ///   - makeDefault: Produces the initial value when the cache is empty.
    ///   - mutate: Closure that mutates the value in place.
    @discardableResult
    func modify(makeDefault: () -> Value, _ mutate: (inout Value) -> Void) -> Value {
        // Exclusive write lock for the full read-modify-write — cannot be split.
        _store.withWriteLock {
            var value = $0.value ?? makeDefault()
            mutate(&value)
            $0.value = value
            $0.stamp &+= 1
            return value
        }
    }

    // MARK: - Sync Startup Seed

    /// Seeds the snapshot from disk synchronously — call once at startup before
    /// any async context is available (e.g. from a synchronous `init`).
    /// Safe because no concurrent writes can exist before the owning object is fully initialised.
    ///
    /// - Returns: The value that was seeded (from disk, or `makeDefault()` if absent).
    @discardableResult
    func seedFromDisk(makeDefault: () -> Value) -> Value {
        let restored: Value? = persistence.restore()
        let initial = restored ?? makeDefault()
        let stamp = _store.withWriteLock { held -> UInt64 in
            held.value = initial
            held.stamp &+= 1
            return held.stamp
        }
        if restored != nil { written.withLock { $0 = stamp } }
        return initial
    }
}
