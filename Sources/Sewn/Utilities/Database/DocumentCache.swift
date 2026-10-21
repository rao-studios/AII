//
//  DocumentCache.swift
//  Sewn
//
//  Created by Ritesh Pakala on 03/19/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

/// Thread-safe in-memory cache for `SewnCore.Document` objects.
///
/// Analogous to `RegistryMutator` but without the actor serialization overhead —
/// document reads are the most frequent operation and must never queue behind
/// writes. A `ReadWriteValue` lets reads run concurrently while writes stay exclusive.
///
/// All mutations go through the typed API (`cache`, `evict`, `seed`).
/// Never access `_store` directly from outside this file.
final class DocumentCache: Sendable {
    private let _store: ReadWriteValue<[DocumentID: SewnCore.Document]>

    init() {
        self._store = ReadWriteValue([:])
    }

    // MARK: - Read

    func get(_ id: DocumentID) -> SewnCore.Document? {
        _store.withReadLock { $0[id] }
    }

    // MARK: - Write

    func cache(_ document: SewnCore.Document) {
        _store.withWriteLock { $0[document.id] = document }
    }

    func evict(_ id: DocumentID) {
        _store.withWriteLock { $0.removeValue(forKey: id) }
    }

    /// Bulk-seeds the cache in a single lock acquisition. Used at startup only.
    func seed(_ initial: [DocumentID: SewnCore.Document]) {
        _store.withWriteLock { $0 = initial }
    }

    /// Inserts multiple documents in a single lock acquisition.
    func cacheBatch(_ documents: [SewnCore.Document]) {
        _store.withWriteLock { store in
            for document in documents { store[document.id] = document }
        }
    }
}
