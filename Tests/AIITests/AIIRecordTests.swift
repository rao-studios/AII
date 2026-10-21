//
//  AIIRecordTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  aii-record/1: the envelope's bytes are stable and its wire addresses readable; any
//  writer's form reads; an app's own type goes in as the payload and comes back as itself;
//  long text is split into partitions without losing a word.
//

import Foundation
import XCTest
@testable import AII

/// An app's own record type, as an app would write it.
struct TestNote: AIIRecordable, Equatable {
    static let kind: AIIRecord.Kind = "note"
    static let group = AIIRecord.Group(id: "notes", label: "Notes")
    var recordID: String
    var title: String
    var body: String
    var pinned: Bool = false
    var count: Int = 0
    var text: String { body }
}

/// One that says more about itself.
struct TestTask: AIIRecordable, Equatable {
    static let kind: AIIRecord.Kind = "task"
    static let group = AIIRecord.Group(id: "tasks", label: "Tasks")
    var recordID: String
    var title: String
    var due: Date
    var replaces: String?
    var text: String { title }
    var tags: [String] { ["todo", "work"] }
    var supersedes: String? { replaces }
}

final class AIIRecordTests: XCTestCase {

    private func record(_ id: String = "standup-1015", tags: [String] = [], extras: AIIJSONValue? = nil) -> AIIRecord {
        AIIRecord(app: "notes", id: id, kind: .note, title: "Stand-up", group: .init(id: "standups", label: "Stand-ups"),
                  tags: tags, rememberedAt: Date(timeIntervalSince1970: 1_760_000_000.75), payload: extras)
    }

    func testTheBytesAreStableAndIndependentOfOrder() throws {
        let a = record(extras: .object(["z": .integer(1), "a": .string("x/y"), "m": .array([.bool(true), .null])]))
        let b = record(extras: .object(["m": .array([.bool(true), .null]), "a": .string("x/y"), "z": .integer(1)]))
        XCTAssertEqual(try a.canonicalJSON(), try b.canonicalJSON())
        let json = String(decoding: try a.canonicalJSON(), as: UTF8.self)
        XCTAssertFalse(json.contains(#"\/"#), "slashes are not escaped: \(json)")
        XCTAssertTrue(json.contains(#""format":"aii-record/1""#), json)
        XCTAssertTrue(json.contains(#""rememberedAt":"2025-10-09T08:53:20Z""#), "to the second: \(json)")
        XCTAssertEqual(AIIRecord.decode(try a.canonicalJSON()), a, "round trip")
        XCTAssertNil(AIIRecord.decode(Data(#"{"type":"record"}"#.utf8)), "another app's metadata is no envelope")
        XCTAssertNil(AIIRecord.decode(Data()))
    }

    func testWhereAnAppsRecordIsFiled() {
        XCTAssertEqual(record().documentID, "notes/note/standup-1015")
        XCTAssertEqual(AIIRecord.groupID(app: "notes", group: "standups"), "notes-standups")
        let parsed = AIIRecord.parseDocumentID("notes/note/standup-1015")
        XCTAssertEqual(parsed?.app, "notes")
        XCTAssertEqual(parsed?.kind, .note)
        XCTAssertEqual(parsed?.id, "standup-1015")
        XCTAssertNil(AIIRecord.parseDocumentID("notes/note/a/b"), "an id never holds a slash")
        XCTAssertNil(AIIRecord.parseDocumentID("Notes/note/a"), "not an app name")
        XCTAssertNil(AIIRecord.parseDocumentID("chat-recap-notes-local-notes"), "Sewn's own ids")

        let group = AIIRecord.parseGroupID("notes-standups")
        XCTAssertEqual(group?.app, "notes")
        XCTAssertEqual(group?.group, "standups")
        XCTAssertEqual(AIIRecord.parseGroupID("notes-memory-aii-local")?.group, "memory-aii-local",
                       "an app name holds no dash, so the first one splits")
        XCTAssertNil(AIIRecord.parseGroupID("notes-"))
        XCTAssertNil(AIIRecord.parseGroupID("standups"))
    }

    func testValidation() {
        XCTAssertNoThrow(try record().validate())
        XCTAssertThrowsError(try record("a/b").validate()) { XCTAssertEqual($0 as? AIIRecordError, .invalidID("a/b")) }
        XCTAssertThrowsError(try record("").validate())
        var badGroup = record()
        badGroup.group.id = "Stand Ups"
        XCTAssertThrowsError(try badGroup.validate()) { XCTAssertEqual($0 as? AIIRecordError, .invalidGroup("Stand Ups")) }
        var badSupersedes = record()
        badSupersedes.supersedes = "x/y"
        XCTAssertThrowsError(try badSupersedes.validate()) { XCTAssertEqual($0 as? AIIRecordError, .invalidID("x/y")) }
        XCTAssertNil(AIIRecord.Kind(rawValue: "Note"))
        XCTAssertNotNil(AIIRecord.Kind(rawValue: "recipe"))
    }

    func testAnyWritersFormReads() throws {
        // Proto field names, a fraction and an offset, absent fields, a field AII doesn't know,
        // and a kind and media type it has no constant for.
        let json = #"{"format":"aii-record/1","app":"notes","id":"x1","kind":"voice-memo","media_type":"audio","#
            + #""remembered_at":"2025-10-09T10:53:20.900+02:00","added_later":{"a":1}}"#
        let record = try XCTUnwrap(AIIRecord.decode(Data(json.utf8)))
        XCTAssertEqual(record.kind.rawValue, "voice-memo")
        XCTAssertEqual(record.mediaType.rawValue, "audio")
        XCTAssertEqual(record.rememberedAt, Date(timeIntervalSince1970: 1_760_000_000), "08:53:20Z, to the second")
        XCTAssertEqual(record.title, "")
        XCTAssertEqual(record.tags, [])
        XCTAssertEqual(record.group, AIIRecord.Group(id: "", label: ""))
        XCTAssertNil(record.payload)

        let odd = #"{"format":"aii-record/1","app":"notes","id":"x1","kind":"Voice Memo","group":{"id":"g","label":"G"}}"#
        let unfileable = try XCTUnwrap(AIIRecord.decode(Data(odd.utf8)), "a kind AII can't file still reads")
        XCTAssertFalse(unfileable.kind.isValid)
        XCTAssertThrowsError(try unfileable.validate()) { XCTAssertEqual($0 as? AIIRecordError, .invalidKind("Voice Memo")) }

        XCTAssertNil(AIIRecord.decode(Data(#"{"format":"aii-record/2","app":"notes","id":"x1","kind":"note"}"#.utf8)),
                     "another format")
        XCTAssertNil(AIIRecord.decode(Data(#"{"format":"aii-record/1","app":"No App","id":"x1","kind":"note"}"#.utf8)),
                     "no app")
    }
}

final class AIIRecordableTests: XCTestCase {

    func testAValueGoesInAsItsPayloadAndComesBackAsItself() throws {
        let note = TestNote(recordID: "n1", title: "Stand-up", body: "Ada leads Joltvault.", pinned: true, count: 3)
        let envelope = try note.envelope(app: "notes", now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(envelope.kind, .note)
        XCTAssertEqual(envelope.group, TestNote.group)
        XCTAssertEqual(envelope.source.kind, "app")
        XCTAssertEqual(try envelope.value(as: TestNote.self), note)
        XCTAssertNil(try envelope.value(as: TestTask.self), "another kind is not this type")

        let decoded = try XCTUnwrap(AIIRecord.decode(try envelope.canonicalJSON()))
        XCTAssertEqual(try decoded.value(as: TestNote.self), note, "through the bytes Thread keeps")

        let document = try note.document(app: "notes", now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(document.record, envelope)
        XCTAssertEqual(document.documentID, "notes/note/n1")
        XCTAssertEqual(document.wireGroupID, "notes-notes")
        XCTAssertEqual(document.partitions, [AIIDocument.Partition(text: "Ada leads Joltvault.")])
    }

    func testATypeCanSayMoreAboutItself() throws {
        let due = Date(timeIntervalSince1970: 1_760_000_000)
        let task = TestTask(recordID: "t2", title: "Ship the index", due: due, replaces: "t1")
        let envelope = try task.envelope(app: "notes")
        XCTAssertEqual(envelope.tags, ["todo", "work"])
        XCTAssertEqual(envelope.supersedes, "t1")
        XCTAssertEqual(try envelope.value(as: TestTask.self)?.due, due, "dates survive the payload")
        XCTAssertEqual(try task.document(app: "notes").graphEntities.map(\.name), ["todo", "work"])
    }

    func testAValueThatCantBeFiledIsRefused() {
        XCTAssertThrowsError(try TestNote(recordID: "a/b", title: "x", body: "y").envelope(app: "notes"))
        XCTAssertThrowsError(try TestNote(recordID: "ok", title: "x", body: "   ").document(app: "notes")) {
            XCTAssertEqual($0 as? AIIRecordError, .noPartitions("ok"), "nothing to index")
        }
    }
}

final class AIIChunkerTests: XCTestCase {

    func testShortTextIsOnePiece() {
        XCTAssertEqual(AIIChunker.split("One paragraph.\n\nAnother."), ["One paragraph.\n\nAnother."])
        XCTAssertEqual(AIIChunker.split("   \n\n "), [])
    }

    func testParagraphsArePackedUnderTheTarget() {
        let paragraph = String(repeating: "word ", count: 120).trimmingCharacters(in: .whitespaces)   // 599 characters
        let pieces = AIIChunker.split(Array(repeating: paragraph, count: 5).joined(separator: "\n\n"))
        XCTAssertEqual(pieces.count, 3)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 1_500 }, "\(pieces.map(\.count))")
    }

    func testALongParagraphIsCutAtSentenceEnds() {
        let sentence = "Ada leads Joltvault and the team ships every Thursday afternoon. "
        let paragraph = String(repeating: sentence, count: 80).trimmingCharacters(in: .whitespaces)   // ~5,000 characters
        let pieces = AIIChunker.split(paragraph)
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 2_000 && !$0.isEmpty })
        XCTAssertTrue(pieces.allSatisfy { $0.hasSuffix("afternoon.") }, "cut between sentences")
        XCTAssertEqual(pieces.joined(separator: " ").filter { !$0.isWhitespace }, paragraph.filter { !$0.isWhitespace },
                       "nothing lost but whitespace")
    }

    func testASentenceLongerThanTheMaximumIsCutHard() {
        let pieces = AIIChunker.split(String(repeating: "x", count: 4_500))
        XCTAssertEqual(pieces.map(\.count), [2_000, 2_000, 500])
    }
}
