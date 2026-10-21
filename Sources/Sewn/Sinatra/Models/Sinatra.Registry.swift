//
//  Sinatra.Registry.swift
//  Sewn
//
//  Created by Ritesh Pakala on 01/25/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

struct SinatraRegistry: Codable {
    /*
     This is built for an ephemeral chat session. Or a single chat session.
     If this can handle multiple chats then we would need to also key via
     a chat session id.
     */
    var parked: [SewnRegistry.Owner: [SinatraTrainingData.Parked]] = [:]
    var parkedIndices: [SewnRegistry.Owner: [SinatraTrainingData.ParkedIndex]] = [:]
    var collectors: [SewnRegistry.Owner : RetrievalDataCollector] = [:]
    var dataSets: [SewnRegistry.Owner : DataSet] = [:]
    var models: [SewnRegistry.Owner : GBTModel] = [:]
    var harmonyMemories: [SewnRegistry.Owner : HarmonyMemory] = [:]
    /// Most recent sentiment result per owner — written after each sentiment cycle,
    /// exposed via the /v1/frank/parking debug route.
    var lastSentiments: [SewnRegistry.Owner : Sinatra.Sentiment] = [:]
    /// Per-partition GBT adjustment entries from the most recent search per owner.
    /// Written after each search.
    var lastSearchEntries: [SewnRegistry.Owner : [SinatraAdjustment.Entry]] = [:]
    /// Trajectory snapshot from the most recent prepare() cycle per owner.
    /// Exposed via /v1/frank/parking for the Trajectory debug tab.
    var lastTrajectories: [SewnRegistry.Owner : SinatraTrajectorySnapshot] = [:]
}
