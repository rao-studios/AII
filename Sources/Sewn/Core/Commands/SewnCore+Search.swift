//
//  SewnCore+Search.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/01/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Seam
import Foundation
import Metrics


extension SewnCore {
    /// Search via connected Thread nodes. Passes the raw query text; each Thread
    /// embeds it locally before searching its HNSW index.
    nonisolated func search(_ query: String?,
                request: SewnRequest,
                topK: Int = 3,
                enableSinatraPark: Bool = true) async throws -> SearchChatResult {
        guard let query, !query.isEmpty else {
            logger.info("Search", "No query to search.", service: .sewn, request: request, flow: .chat)
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        if _threadQueryClient != nil {
            return try await searchWithThreads(query, request: request, topK: topK)
        }

        logger.warning("No Thread client connected — returning empty result.", service: .sewn, request: request)
        return SearchChatResult(context: [], adjustments: [], references: [])
    }
}

// MARK: - High-level chat search with Thread fan-out

extension SewnCore {
    nonisolated func searchWithThreads(
        _ query: String?,
        request: SewnRequest,
        topK: Int = 3
    ) async throws -> SearchChatResult {
        guard let query, !query.isEmpty else {
            return SearchChatResult(context: [], adjustments: [], references: [])
        }

        // One over per node, so a recap ledger dropped below never costs a slot.
        let (fetched, protoTrace) = await fanoutSearch(
            queryText: query,
            request: request,
            topK: topK + 1
        )
        let threadResults = Self.droppingRecaps(fetched, topK: topK)

        var scoreMap: [String: Float] = [:]
        var peerSources: [String: OracleNodeID] = [:]
        var threadMeta: [String: String] = [:]   // partitionId → threadId

        let rawPartitions: [SewnCore.Partition] = threadResults.map { result in
            scoreMap[result.partitionID] = result.score
            threadMeta[result.partitionID] = result.threadID
            if let tid = UUID(uuidString: result.threadID) {
                peerSources[result.partitionID] = tid
            }
            return SewnCore.Partition(
                id: result.partitionID,
                documentId: result.documentID,
                url: URL(string: "thread://\(result.threadID)")!,
                embedding: [],
                text: result.text,
                ownerId: result.ownerID
            )
        }

        var seen = Set<String>()
        let partitions = rawPartitions.filter { seen.insert($0.id).inserted }

        let scoredPartitions: [(score: Float, partition: SewnCore.Partition)] = partitions.compactMap { p in
            guard let s = scoreMap[p.id] else { return nil }
            return (s, p)
        }
        sinatra.park(data: scoredPartitions, forQuery: [], request: request)

        // Derive co-owners from partition results: group by documentId, collect unique ownerIds.
        // Thread is the source of truth — no SewnRegistry read needed.
        var coOwnerMap: [DocumentID: Set<OwnerID>] = [:]
        for p in partitions {
            guard !p.ownerId.isEmpty else { continue }
            coOwnerMap[p.documentId, default: []].insert(p.ownerId)
        }
        let derivedCoOwners = coOwnerMap.filter { $0.value.count > 1 }

        let gitaResult = gita.track(
            Gita.Payload(
                partitions: partitions,
                peerSources: peerSources,
                coOwners: derivedCoOwners
            ),
            command: .inference,
            request: request
        )

        let references: [SewnCore.DocumentReference] = partitions.map { p in
            .init(id: p.documentId, partitionId: p.id, ownerId: p.ownerId,
                  threadId: threadMeta[p.id])
        }

        let trace: SewnCore.GraphTrace? = protoTrace.map {
            SewnCore.GraphTrace(
                matchedEntityIds: $0.matchedEntityIds,
                expansionEdgeIds: $0.expansionEdgeIds,
                expandedDocuments: Int($0.expandedDocumentCount)
            )
        }

        return SearchChatResult(
            context: partitions.map(\.text),
            adjustments: [],
            references: references,
            contribution: gitaResult.contribution,
            partitions: partitions,
            trace: trace,
            retrieved: SewnCore.RetrievedPartition.from(partitions, scores: scoreMap)
        )
    }

    /// The results without recap ledgers or partitions with no text, each node's cut back
    /// to `topK` in the order given. A ledger mirrors the live chat, so it would match
    /// nearly every turn — the prompt already carries it as the recap. A partition with
    /// no text (a region of a picture, found by its vector) has nothing to ground on.
    static func droppingRecaps(
        _ results: [Thread_V1_ThreadPartitionResult],
        topK: Int
    ) -> [Thread_V1_ThreadPartitionResult] {
        var kept: [String: Int] = [:]
        return results.filter { result in
            guard !isRecapDocument(result.documentID),
                  !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let count = kept[result.threadID, default: 0]
            guard count < topK else { return false }
            kept[result.threadID] = count + 1
            return true
        }
    }
}
