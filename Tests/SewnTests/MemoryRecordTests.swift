//
//  MemoryRecordTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  What Sewn writes back from a conversation is filed in the aii-record/1 envelope every
//  app's records use, kind `memory`, in groups named for the caller's app, so an app's
//  recall decodes it through the one path and two apps sharing an owner never share a
//  memory group.
//

import AII
import Foundation
import XCTest
@testable import Sewn

final class MemoryRecordTests: XCTestCase {

    func testEachWriteBackIsAMemoryRecordOfTheCallersApp() throws {
        let cases: [(SewnCore.MemoryWriter, String, String)] = [
            (.summary, "memory-aii-local", "Conversation memory"),
            (.recap, "memory-aii-local", "Chat recap"),
            (.resonance, "resonance-aii-local", "Resonant passage"),
        ]
        for (writer, group, title) in cases {
            let data = try XCTUnwrap(SewnCore.memoryMetadata(writer, id: "doc-1", groupLabel: "Memory", tags: ["joltvault"],
                                                             ownerId: "aii-local", app: "notes"))
            let record = try XCTUnwrap(AIIRecord.decode(data), "\(writer)")
            XCTAssertEqual(record.kind, .memory)
            XCTAssertEqual(record.app, "notes")
            XCTAssertEqual(record.id, "doc-1")
            XCTAssertEqual(record.documentID, SewnCore.memoryDocumentId("doc-1", app: "notes"), "the envelope's id is the document's")
            XCTAssertEqual(record.group.id, group)
            XCTAssertEqual(AIIRecord.groupID(app: record.app, group: record.group.id),
                           SewnCore.memoryGroupId(writer.group, ownerId: "aii-local", app: "notes"),
                           "the envelope names the wire group it is filed in")
            XCTAssertEqual(record.title, title)
            XCTAssertEqual(record.source.kind, writer.rawValue)
            XCTAssertEqual(record.tags, ["joltvault"])
            XCTAssertNil(record.payload, "the text is the partition, not the envelope")
        }
    }

    func testTwoAppsSharingAnOwnerWriteIntoTheirOwnGroups() {
        XCTAssertEqual(SewnCore.memoryGroupId("memory", ownerId: "aii-local", app: .ambient), "ambient-memory-aii-local")
        XCTAssertEqual(SewnCore.memoryGroupId("memory", ownerId: "aii-local", app: .veil), "veil-memory-aii-local")
        XCTAssertEqual(SewnCore.memoryGroupId("resonance", ownerId: "local-notes", app: "notes"), "notes-resonance-local-notes")
        XCTAssertEqual(SewnCore.memoryDocumentId("doc-1", app: "notes"), "notes/memory/doc-1")
    }

    /// An open, hosted Sewn's caller is no app: it has no lane, and no envelope.
    func testNoAppNoEnvelope() {
        XCTAssertNil(SewnCore.memoryMetadata(.summary, id: "doc-1", groupLabel: "Memory", tags: [], ownerId: "person-1", app: nil))
        XCTAssertEqual(SewnCore.memoryGroupId("memory", ownerId: "person-1", app: nil), "memory-person-1")
        XCTAssertEqual(SewnCore.memoryDocumentId("doc-1", app: nil), "doc-1")
    }
}
