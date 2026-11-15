//
//  SearchResponse.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/01/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

/// Matched / traversed entity surfaced alongside a fused search.
struct SearchGraphEntity: Codable {
    let id: String
    let name: String
    let kind: String
}

/// A relationship traversed by the one-hop graph expansion.
struct SearchGraphRelationship: Codable {
    let subject: String
    let predicate: String
    let object: String
    let weight: Int
}

/// The knowledge-graph context for a fused search: which entities the query matched and
/// which relationships the one-hop expansion traversed to pull in related documents.
struct SearchResponseGraph: Codable {
    let entities: [SearchGraphEntity]
    let relationships: [SearchGraphRelationship]
    let expandedDocuments: Int

    enum CodingKeys: String, CodingKey {
        case entities
        case relationships
        case expandedDocuments = "expanded_documents"
    }
}

/// One hit, parallel to `texts`: what the gRPC search's result carries, so an HTTP reader (an app that connected this
/// AII by its address) can rank, hold to a floor and label what it was handed.
struct SearchHit: Codable {
    let documentId: String
    let partitionId: String
    let score: Float
    let mediaType: String
    /// The name the document was filed under, when it was given one.
    let name: String?
    let groupId: String?

    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
        case partitionId = "partition_id"
        case score
        case mediaType = "media_type"
        case name
        case groupId = "group_id"
    }
}

struct SearchResponse: Codable {
    var object: String = "list"
    let texts: [String]
    let references: [Database.DocumentReference]
    let graph: SearchResponseGraph?
    /// Parallel to `texts`.
    var hits: [SearchHit]? = nil

    enum CodingKeys: String, CodingKey {
        case object
        case texts
        case references
        case graph
        case hits
    }
}
