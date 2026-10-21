//
//  RetrievalDataCollector+Models.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/08/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

// === INTERACTION RECORD ===
struct InteractionRecord: Codable {
    let timestamp: Date
    let sentimentWeight: Double  // From sentiment.calculateWeight(), possibly scaled by engagementComposite
    let responseLength: Int
    /// Partition ID (content-addressed hash) — used as the GBT training label.
    let id: String
    /// Document ID this partition belongs to.
    /// Used to look up `DocumentStats` in `buildDataSet` and `evaluateFitness`.
    let documentId: String
    /// Normalised pace score [0, 1]: responseLatency / (assistantWordCount × 0.3).
    /// Represents how much of the response the user likely read before replying.
    let paceScore: Double
    /// Weighted attentiveness score [0, 1]: referenced(0.4) + answered(0.4) + building(0.2).
    let attentivenessScore: Double

    init(timestamp: Date,
         sentimentWeight: Double,
         responseLength: Int,
         id: String,
         documentId: String = "",
         paceScore: Double = 0.5,
         attentivenessScore: Double = 0.0) {
        self.timestamp          = timestamp
        self.sentimentWeight    = sentimentWeight
        self.responseLength     = responseLength
        self.id                 = id
        self.documentId         = documentId
        self.paceScore          = paceScore
        self.attentivenessScore = attentivenessScore
    }
}

