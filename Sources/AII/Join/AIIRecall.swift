//
//  AIIRecall.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a recall found: each hit, with the record it came from, and how the graph
//        shaped the search.
//  OUT:  `AIIRecall {hits, trace}`, and `Match<Value>`, a hit decoded to the app's type.
//  PIN:  A hit is one partition: its text and its distance (lower is closer). Its record
//        is the envelope the document was filed in; nil for a document that holds none
//        (deposited over the wire by hand). Its url is the partition's own address when
//        the filer gave one, and its region the rectangle of a picture that url names.
//

import Foundation

public struct AIIRecall: Sendable {
    public struct Hit: Sendable, Identifiable {
        public var id: String { partitionID }
        /// On the wire: `<app>/<kind>/<id>` for an app's record.
        public let documentID: String
        public let partitionID: String
        /// The partition's text.
        public let text: String
        /// Lower is closer.
        public let distance: Float
        public let name: String?
        /// The wire group: `<app>-<group>`.
        public let groupID: String?
        public let record: AIIRecord?
        /// The partition's own address, when its filer gave one.
        public let url: String?
        /// The region of a picture the hit is, when its url names one.
        public var region: AIIRecord.Region? { url.flatMap { AIIRecord.Region(url: $0) } }

        public init(documentID: String, partitionID: String, text: String, distance: Float,
                    name: String?, groupID: String?, record: AIIRecord?, url: String? = nil) {
            self.documentID = documentID
            self.partitionID = partitionID
            self.text = text
            self.distance = distance
            self.name = name
            self.groupID = groupID
            self.record = record
            self.url = url
        }
    }

    /// How the knowledge graph shaped the search.
    public struct Trace: Sendable, Equatable {
        public let matchedEntityNames: [String]
        public let expandedDocumentCount: Int

        public init(matchedEntityNames: [String], expandedDocumentCount: Int) {
            self.matchedEntityNames = matchedEntityNames
            self.expandedDocumentCount = expandedDocumentCount
        }
    }

    /// A hit, decoded back to the app's own type.
    public struct Match<Value: AIIRecordable>: Sendable {
        public let value: Value
        public let hit: Hit
    }

    public let hits: [Hit]
    public let trace: Trace
}
