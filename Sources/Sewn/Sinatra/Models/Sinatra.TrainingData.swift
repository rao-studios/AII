//
//  Sinatra.TrainingData.swift
//  Sewn
//
//  Created by Ritesh Pakala on 01/25/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

struct SinatraTrainingData: Codable {
    struct Parked: Codable {
        // Partition ID (content-addressed SHA-256 hash of the embedding).
        var id: String
        /// The document this partition belongs to.
        /// Used to key performance stats in `SewnRegistry.documentStats` correctly.
        var documentId: String
        var partitionCompressedEmbedding: [UInt16]?
        var distance: Float
        /// When the partition was parked (end of the search that produced it).
        /// Used at the next prepare() call to compute response latency as a
        /// proxy for how long the user took to reply after the assistant responded.
        var parkedAt: Date

        init(id: String,
             documentId: String = "",
             partitionCompressedEmbedding: [UInt16]? = nil,
             distance: Float,
             parkedAt: Date = Date()) {
            self.id = id
            self.documentId = documentId
            self.partitionCompressedEmbedding = partitionCompressedEmbedding
            self.distance = distance
            self.parkedAt = parkedAt
        }
    }
    
    struct ParkedIndex: Codable {
        var documentId: String
        /// Exact tag distance (1.0 - dot) at filter time. Nil when tagDistance() returned nil (untagged doc).
        var tagDistance: Float?
        /// Whether this document passed the tag pre-filter for this search.
        var wasIncluded: Bool
        var parkedAt: Date

        init(documentId: String, tagDistance: Float?, wasIncluded: Bool, parkedAt: Date = Date()) {
            self.documentId = documentId
            self.tagDistance = tagDistance
            self.wasIncluded = wasIncluded
            self.parkedAt = parkedAt
        }
    }

    var date: Date = .now

    var parked: Parked
    var sentiment: Float
}
