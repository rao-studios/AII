//
//  AIILinkSchemaJSON.swift
//  AII
//
//  Created by Ritesh Pakala on 11/05/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Link's documents as JSON Schema, for whoever reads AII outside the apps that
//        file into it: the aii-record/1 envelope's fields Link fixes (its lane, its
//        kind, its id, its group) and the note's payload.
//  OUT:  `note`, the schema; `noteJSON`, its bytes as `Schemas/Link/link-note.schema.json`
//        holds them (a test fails when the two drift; AII_UPDATE_GOLDEN=1 rewrites it).
//

import Foundation

public enum AIILinkSchemaJSON {

    /// `link-note.schema.json`.
    public static var note: AIIJSONValue {
        .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "$id": .string(AIILinkNote.format),
            "title": .string("A note written on a linked device"),
            "description": .string(
                "An aii-record/1 envelope in Link's lane: one per note and owner, in link-<owner>, replaced when "
                + "the note changes. Its partitions are the card (Note:, Written on:, Written:, Folder:, Tags:) "
                + "then the body in packed paragraphs."),
            "type": .string("object"),
            "required": strings(["format", "app", "id", "kind", "title", "group", "source", "payload"]),
            "properties": .object([
                "format": constant(AIIContract.recordFormat),
                "app": constant(AIILink.app.rawValue),
                "kind": constant(AIILinkNote.kind.rawValue),
                "id": described(pattern("^[0-9a-f]{16}$"),
                                "16 hex of FNV-1a over the owner and the note's id; the document's is link/note/<this>"),
                "title": described(string, "the note's title, or the first 80 characters of its body"),
                "group": .object([
                    "type": .string("object"),
                    "required": strings(["id", "label"]),
                    "properties": .object([
                        "id": described(string, "the owner, lowercased; the wire group is link-<this>"),
                        "label": constant("Link"),
                    ]),
                ]),
                "source": .object([
                    "type": .string("object"),
                    "required": strings(["kind", "ref"]),
                    "properties": .object([
                        "kind": constant("link"),
                        "ref": described(string, "the note's own id on the device"),
                    ]),
                ]),
                "tags": described(.object(["type": .string("array"), "items": string]),
                                  "the note's tags, each a concept a query can name"),
                "payload": .object(["$ref": .string("#/$defs/note")]),
            ]),
            "$defs": .object([
                "note": .object([
                    "type": .string("object"),
                    "required": strings(["format", "noteID", "tags", "device", "createdAt", "updatedAt",
                                         "contentHash", "characters", "filedBy"]),
                    "properties": .object([
                        "format": constant(AIILinkNote.format),
                        "noteID": described(string, "the note's own id on the device, lowercased"),
                        "folder": described(string, "the device's folder for it; a field, never a group"),
                        "tags": .object(["type": .string("array"), "items": string]),
                        "device": .object(["$ref": .string("#/$defs/device")]),
                        "createdAt": dateTime,
                        "updatedAt": dateTime,
                        "contentHash": described(string, "what the device says the note's words hash to"),
                        "characters": .object(["type": .string("integer"), "minimum": .integer(0)]),
                        "filedBy": described(string, "the Mac app that received and filed it"),
                    ]),
                ]),
                "device": .object([
                    "type": .string("object"),
                    "required": strings(["kind", "name", "id"]),
                    "properties": .object([
                        "kind": described(string, "what the device is: phone today"),
                        "name": string,
                        "id": string,
                    ]),
                ]),
            ]),
        ])
    }

    /// The schema as the checked-in file holds it: pretty, sorted, with a trailing newline.
    public static var noteJSON: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(note)) ?? Data()) + Data("\n".utf8)
    }

    // MARK: - Pieces

    static let string: AIIJSONValue = .object(["type": .string("string")])
    static let dateTime: AIIJSONValue = .object(["type": .string("string"), "format": .string("date-time")])

    static func constant(_ value: String) -> AIIJSONValue { .object(["const": .string(value)]) }
    static func pattern(_ value: String) -> AIIJSONValue {
        .object(["type": .string("string"), "pattern": .string(value)])
    }
    static func strings(_ values: [String]) -> AIIJSONValue { .array(values.map { .string($0) }) }
    static func described(_ value: AIIJSONValue, _ description: String) -> AIIJSONValue {
        guard case .object(var fields) = value else { return value }
        fields["description"] = .string(description)
        return .object(fields)
    }
}
