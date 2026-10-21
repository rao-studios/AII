//
//  Gita.Payload.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/02/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

/// The `Gita.Payload` that utilizes certain Sewn and Sinatra data types to
/// match with relevant contributions in the network returning a shared royalty
/// tracked set of information.
extension Gita {
    struct Payload {
        // TODO: dataSets becomes the prediction that is tracked instead.
        var dataSets: [SinatraTrainingData]
        var partitions: [SewnCore.Partition]
        var documents: [SewnCore.Document]
        /// Maps partitionId → OracleNodeID for partitions retrieved from peer nodes.
        /// Empty for purely local search results.
        var peerSources: [String: OracleNodeID]
        /// Maps documentId → all registered owner IDs for co-owned documents.
        /// Only documents with 2+ owners need entries; single-owner documents
        /// fall back to `partition.ownerId` inside `royalty(for:coOwners:)`.
        var coOwners: [DocumentID: Set<OwnerID>]

        init(dataSets: [SinatraTrainingData] = [],
             partitions: [SewnCore.Partition] = [],
             documents: [SewnCore.Document] = [],
             peerSources: [String: OracleNodeID] = [:],
             coOwners: [DocumentID: Set<OwnerID>] = [:]) {
            // TODO: dataSets becomes the prediction that is tracked instead.
            self.dataSets = dataSets
            self.partitions = partitions
            self.documents = documents
            self.peerSources = peerSources
            self.coOwners = coOwners
        }

        init(_ partition: SewnCore.Partition) {
            self.dataSets = []
            self.partitions = [partition]
            self.documents = []
            self.peerSources = [:]
            self.coOwners = [:]
        }

        init(_ document: SewnCore.Document) {
            self.dataSets = []
            self.partitions = []
            self.documents = [document]
            self.peerSources = [:]
            self.coOwners = [:]
        }
    }
}

/* SewnCore.Partition Helpers */

extension SewnCore.Partition {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(self)
    }
}

extension Collection where Element == SewnCore.Partition {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(partitions: self as? [SewnCore.Partition] ?? [])
    }
}

/* SewnCore.Document Helpers */

extension SewnCore.Document {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(self)
    }
}

extension Collection where Element == SewnCore.Document {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(documents: self as? [SewnCore.Document] ?? [])
    }
}

