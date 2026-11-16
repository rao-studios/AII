//
//  ThreadCacheTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A cache writes its latest value, only when it changed, and folds the asks made while a write
//  runs into one more write.
//

import Foundation
import Logging
import XCTest
@testable import Thread

final class ThreadCacheTests: XCTestCase {
    private var root: URL!
    private let logger = Logger(label: "test")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thread-cache-\(UUID().uuidString)")
        FilePersistence.configure(dataDirectory: root.path)
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func onDisk(_ persistence: FilePersistence) -> [String]? {
        persistence.restore()
    }

    func testAWriteIsOfTheLatestValueAndOnlyWhenItChanged() async {
        let persistence = FilePersistence(key: "cache-a", kind: .basic, logger: logger)
        let cache = ThreadCache<[String]>(persistence: persistence)

        cache.seed(["seeded"])
        await cache.saveNow()
        XCTAssertNil(onDisk(persistence), "a seeded value is the one on disk: nothing written")

        cache.update(["one"])
        cache.update(["two"])
        await cache.saveNow()
        XCTAssertEqual(onDisk(persistence), ["two"])

        try? FileManager.default.removeItem(at: persistence.url)
        await cache.saveNow()
        XCTAssertNil(onDisk(persistence), "unchanged since the last write: not written again")
    }

    func testAsksDuringAWriteFoldIntoTheLatest() async throws {
        let persistence = FilePersistence(key: "cache-b", kind: .basic, logger: logger)
        let cache = ThreadCache<[String]>(persistence: persistence)
        for value in 0..<50 {
            cache.update(["\(value)"])
            cache.saveLatest()
        }
        for _ in 0..<200 where onDisk(persistence) != ["49"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(onDisk(persistence), ["49"])
    }
}
