//
//  AIIRecordProtoTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  aii-record/1 and aii-lanes/1 against their definitions in Protos/ (record.proto,
//  lanes.proto; Swift generated into Generated/ by Scripts/generate-seam.sh). What AII writes
//  parses as the proto3 JSON of aii.v1.Record and aii.v1.LaneManifest, with no field the
//  proto doesn't know, and what a proto3 JSON printer writes reads back as the same values.
//  Payloads are built from JSON text: a JSON number that is whole reads as an integer.
//

import Foundation
import SwiftProtobuf
import XCTest
@testable import AII

final class AIIRecordProtoTests: XCTestCase {

    /// Unknown fields refused: AII writes nothing the proto doesn't define.
    private static let strict: JSONDecodingOptions = {
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = false
        return options
    }()

    /// 2026-10-16T09:12:00Z.
    private static let filed = Date(timeIntervalSince1970: 1_792_141_920)

    /// Every field set.
    private func fullRecord() throws -> AIIRecord {
        let payload = try JSONDecoder().decode(AIIJSONValue.self, from: Data("""
            {"servings": 4, "ratio": 2.5, "vegan": true, "steps": ["rinse", "simmer"],
             "from": {"name": "Ada", "page": null}, "big": 9007199254740991}
            """.utf8))
        return AIIRecord(
            app: "notes", id: "soup.v2", kind: "recipe", title: "Lentil soup",
            group: .init(id: "kitchen", label: "Kitchen"), source: .init(kind: "import", ref: "file:///Users/me/soup.md"),
            tags: ["lentils", "soup"], supersedes: "soup.v1", mediaType: .text, rememberedAt: Self.filed, payload: payload,
            image: .init(sha256: String(repeating: "ab", count: 32), width: 640, height: 480, mimeType: "image/png",
                         location: "file:///Users/me/soup.png", capturedAt: Date(timeIntervalSince1970: 1_792_000_000)),
            verified: .init(record: #"{"documentId":"notes/recipe/soup.v2"}"#, seal: "c2VhbA=="))
    }

    // MARK: - aii.v1.Record

    func testWhatAIIWritesIsTheProtosJSON() throws {
        let record = try fullRecord()
        let proto = try Aii_V1_Record(jsonString: String(decoding: try record.canonicalJSON(), as: UTF8.self), options: Self.strict)
        XCTAssertEqual(proto, Self.proto(record), "field for field")

        let minimal = AIIRecord(app: "notes", id: "n1", kind: .note, title: "Milk", group: .init(id: "home", label: "Home"),
                                rememberedAt: Self.filed)
        let sparse = try Aii_V1_Record(jsonString: String(decoding: try minimal.canonicalJSON(), as: UTF8.self), options: Self.strict)
        XCTAssertEqual(sparse, Self.proto(minimal))
        XCTAssertFalse(sparse.hasSupersedes || sparse.source.hasRef || sparse.hasPayload || sparse.hasImage || sparse.hasVerified)
    }

    func testWhatAPrinterWritesReadsAsTheSameRecord() throws {
        let record = try fullRecord()
        let json = try Self.proto(record).jsonString()
        XCTAssertEqual(AIIRecord.decode(Data(json.utf8)), record, json)

        var protoNames = JSONEncodingOptions()
        protoNames.preserveProtoFieldNames = true
        let snake = try Self.proto(record).jsonString(options: protoNames)
        XCTAssertTrue(snake.contains(#""remembered_at""#), snake)
        XCTAssertEqual(AIIRecord.decode(Data(snake.utf8)), record, "proto field names read too")
    }

    func testDefaultsAPrinterLeavesOutReadAsEmpty() throws {
        var proto = Aii_V1_Record()
        proto.format = AIIContract.recordFormat
        proto.app = "notes"
        proto.id = "n1"
        proto.kind = "note"
        let json = try proto.jsonString()
        XCTAssertFalse(json.contains("tags"), "a printer omits defaults: \(json)")
        let record = try XCTUnwrap(AIIRecord.decode(Data(json.utf8)))
        XCTAssertEqual(record.title, "")
        XCTAssertEqual(record.tags, [])
        XCTAssertEqual(record.group, AIIRecord.Group(id: "", label: ""))
        XCTAssertEqual(record.source, AIIRecord.Source(kind: ""))
        XCTAssertEqual(record.mediaType, .text)
        XCTAssertNil(record.supersedes)
        XCTAssertNil(record.payload)
        XCTAssertNil(record.image)
    }

    func testAPrintersFractionalSecondsReadToTheSecond() throws {
        var proto = Self.proto(try fullRecord())
        proto.rememberedAt = Google_Protobuf_Timestamp(seconds: 1_792_141_920, nanos: 750_000_000)
        let json = try proto.jsonString()
        XCTAssertTrue(json.contains("09:12:00.750Z"), json)
        XCTAssertEqual(AIIRecord.decode(Data(json.utf8))?.rememberedAt, Self.filed)
    }

    func testTheCanonicalBytes() throws {
        let payload = try JSONDecoder().decode(AIIJSONValue.self, from: Data(#"{"list": "milk/eggs", "count": 2}"#.utf8))
        let record = AIIRecord(app: "notes", id: "n1", kind: .note, title: "Errands", group: .init(id: "home", label: "Home"),
                               tags: ["errand"], rememberedAt: Self.filed.addingTimeInterval(0.9), payload: payload)
        XCTAssertEqual(String(decoding: try record.canonicalJSON(), as: UTF8.self),
                       #"{"app":"notes","format":"aii-record/1","group":{"id":"home","label":"Home"},"id":"n1","kind":"note","#
                       + #""mediaType":"text","payload":{"count":2,"list":"milk/eggs"},"rememberedAt":"2026-10-16T09:12:00Z","#
                       + #""source":{"kind":"app"},"tags":["errand"],"title":"Errands"}"#)
    }

    // MARK: - aii.v1.LaneManifest

    func testTheLanesManifestIsTheProtosJSON() throws {
        let test = TestHome()
        try test.home.register("notes", displayName: "My Notes", bundleIdentifier: "com.example.notes", owner: .local, by: .stack)
        try test.home.register("recipes", by: .app("recipes"))
        let written = try XCTUnwrap(FileManager.default.contents(atPath: test.home.lanesFile.path))
        let manifest = try Aii_V1_LaneManifest(jsonString: String(decoding: written, as: UTF8.self), options: Self.strict)
        let lanes = try XCTUnwrap(try AIILanes.load(home: test.home))

        XCTAssertEqual(manifest.format, AIILanes.format)
        XCTAssertEqual(Set(manifest.lanes.keys), ["notes", "recipes"])
        for (name, entry) in manifest.lanes {
            let lane = try XCTUnwrap(lanes.lane(for: AIIApp(stringLiteral: name)))
            XCTAssertEqual(entry.id, lane.id.rawValue)
            XCTAssertEqual(entry.derivedFrom, lane.derivedFrom)
            XCTAssertEqual(entry.registeredAt.date, lane.registeredAt)
            XCTAssertEqual(entry.displayName, lane.displayName)
            XCTAssertEqual(entry.hasBundleIdentifier ? entry.bundleIdentifier : nil, lane.bundleIdentifier)
            XCTAssertEqual(entry.registeredBy, lane.registeredBy.rawValue)
            XCTAssertEqual(entry.owner, lane.owner.rawValue)
        }
        XCTAssertEqual(manifest.lanes["notes"]?.owner, "aii-local")
        XCTAssertEqual(manifest.lanes["recipes"]?.owner, "local-recipes")
        XCTAssertEqual(manifest.lanes["recipes"]?.registeredBy, "recipes")

        // What a printer writes is a manifest AII reads.
        try PrivateFile.writeAtomically(Data(try manifest.jsonString().utf8), to: test.home.lanesFile, mode: 0o600)
        XCTAssertEqual(try AIILanes.load(home: test.home), lanes)
    }

    // MARK: - Field by field

    static func proto(_ record: AIIRecord) -> Aii_V1_Record {
        var proto = Aii_V1_Record()
        proto.format = record.format
        proto.app = record.app.rawValue
        proto.id = record.id
        proto.kind = record.kind.rawValue
        proto.title = record.title
        proto.group.id = record.group.id
        proto.group.label = record.group.label
        proto.source.kind = record.source.kind
        if let ref = record.source.ref { proto.source.ref = ref }
        proto.tags = record.tags
        if let supersedes = record.supersedes { proto.supersedes = supersedes }
        proto.mediaType = record.mediaType.rawValue
        proto.rememberedAt = Google_Protobuf_Timestamp(date: record.rememberedAt)
        if let payload = record.payload { proto.payload = value(payload) }
        if let image = record.image {
            proto.image.sha256 = image.sha256
            proto.image.width = UInt32(image.width)
            proto.image.height = UInt32(image.height)
            if let mimeType = image.mimeType { proto.image.mimeType = mimeType }
            if let location = image.location { proto.image.location = location }
            if let capturedAt = image.capturedAt { proto.image.capturedAt = Google_Protobuf_Timestamp(date: capturedAt) }
        }
        if let verified = record.verified {
            proto.verified.record = verified.record
            proto.verified.seal = verified.seal
        }
        return proto
    }

    static func value(_ json: AIIJSONValue) -> Google_Protobuf_Value {
        switch json {
        case .null: return Google_Protobuf_Value(nilLiteral: ())
        case .bool(let value): return Google_Protobuf_Value(boolValue: value)
        case .integer(let value): return Google_Protobuf_Value(numberValue: Double(value))
        case .number(let value): return Google_Protobuf_Value(numberValue: value)
        case .string(let value): return Google_Protobuf_Value(stringValue: value)
        case .array(let values): return Google_Protobuf_Value(listValue: Google_Protobuf_ListValue(values: values.map(value)))
        case .object(let fields): return Google_Protobuf_Value(structValue: Google_Protobuf_Struct(fields: fields.mapValues(value)))
        }
    }
}
