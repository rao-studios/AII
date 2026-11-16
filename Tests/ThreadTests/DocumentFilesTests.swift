//
//  DocumentFilesTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A document's files live in one of 256 shard folders named by a stable hash of its id; a flat
//  documents/ folder is set aside with one rename and its files copied into shards by name, never
//  moved; an abandoned atomic save at the root goes once it is old.
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

    func testAFlatFolderIsSetAsideOnceAndItsFilesAreCopiedByName() throws {
        let ids = ["abc", "craft-abc/Sources/A+B.swift@v1"]
        for id in ids {
            try write(id, under: "documents")
            try write(id + "-parts", under: "documents")
        }

        DocumentFiles.setFlatAside(root: root, logger: logger)
        XCTAssertTrue(exists("documents-flat/abc"), "set aside whole, nothing moved out of it")
        XCTAssertFalse(DocumentFiles.isFlat(root.appendingPathComponent("documents")), "a fresh documents/")

        for id in ids {
            XCTAssertEqual(DocumentFiles.adopt(DocumentFiles.documentKey(id), root: root, logger: logger), .copied, id)
            XCTAssertEqual(DocumentFiles.adopt(DocumentFiles.partsKey(id), root: root, logger: logger), .copied, id)
            XCTAssertTrue(exists(DocumentFiles.documentKey(id)), id)
            XCTAssertTrue(exists(DocumentFiles.partsKey(id)), id)
            XCTAssertTrue(exists("documents-flat/" + id), "the flat copy stays: no change to the big folder")
        }
        XCTAssertEqual(DocumentFiles.adopt(DocumentFiles.documentKey("nowhere"), root: root, logger: logger), .absent)

        try write("late", under: "documents")
        DocumentFiles.setFlatAside(root: root, logger: logger)
        XCTAssertTrue(exists("documents/late"), "a second flat folder never replaces the one aside")

        FilePersistence.configure(dataDirectory: root.path)
        defer { FilePersistence.configure(dataDirectory: nil) }
        let store = FilePersistence(key: DocumentFiles.documentKey("abc"), kind: .basic, logger: logger)
        XCTAssertEqual(try Data(contentsOf: store.url), Data("abc".utf8), "a store finds the copied file")
    }

    func testNothingAsideIsNothingToCopy() {
        DocumentFiles.setFlatAside(root: root, logger: logger)
        XCTAssertFalse(exists("documents-flat"))
        XCTAssertEqual(DocumentFiles.adopt(DocumentFiles.documentKey("abc"), root: root, logger: logger), .absent)
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
