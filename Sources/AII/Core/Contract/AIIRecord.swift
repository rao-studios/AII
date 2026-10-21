//
//  AIIRecord.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: aii-record/1, the envelope every document in a lane is filed in: what it is (kind,
//        title), where it is filed (group), where it came from (source), the words to match
//        it by (tags), what it replaces (supersedes), the picture it describes (image), its
//        Rao Verified stamp (verified), and the app's own value (payload). Defined in
//        Protos/record.proto as aii.v1.Record; this is its Swift form.
//  IN:   An app's AIIRecordable values (through AIIDocument), and Sewn's write-backs
//        (summaries, the recap ledger, resonant passages: kind `memory`).
//  OUT:  The envelope, its canonical JSON (a document's metadata in Thread), and the wire
//        addresses an app's records are filed under.
//  PIN:  The envelope holds what every app shares; an app's own meaning lives in its
//        payload. The searchable text and the graph are not in it: Thread holds them (the
//        partitions, the entities), so metadata, which rides on every recall hit, stays
//        small. On the wire a record is `<app>/<kind>/<id>` in group `<app>-<group>`:
//        references carry the id and nothing else, so provenance is readable from it, and
//        app names hold no `-`, so `<app>-<group>` always splits at the first `-`. The JSON
//        is value-equivalent to the proto3 JSON form of aii.v1.Record. AII writes it
//        canonically (sorted keys, `/` unescaped, whole-second UTC timestamps) and reads any
//        writer's form: absent fields as empty, fractional seconds and offsets, snake_case
//        names, and kinds and media types it doesn't know. Foundation only: both servers
//        file envelopes too.
//

import Foundation

public enum AIIRecordError: Error, Equatable, CustomStringConvertible {
    case invalidID(String)
    case invalidGroup(String)
    case invalidKind(String)
    case noPartitions(String)
    case emptyPartition(String, index: Int)
    case invalidURL(String, url: String)
    case metadataTooLarge(String, bytes: Int)

    public var description: String {
        switch self {
        case .invalidID(let id): return "record id \"\(id)\" must be 1 to 128 of A-Z, a-z, 0-9 and . _ : @ -"
        case .invalidGroup(let id): return "group id \"\(id)\" must be 1 to 64 of a-z, 0-9 and . _ -"
        case .invalidKind(let kind): return "kind \"\(kind)\" must be 1 to 32 of a-z, 0-9 and -, starting with a letter"
        case .noPartitions(let id): return "record \(id) has nothing to index"
        case .emptyPartition(let id, let index): return "record \(id): partition \(index) has neither text nor a vector"
        case .invalidURL(let id, let url): return "record \(id): \"\(url)\" is not a URL"
        case .metadataTooLarge(let id, let bytes):
            return "record \(id): its envelope is \(bytes) bytes; keep it under \(AIIDocument.maximumMetadataBytes) by leaving bulk text out of the payload"
        }
    }
}

public struct AIIRecord: Sendable, Equatable {

    /// What a record is, in an open vocabulary: `note`, `recipe`, `approach`.
    public struct Kind: RawRepresentable, Codable, Hashable, Comparable, Sendable,
                        CustomStringConvertible, ExpressibleByStringLiteral {
        public let rawValue: String

        public init?(rawValue: String) {
            guard Self.isValid(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        /// A kind as another writer spelled it: kept, so the record still reads.
        init(read rawValue: String) { self.rawValue = rawValue }

        /// A literal is the developer's own constant, so an invalid one is a programming error.
        public init(stringLiteral value: String) {
            guard let kind = Kind(rawValue: value) else {
                preconditionFailure(AIIRecordError.invalidKind(value).description)
            }
            self = kind
        }

        public static let note: Kind = "note"
        public static let document: Kind = "document"
        public static let convention: Kind = "convention"
        public static let approach: Kind = "approach"
        public static let memory: Kind = "memory"
        public static let event: Kind = "event"
        public static let image: Kind = "image"

        public var isValid: Bool { Self.isValid(rawValue) }

        static func isValid(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            guard (1...32).contains(bytes.count), let first = bytes.first,
                  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first) else { return false }
            return bytes.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: "-") }
        }

        public var description: String { rawValue }
        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How a record's text is read: `text`, `code` or `image`. Open, so a record from a
    /// newer writer still reads.
    public struct MediaType: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) { self.rawValue = rawValue }

        public static let text = MediaType(rawValue: "text")
        public static let code = MediaType(rawValue: "code")
        public static let image = MediaType(rawValue: "image")

        public var description: String { rawValue }
    }

    /// Where a record is filed: an id the app chooses and a label people read.
    public struct Group: Codable, Hashable, Sendable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = try c.read(String.self, "id") ?? ""
            label = try c.read(String.self, "label") ?? ""
        }
    }

    /// Where a record came from: who or what made it, and a reference into it.
    public struct Source: Codable, Hashable, Sendable {
        /// `app`, `user`, `import`, `sewn-summary`…
        public var kind: String
        /// A path, a URL, a session id: whatever finds the original again.
        public var ref: String?

        public init(kind: String, ref: String? = nil) {
            self.kind = kind
            self.ref = ref
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            kind = try c.read(String.self, "kind") ?? ""
            ref = try c.read(String.self, "ref")
        }
    }

    /// A graph entity a record is about. Thread's kinds: person, organization, place,
    /// event, work, concept, other; "" is concept. Filed with the record (AIIDocument),
    /// not kept in its envelope.
    public struct Entity: Codable, Hashable, Sendable {
        public var name: String
        public var kind: String

        public init(name: String, kind: String = "concept") {
            self.name = name
            self.kind = kind
        }
    }

    public struct Relationship: Codable, Hashable, Sendable {
        public var subject: String
        public var predicate: String
        public var object: String

        public init(subject: String, predicate: String, object: String) {
            self.subject = subject
            self.predicate = predicate
            self.object = object
        }
    }

    /// The picture a visual record describes.
    public struct Image: Codable, Hashable, Sendable {
        /// Its identity: the hex SHA-256 of its bytes, or of the app's canonical pixels.
        public var sha256: String
        /// In pixels, of the image `sha256` identifies: the space its regions' rectangles are in.
        public var width: Int
        public var height: Int
        /// `image/png`, `image/jpeg`; nil when unknown.
        public var mimeType: String?
        /// Where it lives, when the app knows: a file URL or the app's own URL.
        public var location: String?
        /// When it was taken or made, when known.
        public var capturedAt: Date?

        public init(sha256: String, width: Int, height: Int, mimeType: String? = nil, location: String? = nil,
                    capturedAt: Date? = nil) {
            self.sha256 = sha256
            self.width = width
            self.height = height
            self.mimeType = mimeType
            self.location = location
            self.capturedAt = capturedAt.map(AIIRecord.wholeSecond)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            sha256 = try c.read(String.self, "sha256") ?? ""
            width = try c.read(Int.self, "width") ?? 0
            height = try c.read(Int.self, "height") ?? 0
            mimeType = try c.read(String.self, "mimeType", "mime_type")
            location = try c.read(String.self, "location")
            capturedAt = try c.readDate("capturedAt", "captured_at")
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(sha256, forKey: AnyKey("sha256"))
            try c.encode(width, forKey: AnyKey("width"))
            try c.encode(height, forKey: AnyKey("height"))
            try c.encodeIfPresent(mimeType, forKey: AnyKey("mimeType"))
            try c.encodeIfPresent(location, forKey: AnyKey("location"))
            try c.encodeIfPresent(capturedAt.map(AIIRecord.timestamp), forKey: AnyKey("capturedAt"))
        }
    }

    /// A Rao Verified stamp: the signed record of what a person read or made, and its seal.
    public struct Verified: Codable, Hashable, Sendable {
        /// The Rao Verified record, as its canonical JSON.
        public var record: String
        /// The seal over it, base64.
        public var seal: String

        public init(record: String, seal: String) {
            self.record = record
            self.seal = seal
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            record = try c.read(String.self, "record") ?? ""
            seal = try c.read(String.self, "seal") ?? ""
        }
    }

    /// A rectangle of a picture filed as its own partition, with the vector that searches
    /// it. Not part of the envelope: a region is a partition whose url ends in the W3C
    /// media fragment `#xywh=pixel:x,y,w,h`.
    public struct Region: Hashable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        /// A vector in the index's own space (AIIModels.embedding), or nil for Thread to embed `text`.
        public var embedding: [Float]?
        /// What the region shows in words, if anything; "" for a region searched by its vector.
        public var text: String

        public init(x: Int, y: Int, width: Int, height: Int, embedding: [Float]? = nil, text: String = "") {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.embedding = embedding
            self.text = text
        }

        /// `xywh=pixel:x,y,w,h`.
        public var fragment: String { "xywh=pixel:\(x),\(y),\(width),\(height)" }

        /// A region from a media fragment (`xywh=pixel:0,0,32,32`, `xywh=0,0,32,32`), other
        /// `&`-joined parameters ignored.
        public init?(fragment: String) {
            guard let part = fragment.split(separator: "&").first(where: { $0.hasPrefix("xywh=") }) else { return nil }
            var value = part.dropFirst("xywh=".count)
            if value.hasPrefix("pixel:") { value = value.dropFirst("pixel:".count) }
            let numbers = value.split(separator: ",").compactMap { Int($0) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            self.init(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }

        /// A region from a partition's url: its fragment, when it has one.
        public init?(url: String) {
            guard let hash = url.firstIndex(of: "#") else { return nil }
            self.init(fragment: String(url[url.index(after: hash)...]))
        }
    }

    public var format: String
    /// The app whose lane it is filed in.
    public var app: AIIApp
    /// The app's id for it: stable, and unique within its kind.
    public var id: String
    public var kind: Kind
    public var title: String
    public var group: Group
    public var source: Source
    /// Words to match it by: filed as concept entities named as written (AIIDocument).
    public var tags: [String]
    /// The id of the record of the same kind this one replaces.
    public var supersedes: String?
    public var mediaType: MediaType
    /// When it was put in the lane, to the second.
    public var rememberedAt: Date
    /// The app's own value, as JSON.
    public var payload: AIIJSONValue?
    /// The picture, for a visual record.
    public var image: Image?
    /// Its Rao Verified stamp, when it carries one.
    public var verified: Verified?

    public init(app: AIIApp, id: String, kind: Kind, title: String, group: Group,
                source: Source = Source(kind: "app"), tags: [String] = [], supersedes: String? = nil,
                mediaType: MediaType = .text, rememberedAt: Date = Date(), payload: AIIJSONValue? = nil,
                image: Image? = nil, verified: Verified? = nil) {
        self.format = AIIContract.recordFormat
        self.app = app
        self.id = id
        self.kind = kind
        self.title = title
        self.group = group
        self.source = source
        self.tags = tags
        self.supersedes = supersedes
        self.mediaType = mediaType
        self.rememberedAt = Self.wholeSecond(rememberedAt)
        self.payload = payload
        self.image = image
        self.verified = verified
    }

    /// Throws unless the record can be filed: its id, what it supersedes, its kind and its group.
    public func validate() throws {
        guard Self.isValidID(id) else { throw AIIRecordError.invalidID(id) }
        if let supersedes, !Self.isValidID(supersedes) { throw AIIRecordError.invalidID(supersedes) }
        guard kind.isValid else { throw AIIRecordError.invalidKind(kind.rawValue) }
        guard Self.isValidGroupID(group.id) else { throw AIIRecordError.invalidGroup(group.id) }
    }

    // MARK: - Bytes

    /// Sorted keys, no escaped slashes, whole-second UTC timestamps: the same record, the
    /// same bytes.
    public func canonicalJSON() throws -> Data { try AIIJSONValue.encoder.encode(self) }

    /// An envelope from a document's metadata; nil when the metadata isn't one.
    public static func decode(_ metadata: Data) -> AIIRecord? {
        guard !metadata.isEmpty, let record = try? AIIJSONValue.decoder.decode(AIIRecord.self, from: metadata),
              record.format == AIIContract.recordFormat else { return nil }
        return record
    }

    // MARK: - Where an app's record is filed

    /// `<app>/<kind>/<id>`.
    public var documentID: String { Self.documentID(app: app, kind: kind, id: id) }

    public static func documentID(app: AIIApp, kind: Kind, id: String) -> String {
        "\(app.rawValue)/\(kind.rawValue)/\(id)"
    }

    /// The app, kind and id a document id names, when it is an app's record.
    public static func parseDocumentID(_ documentID: String) -> (app: AIIApp, kind: Kind, id: String)? {
        let parts = documentID.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let app = AIIApp(rawValue: String(parts[0])),
              let kind = Kind(rawValue: String(parts[1])), isValidID(String(parts[2])) else { return nil }
        return (app, kind, String(parts[2]))
    }

    /// `<app>-<group>`.
    public static func groupID(app: AIIApp, group: String) -> String { "\(app.rawValue)-\(group)" }

    /// The app and the app's own group id a wire group names, when it is an app's.
    public static func parseGroupID(_ groupID: String) -> (app: AIIApp, group: String)? {
        guard let dash = groupID.firstIndex(of: "-"), let app = AIIApp(rawValue: String(groupID[..<dash])) else { return nil }
        let group = String(groupID[groupID.index(after: dash)...])
        return group.isEmpty ? nil : (app, group)
    }

    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || ".:_@-".utf8.contains($0) }
    }

    public static func isValidGroupID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || "._-".utf8.contains($0) }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    // MARK: - Time

    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// `2026-10-16T09:12:00Z`.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: wholeSecond(date))
    }

    /// Any RFC 3339 timestamp, with or without fractional seconds or an offset, to the second.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return wholeSecond(date) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text).map(wholeSecond)
    }
}

// MARK: - Codable

extension AIIRecord: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        format = try c.read(String.self, "format") ?? ""
        let appName = try c.read(String.self, "app") ?? ""
        guard let app = AIIApp(rawValue: appName) else {
            throw DecodingError.dataCorruptedError(forKey: AnyKey("app"), in: c,
                                                   debugDescription: "\"\(appName)\" is not an app name")
        }
        self.app = app
        id = try c.read(String.self, "id") ?? ""
        kind = Kind(read: try c.read(String.self, "kind") ?? "")
        title = try c.read(String.self, "title") ?? ""
        group = try c.read(Group.self, "group") ?? Group(id: "", label: "")
        source = try c.read(Source.self, "source") ?? Source(kind: "")
        tags = try c.read([String].self, "tags") ?? []
        supersedes = try c.read(String.self, "supersedes")
        let media = try c.read(String.self, "mediaType", "media_type") ?? ""
        mediaType = media.isEmpty ? .text : MediaType(rawValue: media)
        rememberedAt = try c.readDate("rememberedAt", "remembered_at") ?? Date(timeIntervalSince1970: 0)
        payload = try c.read(AIIJSONValue.self, "payload").flatMap { $0 == .null ? nil : $0 }
        image = try c.read(Image.self, "image")
        verified = try c.read(Verified.self, "verified")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(format, forKey: AnyKey("format"))
        try c.encode(app.rawValue, forKey: AnyKey("app"))
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(kind.rawValue, forKey: AnyKey("kind"))
        try c.encode(title, forKey: AnyKey("title"))
        try c.encode(group, forKey: AnyKey("group"))
        try c.encode(source, forKey: AnyKey("source"))
        try c.encode(tags, forKey: AnyKey("tags"))
        try c.encodeIfPresent(supersedes, forKey: AnyKey("supersedes"))
        try c.encode(mediaType.rawValue, forKey: AnyKey("mediaType"))
        try c.encode(Self.timestamp(rememberedAt), forKey: AnyKey("rememberedAt"))
        try c.encodeIfPresent(payload, forKey: AnyKey("payload"))
        try c.encodeIfPresent(image, forKey: AnyKey("image"))
        try c.encodeIfPresent(verified, forKey: AnyKey("verified"))
    }
}

/// A key by name, so a field can be read under its proto3 JSON name or its proto name.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// The first of `names` present and not null, decoded; nil when none is.
    func read<T: Decodable>(_ type: T.Type, _ names: String...) throws -> T? {
        for name in names {
            let key = AnyKey(name)
            if contains(key), !(try decodeNil(forKey: key)) { return try decode(T.self, forKey: key) }
        }
        return nil
    }

    /// A timestamp under any of `names`, read leniently (AIIRecord.date).
    func readDate(_ names: String...) throws -> Date? {
        for name in names {
            let key = AnyKey(name)
            guard contains(key), !(try decodeNil(forKey: key)) else { continue }
            let text = try decode(String.self, forKey: key)
            guard let date = AIIRecord.date(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\"\(text)\" is not an RFC 3339 timestamp")
            }
            return date
        }
        return nil
    }
}
