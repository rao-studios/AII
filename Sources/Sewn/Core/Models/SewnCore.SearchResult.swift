//
//  SewnCore.SearchResult.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/02/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

extension SewnCore {
    // A SearchResult tuned for chat completion requests.
    // Prioritizes the context as Strings for immediate context
    // augmentation in system prompts when processing replies.
    /// Graph provenance for a hybrid search, merged across Thread nodes: which entities
    /// matched the query and how many documents the one-hop expansion pulled in.
    struct GraphTrace {
        var matchedEntityIds: [String] = []
        var expansionEdgeIds: [String] = []
        var expandedDocuments: Int = 0
    }

    struct SearchChatResult {
        var context: [String]
        var adjustments: [SinatraAdjustment]
        var references: [SewnCore.DocumentReference]
        var contribution: Gita.Contribution?
        /// Raw partitions retained so span attribution can run after LLM generation.
        var partitions: [SewnCore.Partition]
        var trace: SewnCore.GraphTrace?
        /// The partitions with their search scores, for the on-device provider's SinatraHarness.
        var retrieved: [SewnCore.RetrievedPartition] = []

        init(
            context: [String],
            adjustments: [SinatraAdjustment],
            references: [SewnCore.DocumentReference],
            contribution: Gita.Contribution? = nil,
            partitions: [SewnCore.Partition] = [],
            trace: SewnCore.GraphTrace? = nil,
            retrieved: [SewnCore.RetrievedPartition] = []
        ) {
            self.retrieved = retrieved
            self.context = context
            self.adjustments = adjustments
            self.references = references
            self.contribution = contribution
            self.partitions = partitions
            self.trace = trace
        }
    }
}
