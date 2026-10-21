//
//  SewnCore.Registry.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/08/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

typealias DocumentID = String
typealias GroupID = String
typealias OwnerID = String

/// Lean billing-only registry. Document/group/ownership data lives on Thread nodes.
struct SewnRegistry: Codable {
    // Billing and engagement stats per document.
    // Keyed by DocumentID — same identifier as the document itself.
    var documentStats: [DocumentID : SewnCore.DocumentStats] = [:]
    // Owner IDs that have opted in to Marielle bridging.
    var bridgingEnabledOwners: Set<OwnerID> = []
}

// MARK: - Marielle

extension SewnRegistry {
    func bridgingEnabled(for ownerId: OwnerID) -> Bool {
        bridgingEnabledOwners.contains(ownerId)
    }

    mutating func enableBridging(for ownerId: OwnerID) {
        bridgingEnabledOwners.insert(ownerId)
    }

    mutating func disableBridging(for ownerId: OwnerID) {
        bridgingEnabledOwners.remove(ownerId)
    }
}

// MARK: - Document Stats

extension SewnRegistry {
    func stats(for documentId: DocumentID) -> SewnCore.DocumentStats {
        documentStats[documentId] ?? .init(id: documentId)
    }

    mutating func addEarnings(_ earnings: [DocumentID: Gita.Credits]) {
        for (documentId, credits) in earnings where credits > 0 {
            documentStats[documentId, default: .init(id: documentId)].totalEarned += credits
        }
    }

    mutating func addPerformance(_ updates: [DocumentID: SewnCore.DocumentStats]) {
        for (documentId, updated) in updates {
            var entry = documentStats[documentId, default: .init(id: documentId)]
            entry.retrievalCount += updated.retrievalCount
            entry.sentimentSum   += updated.sentimentSum
            if let t = updated.lastRetrieved {
                entry.lastRetrieved = t
            }
            for (partitionId, count) in updated.partitionRetrievalCount {
                entry.partitionRetrievalCount[partitionId, default: 0] += count
            }
            for (partitionId, ps) in updated.partitionSentiments {
                entry.partitionSentiments[partitionId, default: .init()].retrievalCount += ps.retrievalCount
                entry.partitionSentiments[partitionId, default: .init()].sentimentSum   += ps.sentimentSum
                if let t = ps.lastRetrieved {
                    entry.partitionSentiments[partitionId, default: .init()].lastRetrieved = t
                }
            }
            documentStats[documentId] = entry
        }
    }
}

// MARK: - Access (kept for Modify route return types and SewnCore.Group model)

extension SewnRegistry {
    enum Access: String, Codable {
        case available
        case restricted
        case unknown
    }
}

// MARK: - Owner (keyed Sinatra ML registries; does not represent document ownership)

extension SewnRegistry {
    struct Owner: Codable, Hashable {
        let id: OwnerID
    }
}
