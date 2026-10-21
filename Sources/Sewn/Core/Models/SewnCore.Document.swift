//
//  SewnCore.Document.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/01/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


/// Base document object for text-embeddings stored on the
/// Sewn network.
extension SewnCore {
    struct Document: Codable {
        var id: String
        var url: URL

        // Ties with Gita owners on-chain.
        var ownerId: String

        var createdAt: Date = .now

        enum CodingKeys: String, CodingKey {
            case id
            case url
            case ownerId = "owner_id"
            case createdAt = "created_at"
        }

        init(id: String, url: URL, ownerId: String, createdAt: Date = .now) {
            self.id = id
            self.url = url
            self.ownerId = ownerId
            self.createdAt = createdAt
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id        = try c.decode(String.self, forKey: .id)
            url       = try c.decode(URL.self,    forKey: .url)
            ownerId   = try c.decode(String.self, forKey: .ownerId)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        }
    }
    
    struct DocumentReference: Codable {
        var id: String
        var partitionId: String
        var ownerId: String
        var threadId: String? = nil
        var shardIndex: Int? = nil

        enum CodingKeys: String, CodingKey {
            case id
            case partitionId = "partition_id"
            case ownerId     = "owner_id"
            case threadId     = "thread_id"
            case shardIndex  = "shard_index"
        }
    }
}

extension SewnCore {
    // MARK: - Document store

    /// Helper to retrieve the `FilePersistence` instance of the document.
    /// - Parameter id: The `DocumentID`.
    /// - Returns: The `FilePersistence` object.
    nonisolated func documentStore(for id: DocumentID) -> FilePersistence {
        FilePersistence(key: "documents/\(id)",
                        kind: .basic,
                        logger: logger.base)
    }
    /// Retrieve the `SewnCore.Document` for a `DocumentID`.
    /// Returns the in-memory cached copy if available; falls back to disk.
    nonisolated func document(for id: DocumentID) -> SewnCore.Document? {
        documentCache.get(id) ?? documentStore(for: id).restore()
    }
    /// Helper to retrieve the `FilePersistence` instance of the document.
    /// - Parameter id: The `DocumentID`.
    /// - Returns: The `FilePersistence` object.
    func conversationDocumentStore(for id: DocumentID) -> FilePersistence {
        FilePersistence(key: "conversations/\(id)",
                        kind: .basic,
                        logger: logger.base)
    }
    /// Retrieve the conversation `SewnCore.Document` for a `DocumentID` via `FilePersistence`.
    /// - Parameter id: The `DocumentID`.
    /// - Returns: The `SewnCore.Document` object.
    func conversationDocument(for id: DocumentID) -> SewnCore.Document? {
        conversationDocumentStore(for: id).restore()
    }
}
