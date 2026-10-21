//
//  AIIRecordable.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What an app's own model type adopts to be pushed into its lane: a clearly
//        defined schema (kind, group, id, title, text) around the app's own fields.
//  IN:   The app's type: `struct Note: AIIRecordable { static let kind: AIIRecord.Kind = "note" … }`.
//  OUT:  `document(app:now:)`, what Thread files for the value (the aii-record/1 envelope,
//        its partitions and its graph); `envelope(app:now:)`, the envelope alone; and
//        `AIIRecord.value(as:)`, the app's type back from a recalled envelope.
//  PIN:  The value itself is the envelope's payload, encoded as its own Codable shape, so
//        recall hands back the same type with every field the app gave it. Keep bulk text
//        out of that shape (exclude it from CodingKeys, or keep it beside the type): the
//        partitions carry the text, and the envelope rides on every recall hit (AII
//        refuses one over 1 MB). `text` is split into partitions of about 1,500 characters
//        unless the type describes its own `partitions` (pre-chunked text, a url or a
//        vector each).
//

import Foundation

public protocol AIIRecordable: Codable, Sendable {
    /// What this type is in the lane. One kind per type.
    static var kind: AIIRecord.Kind { get }
    /// Where values of this type are filed, unless a value says otherwise.
    static var group: AIIRecord.Group { get }

    /// Stable for the value's life, unique within its kind.
    var recordID: String { get }
    var title: String { get }
    /// What is embedded and searched.
    var text: String { get }

    /// Default: `Self.group`.
    var group: AIIRecord.Group { get }
    /// Words to match it by, filed as concept entities. Any tag turns Thread's own
    /// extraction off. Default: none.
    var tags: [String] { get }
    /// Its graph, when the app knows it. Default: none, and Thread extracts one from
    /// the text unless tags are given.
    var entities: [AIIRecord.Entity] { get }
    var relationships: [AIIRecord.Relationship] { get }
    /// Where it came from. Default: the app.
    var source: AIIRecord.Source { get }
    /// The id of the record of the same kind it replaces. Default: none.
    var supersedes: String? { get }
    /// Default: text.
    var mediaType: AIIRecord.MediaType { get }
    /// What Thread embeds and searches, in order. Default: `text`, split into partitions
    /// of about 1,500 characters. Override to keep the app's own chunks, or to give a
    /// partition its own url or a vector.
    var partitions: [AIIDocument.Partition] { get }
    /// The picture, for a visual record. Default: none.
    var image: AIIRecord.Image? { get }
    /// A Rao Verified stamp to carry. Default: none.
    var verified: AIIRecord.Verified? { get }
}

extension AIIRecordable {
    public var group: AIIRecord.Group { Self.group }
    public var tags: [String] { [] }
    public var entities: [AIIRecord.Entity] { [] }
    public var relationships: [AIIRecord.Relationship] { [] }
    public var source: AIIRecord.Source { AIIRecord.Source(kind: "app") }
    public var supersedes: String? { nil }
    public var mediaType: AIIRecord.MediaType { .text }
    public var partitions: [AIIDocument.Partition] { AIIChunker.split(text).map { AIIDocument.Partition(text: $0) } }
    public var image: AIIRecord.Image? { nil }
    public var verified: AIIRecord.Verified? { nil }

    /// The aii-record/1 envelope this value is filed in, in `app`'s lane.
    public func envelope(app: AIIApp, now: Date = Date()) throws -> AIIRecord {
        let record = AIIRecord(
            app: app, id: recordID, kind: Self.kind, title: title, group: group, source: source, tags: tags,
            supersedes: supersedes, mediaType: mediaType, rememberedAt: now,
            payload: try AIIJSONValue(encoding: self), image: image, verified: verified)
        try record.validate()
        return record
    }

    /// What Thread files for this value in `app`'s lane: the envelope, the partitions and the
    /// graph. A region partition without a url gets `<base>#xywh=pixel:x,y,w,h`, where the
    /// base is the picture's location or `aii:<document id>`. Throws when it can't be filed.
    public func document(app: AIIApp, now: Date = Date()) throws -> AIIDocument {
        let record = try envelope(app: app, now: now)
        let base = Self.regionBase(image?.location ?? "aii:\(record.documentID)")
        let partitions = self.partitions.map { partition -> AIIDocument.Partition in
            guard partition.url == nil, let region = partition.region else { return partition }
            var addressed = partition
            addressed.url = "\(base)#\(region.fragment)"
            return addressed
        }
        let document = AIIDocument(record: record, partitions: partitions, entities: entities, relationships: relationships)
        try document.validate()
        return document
    }

    /// A location as the base of a region url: percent-encoded where it isn't a URL already,
    /// and without a fragment of its own.
    private static func regionBase(_ location: String) -> String {
        let bare = location.split(separator: "#", maxSplits: 1).first.map(String.init) ?? location
        if URL(string: bare, encodingInvalidCharacters: false) != nil { return bare }
        return bare.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bare
    }
}

extension AIIRecord {
    /// The app's value back, when this envelope holds one of `type`'s kind.
    public func value<T: AIIRecordable>(as type: T.Type) throws -> T? {
        guard kind == T.kind, let payload else { return nil }
        return try payload.decode(as: T.self)
    }
}
