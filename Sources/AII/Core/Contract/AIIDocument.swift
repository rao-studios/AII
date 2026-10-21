//
//  AIIDocument.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A record as Thread files it: the envelope (its metadata), and what is indexed —
//        the partitions (text, an own url, a supplied vector) and the graph (entities,
//        relationships, and the tags as concept entities).
//  IN:   AIIRecordable.document(app:now:), or an app that builds one by hand.
//  OUT:  Plain values an app maps onto its own wire layer (Ambient's DepositItem); in
//        Join/, the Thread_V1 index item and requests (AIIDocument+Thread.swift).
//  PIN:  Checked before filing: the record's ids, kind and group; at least one partition,
//        each with text or a vector; urls that parse as written (a space is no URL); and
//        metadata of at most 1 MB. Keep it far smaller: it rides on every recall hit that
//        asks for it. The cap is a backstop for a state document, such as Craft's ledger.
//        Tags join the graph as concept entities named exactly as written, so a query's
//        words match them; a declared entity of the same name wins. Any tag or entity turns
//        Thread's own extraction off for that document.
//

import Foundation

public struct AIIDocument: Sendable, Equatable {

    /// One searchable piece of a document, in order.
    public struct Partition: Sendable, Equatable {
        /// What Thread embeds (when no vector is given) and returns with a hit.
        public var text: String
        /// The partition's own address, when it has one: a region of a picture, a line range.
        public var url: String?
        /// A vector from the index's own embedder (AIIModels.embedding); nil for Thread to embed `text`.
        public var embedding: [Float]?
        /// The region of the picture this partition covers, when it is one.
        public var region: AIIRecord.Region?

        public init(text: String, url: String? = nil, embedding: [Float]? = nil, region: AIIRecord.Region? = nil) {
            self.text = text
            self.url = url
            self.embedding = embedding
            self.region = region
        }
    }

    /// The most an envelope may weigh. It comes back with every recall hit that asks for it, so
    /// a record keeps it small; this is the backstop, for a state document that grows.
    public static let maximumMetadataBytes = 1024 * 1024

    public var record: AIIRecord
    public var partitions: [Partition]
    public var entities: [AIIRecord.Entity]
    public var relationships: [AIIRecord.Relationship]

    public init(record: AIIRecord, partitions: [Partition], entities: [AIIRecord.Entity] = [],
                relationships: [AIIRecord.Relationship] = []) {
        self.record = record
        self.partitions = partitions
        self.entities = entities
        self.relationships = relationships
    }

    /// `<app>/<kind>/<id>`.
    public var documentID: String { record.documentID }

    /// `<app>-<group>`.
    public var wireGroupID: String { AIIRecord.groupID(app: record.app, group: record.group.id) }

    /// The entities Thread files: the declared ones, then each tag as a concept entity,
    /// once per name as Thread compares names (lowercased, whitespace collapsed).
    public var graphEntities: [AIIRecord.Entity] {
        var seen = Set(entities.map { Self.normalized($0.name) })
        var out = entities
        for tag in record.tags {
            let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(Self.normalized(name)).inserted else { continue }
            out.append(AIIRecord.Entity(name: name, kind: "concept"))
        }
        return out
    }

    /// The envelope's canonical JSON: the document's metadata.
    public func metadata() throws -> Data { try record.canonicalJSON() }

    /// Throws unless the document can be filed as it is.
    public func validate() throws {
        try record.validate()
        guard !partitions.isEmpty else { throw AIIRecordError.noPartitions(record.id) }
        for (index, partition) in partitions.enumerated() {
            let hasText = !partition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText || !(partition.embedding ?? []).isEmpty else {
                throw AIIRecordError.emptyPartition(record.id, index: index)
            }
            if let url = partition.url, !url.isEmpty, URL(string: url, encodingInvalidCharacters: false) == nil {
                throw AIIRecordError.invalidURL(record.id, url: url)
            }
        }
        let bytes = try metadata().count
        guard bytes <= Self.maximumMetadataBytes else { throw AIIRecordError.metadataTooLarge(record.id, bytes: bytes) }
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
