//
//  AIILinkNote.swift
//  AII
//
//  Created by Ritesh Pakala on 11/05/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A note written on a linked device, as Link files it (`link-note/1`): one
//        record per note and owner in `link-<owner>`, replaced when the note changes.
//  IN:   The Mac app the device is linked to, with what the device sent.
//  OUT:  `document(app: AIILink.app)`: the envelope, the card and the body's
//        partitions, the note's tags as concepts.
//  PIN:  THE NOTE'S OWN WORDS, AS WRITTEN. The first partition is a card of facts
//        about the note (`Note:`, `Written on:`, `Written:`, `Folder:`, `Tags:`); then
//        the body in paragraphs packed to about 1,200 characters, a long one cut at a
//        sentence end, at most 400. Nothing is summarized. Every app files a note the
//        same way because the composition is here, not in the app.
//  PIN:  THE FORMAT IS IN THE PAYLOAD. `format` names it; a reader that does not
//        know the format leaves the note alone. `Schemas/Link/link-note.schema.json`
//        is `AIILinkSchemaJSON.note`, and a test holds the two together.
//  PIN:  Imported, never verified: the Mac watched none of it written. The filing
//        app stamps a Rao Verified record that says so.
//

import Foundation

public struct AIILinkNote: AIIRecordable, Equatable {
    public static let kind: AIIRecord.Kind = "note"
    public static let format = "link-note/1"
    /// The group with no account: every note names its own owner's.
    public static let group = AIILink.group(ownerID: AIIOwner.local.rawValue)

    /// The device that wrote a note.
    public struct Device: Codable, Sendable, Equatable {
        /// What the device is: `phone` today; any accessory class later.
        public var kind: String
        public var name: String
        public var id: String

        public init(kind: String = "phone", name: String, id: String) {
            self.kind = kind
            self.name = name
            self.id = id
        }
    }

    public var format = AIILinkNote.format
    public var recordID: String
    /// The note's own id on the device, lowercased.
    public var noteID: String
    public var title: String
    /// The device's folder for it, if any.
    public var folder: String?
    /// The note's tags, as written.
    public var tags: [String]
    public var device: Device
    public var createdAt: Date
    public var updatedAt: Date
    /// What the device says the note's words hash to.
    public var contentHash: String
    public var characters: Int
    /// The Mac app that received it and filed it.
    public var filedBy: AIIApp

    /// The card, then the body. Beside the payload, never in it.
    public var texts: [String] = []
    public var group: AIIRecord.Group = AIILinkNote.group
    public var verified: AIIRecord.Verified?

    enum CodingKeys: String, CodingKey {
        case format, noteID, folder, tags, device, createdAt, updatedAt, contentHash, characters, filedBy
    }

    /// A note from `device` for `ownerID`, filed by `app`: its card and body composed here.
    public init(
        noteID: String, title: String, body: String, folder: String?, tags: [String],
        device: Device, createdAt: Date, updatedAt: Date, contentHash: String,
        ownerID: String, filedBy app: AIIApp
    ) {
        let folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recordID = AIILink.noteRecordID(noteID: noteID, ownerID: ownerID)
        self.noteID = noteID.lowercased()
        self.title = title.isEmpty ? Self.clip(body, limit: 80) : title
        self.folder = folder?.isEmpty == false ? folder : nil
        self.tags = tags
        self.device = device
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contentHash = contentHash
        self.characters = body.count
        self.filedBy = app
        self.group = AIILink.group(ownerID: ownerID)
        self.texts = [Self.card(title: title, device: device, createdAt: createdAt, folder: self.folder, tags: tags)]
            + Array(Self.pack(body, limit: Self.partitionCharacters).prefix(Self.maxPartitions))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        noteID = try container.decode(String.self, forKey: .noteID)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        tags = try container.decode([String].self, forKey: .tags)
        device = try container.decode(Device.self, forKey: .device)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        characters = try container.decode(Int.self, forKey: .characters)
        filedBy = try container.decode(AIIApp.self, forKey: .filedBy)
        // The envelope's own, read back by whoever holds the envelope.
        recordID = ""
        title = ""
    }

    public var text: String { texts.joined(separator: "\n\n") }

    /// Each text its own partition, as composed.
    public var partitions: [AIIDocument.Partition] { texts.map { AIIDocument.Partition(text: $0) } }

    public var source: AIIRecord.Source { AIIRecord.Source(kind: "link", ref: noteID) }

    // MARK: - Composition

    /// A partition's size: a few paragraphs.
    public static let partitionCharacters = 1_200
    /// More than this is clipped: a note is not a book.
    public static let maxPartitions = 400

    /// Facts about the note, one per line. Part of the format: readers may parse it.
    public static func card(title: String, device: Device, createdAt: Date, folder: String?, tags: [String]) -> String {
        var card = "Note: \(title.isEmpty ? "Untitled" : title)"
        card += "\nWritten on: \(device.name)"
        card += "\nWritten: \(ISO8601DateFormatter().string(from: createdAt))"
        if let folder { card += "\nFolder: \(folder)" }
        if !tags.isEmpty { card += "\nTags: \(tags.joined(separator: ", "))" }
        return card
    }

    /// The body's paragraphs packed into pieces of at most `limit` characters; a long
    /// paragraph is cut after a sentence where one ends in time, else at a space, else hard.
    public static func pack(_ text: String, limit: Int) -> [String] {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var parts: [String] = []
        var current = ""
        for paragraph in paragraphs {
            for piece in split(paragraph, limit: limit) {
                if current.isEmpty {
                    current = piece
                } else if current.count + 2 + piece.count <= limit {
                    current += "\n\n" + piece
                } else {
                    parts.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func split(_ paragraph: String, limit: Int) -> [String] {
        var rest = Substring(paragraph)
        var pieces: [String] = []
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { ".!?…".contains($0) }).map { window.index(after: $0) }
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            let piece = rest[..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        let last = rest.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { pieces.append(last) }
        return pieces
    }

    static func clip(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
