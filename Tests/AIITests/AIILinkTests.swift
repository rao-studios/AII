//
//  AIILinkTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 11/05/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Link's addresses, its credential, its note and its schema. `Schemas/Link/` is AII's
//  own: the schema file is the code's (AII_UPDATE_GOLDEN=1 rewrites it), and Link.md
//  names everything Link files.
//

import Foundation
import XCTest
@testable import AII

final class AIILinkTests: XCTestCase {

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func note(owner: String = "AII-Local") -> AIILinkNote {
        AIILinkNote(
            noteID: "6F1C2B4A-0000-4000-8000-000000000001", title: "Tide pools",
            body: "First paragraph.\n\nSecond paragraph.", folder: " Field notes ", tags: ["ocean", " "],
            device: .init(name: "Ritesh's iPhone", id: "device-1"),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_060),
            contentHash: "abc123", ownerID: owner, filedBy: .ambient)
    }

    func testLinkIsALaneEveryLaneReads() {
        XCTAssertEqual(AIILink.app.rawValue, "link")
        XCTAssertEqual(AIILanes.shared, [.link])
        XCTAssertEqual(AIILanes.defaultOwner(for: .link), .local, "files with no account under aii-local, as the Rao apps do")
        XCTAssertFalse(AIIApp.allCases.contains(.link), "no secret file is provisioned for it")
    }

    func testANoteIsFiledInItsOwnersOneGroup() throws {
        let note = note()
        XCTAssertEqual(AIILink.groupID(ownerID: "AII-Local"), "link-aii-local")
        XCTAssertEqual(note.group, AIILink.group(ownerID: "aii-local"))
        let document = try note.document(app: AIILink.app)
        XCTAssertEqual(document.documentID, AIILink.noteDocumentID(noteID: note.noteID, ownerID: "aii-local"))
        XCTAssertTrue(document.documentID.hasPrefix("link/note/"))
        XCTAssertEqual(document.wireGroupID, "link-aii-local")
        XCTAssertEqual(document.record.source, AIIRecord.Source(kind: "link", ref: note.noteID))
        XCTAssertEqual(note.folder, "Field notes", "a folder is a field, trimmed")
        XCTAssertEqual(note.tags, ["ocean"])
        XCTAssertNotEqual(AIILink.noteRecordID(noteID: note.noteID, ownerID: "someone"), note.recordID,
                          "another owner's copy never shares an id")
    }

    func testTheCardLeadsAndTheBodyFollows() throws {
        let texts = note().texts
        XCTAssertEqual(texts.count, 2)
        XCTAssertTrue(texts[0].hasPrefix("Note: Tide pools\nWritten on: Ritesh's iPhone\nWritten: "))
        XCTAssertTrue(texts[0].contains("\nFolder: Field notes\nTags: ocean"))
        XCTAssertEqual(texts[1], "First paragraph.\n\nSecond paragraph.")
        let long = AIILinkNote.pack(String(repeating: "A sentence here. ", count: 200), limit: AIILinkNote.partitionCharacters)
        XCTAssertTrue(long.allSatisfy { $0.count <= AIILinkNote.partitionCharacters })
    }

    func testThePayloadSaysItsFormatAndReadsBack() throws {
        let record = try note().envelope(app: AIILink.app)
        guard case .object(let payload)? = record.payload else { return XCTFail("a payload") }
        XCTAssertEqual(payload["format"], .string("link-note/1"))
        XCTAssertNil(payload["recordID"], "the envelope's id is not repeated")
        XCTAssertNil(payload["texts"], "the words ride the partitions")
        let back = try XCTUnwrap(try record.value(as: AIILinkNote.self))
        XCTAssertEqual(back.noteID, note().noteID)
        XCTAssertEqual(back.filedBy, .ambient)
        XCTAssertEqual(back.device.kind, "phone")
    }

    func testTheCredentialIsDerivedAndTheKeyringKnowsIt() throws {
        let test = TestHome()
        XCTAssertNil(try AIILink.secret(home: test.home), "no device key yet, no credential")
        let (key, _) = try AIIDeviceKey.loadOrCreate(home: test.home)
        let secret = try XCTUnwrap(try AIILink.secret(home: test.home))
        XCTAssertEqual(secret, AIILink.secret(deviceKey: key))
        XCTAssertTrue(StackSecret.isWellFormedSecret(secret))
        let ring = StackKeyring(home: test.home)
        XCTAssertEqual(ring.app(forPresented: secret), .link)
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.home.secretsDirectory.appendingPathComponent("link").path),
                       "nothing is written under secrets/")
    }

    func testTheSchemaFileIsTheCodes() throws {
        let url = repository.appendingPathComponent("Schemas/Link/link-note.schema.json")
        let generated = AIILinkSchemaJSON.noteJSON
        if ProcessInfo.processInfo.environment["AII_UPDATE_GOLDEN"] != nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try generated.write(to: url)
        }
        let checkedIn = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: checkedIn, as: UTF8.self), String(decoding: generated, as: UTF8.self),
                       "Schemas/Link/link-note.schema.json is stale; regenerate with AII_UPDATE_GOLDEN=1")
    }

    func testANoteIsWhatItsSchemaSays() throws {
        guard case .object(let schema) = AIILinkSchemaJSON.note,
              case .object(let properties)? = schema["properties"],
              case .object(let id)? = properties["id"], case .string(let pattern)? = id["pattern"],
              case .object(let app)? = properties["app"], case .object(let kind)? = properties["kind"]
        else { return XCTFail("the schema's shape") }
        let record = try note().envelope(app: AIILink.app)
        XCTAssertNotNil(record.id.range(of: pattern, options: .regularExpression), "\(record.id) against \(pattern)")
        XCTAssertEqual(app["const"], .string(record.app.rawValue))
        XCTAssertEqual(kind["const"], .string(record.kind.rawValue))
        XCTAssertEqual(schema["$id"], .string(AIILinkNote.format))
    }

    func testLinkMdNamesEverythingLinkFiles() throws {
        let text = try String(contentsOf: repository.appendingPathComponent("Schemas/Link/Link.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# link-storage/1\n"))
        let named = ["`link`", "link-<owner>", "link/note/", "`note`", AIILinkNote.format, AIIContract.recordFormat,
                     "aii-local", AIILink.credentialLabel, "keys/device.key", "link-note.schema.json"]
        let missing = named.filter { !text.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Schemas/Link/Link.md does not name: \(missing)")
    }
}
