//
//  AIILabelTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  An AII's own name: what a label may be, the file in the home, what a running
//  server reads at each /health, and that /health says it to whoever asks.
//

import Foundation
import XCTest
@testable import AII

final class AIILabelTests: XCTestCase {

    func testWhatALabelMayBe() {
        let rows: [(label: String, text: String, expected: String?)] = [
            ("a handle", "craft-frameworks", "craft-frameworks"),
            ("words with spaces", "Apple Reasoning", "Apple Reasoning"),
            ("trimmed", "  atlas \n", "atlas"),
            ("empty", "", nil),
            ("only spaces", "   ", nil),
            ("two lines", "a\nb", nil),
            ("a tab inside", "a\tb", nil),
            ("64 characters", String(repeating: "x", count: 64), String(repeating: "x", count: 64)),
            ("65 characters", String(repeating: "x", count: 65), nil),
            ("emoji count as one", String(repeating: "🧵", count: 64), String(repeating: "🧵", count: 64)),
        ]
        for row in rows { XCTAssertEqual(AIILabel.normalized(row.text), row.expected, row.label) }
    }

    func testTheFileIsWrittenReadAndCleared() throws {
        let test = TestHome()
        XCTAssertNil(AIILabel.read(home: test.home), "no label until someone names it")
        XCTAssertEqual(try AIILabel.write("  Atlas ", home: test.home), "Atlas")
        XCTAssertEqual(AIILabel.read(home: test.home), "Atlas")
        XCTAssertEqual(test.mode(test.home.labelFile), 0o600)
        XCTAssertThrowsError(try AIILabel.write("a\nb", home: test.home)) { error in
            XCTAssertEqual(error as? AIILabelError, .invalid("a\nb"))
        }
        XCTAssertEqual(AIILabel.read(home: test.home), "Atlas", "a refused label leaves the old one")
        AIILabel.clear(home: test.home)
        XCTAssertNil(AIILabel.read(home: test.home))
        AIILabel.clear(home: test.home)   // nothing to clear is not an error
    }

    func testARunningServerSeesANewLabelWithoutARestart() throws {
        let test = TestHome()
        XCTAssertNil(AIILabel.current(home: test.home))
        try AIILabel.write("first", home: test.home)
        XCTAssertEqual(AIILabel.current(home: test.home), "first")
        try AIILabel.write("the second", home: test.home)
        XCTAssertEqual(AIILabel.current(home: test.home), "the second")
        AIILabel.clear(home: test.home)
        XCTAssertNil(AIILabel.current(home: test.home))
    }

    func testHealthSaysTheHomesLabelToEveryone() throws {
        let test = TestHome()
        try PrivateFile.ensureDirectory(test.home.root)
        let mode = StackMode.multiApp(StackKeyring(home: test.home))
        XCTAssertNil(mode.healthAnswer(nonce: nil, requestedApp: nil).label, "no label: none said")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertFalse(String(decoding: try encoder.encode(mode.healthAnswer(nonce: nil, requestedApp: nil)), as: UTF8.self)
            .contains("label"), "an AII with no label says nothing of one, not null")

        try AIILabel.write("craft-frameworks", home: test.home)
        let unasked = mode.healthAnswer(nonce: nil, requestedApp: nil)
        XCTAssertEqual(unasked.label, "craft-frameworks", "keyless: a label is public")
        XCTAssertNil(unasked.proof)
        XCTAssertTrue(String(decoding: try encoder.encode(unasked), as: UTF8.self).contains(#""label":"craft-frameworks""#))
        XCTAssertNil(StackMode.open.healthAnswer(nonce: nil, requestedApp: nil).label, "an open server has no home, so no label")
    }
}
