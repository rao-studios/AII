//
//  DocumentFilesTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A document's files live in one of 256 shard folders named by a stable hash of its id, and a
//  flat documents/ folder moves into them once, resuming after a stop and never dropping a file
//  it could not move; an abandoned atomic save at the root goes once it is old.
//

import Foundation
import Logging
import XCTest
@testable import Thread

final class DocumentFilesTests: XCTestCase {
    private var root: URL!
    private let logger = Logger(label: "test")
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        root = fm.temporaryDirectory.appendingPathComponent("thread-document-files-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
        super.tearDown()
    }

    private func write(_ relative: String, under folder: String) throws {
        let url = root.appendingPathComponent(folder).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(relative.utf8).write(to: url)
    }

    private func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(relative).path(percentEncoded: false))
    }

    func testTheShardIsTheSameHashInEveryProcess() {
        // FNV-1a's low byte, pinned: a change here strands every node's files.
        let rows: [(id: String, shard: String)] = [
            ("abc", "0b"),
            ("craft-abc/Sources/A+B.swift@v1", "9e"),
            ("25532111211211042445611413025323219505194047960116253898723119923219212509073820038", "cf"),
        ]
        for row in rows {
            XCTAssertEqual(DocumentFiles.shard(row.id), row.shard, row.id)
            XCTAssertEqual(DocumentFiles.documentKey(row.id), "documents/\(row.shard)/\(row.id)")
            XCTAssertEqual(DocumentFiles.partsKey(row.id), "documents/\(row.shard)/\(row.id)-parts")
        }
    }

    func testAFlatFolderMovesIntoShardsOnceAndItsTempFilesGo() throws {
        let ids = ["abc", "craft-abc/Sources/A+B.swift@v1"]
        for id in ids {
            try write(id, under: "documents")
            try write(id + "-parts", under: "documents")
        }
        try write("abc.sb-703cdddb-KBsXcX", under: "documents")

        XCTAssertTrue(DocumentFiles.shardFlatLayout(root: root, logger: logger))
        for id in ids {
            XCTAssertTrue(exists(DocumentFiles.documentKey(id)), id)
            XCTAssertTrue(exists(DocumentFiles.partsKey(id)), id)
        }
        XCTAssertFalse(exists("documents/abc"), "nothing is left at the top")
        XCTAssertFalse(exists("documents-flat"), "the emptied folder is gone")
        XCTAssertFalse(DocumentFiles.isFlat(root.appendingPathComponent("documents")))

        XCTAssertTrue(DocumentFiles.shardFlatLayout(root: root, logger: logger), "a sharded folder is left as it is")
        FilePersistence.configure(dataDirectory: root.path)
        defer { FilePersistence.configure(dataDirectory: nil) }
        let store = FilePersistence(key: DocumentFiles.documentKey("abc"), kind: .basic, logger: logger)
        XCTAssertEqual(try Data(contentsOf: store.url), Data("abc".utf8), "a store finds the moved file")
    }

    func testAMoveThatStoppedResumesFromTheFlatFolder() throws {
        // Stopped after "abc" moved and before "def" did: both copies of "abc" exist.
        try write("abc", under: "documents-flat")
        try write("def", under: "documents-flat")
        try write(String(DocumentFiles.documentKey("abc").dropFirst("documents/".count)), under: "documents")

        XCTAssertTrue(DocumentFiles.shardFlatLayout(root: root, logger: logger))
        XCTAssertTrue(exists(DocumentFiles.documentKey("abc")))
        XCTAssertTrue(exists(DocumentFiles.documentKey("def")))
        XCTAssertFalse(exists("documents-flat"))
    }

    func testNoDocumentsFolderIsNothingToMove() {
        XCTAssertTrue(DocumentFiles.shardFlatLayout(root: root, logger: logger))
        XCTAssertFalse(exists("documents-flat"))
    }

    func testAnAbandonedSaveGoesOnlyOnceItIsOld() throws {
        try write("table-x.sb-1-old", under: ".")
        try write("table-x.sb-2-new", under: ".")
        let old = root.appendingPathComponent("table-x.sb-1-old").path(percentEncoded: false)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old)
        FilePersistence.removeAbandonedSaves(under: root)
        XCTAssertFalse(exists("table-x.sb-1-old"))
        XCTAssertTrue(exists("table-x.sb-2-new"), "a write in progress elsewhere is left alone")
    }
}
