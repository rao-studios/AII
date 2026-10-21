//
//  EnvExampleTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The checkout's .env.example stays the two-key template: bare KEY= lines the servers'
//  loaders read, nothing a copy would set by accident.
//

import Foundation
import XCTest
@testable import AII

final class EnvExampleTests: XCTestCase {

    private static var example: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent().appendingPathComponent(".env.example")
    }

    func testEveryLineIsAcommentOrABareAssignment() throws {
        let text = try String(contentsOf: Self.example, encoding: .utf8)
        let assignment = try NSRegularExpression(pattern: #"^[A-Z][A-Z0-9_]*=[^"'# ]*$"#)
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let string = String(line)
            XCTAssertNotNil(assignment.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)), "not a bare KEY=value: \(string)")
        }
    }

    func testItNamesTheTwoKeysAndSetsNothing() throws {
        let pairs = EnvFile.parse(try String(contentsOf: Self.example, encoding: .utf8))
        XCTAssertEqual(pairs.map(\.key), [ProviderKeyStore.mistralAPIKey, ProviderKeyStore.tinkerAPIKey])
        XCTAssertTrue(pairs.allSatisfy { $0.value.isEmpty }, "a copy sets nothing until filled in")
        XCTAssertEqual(ProviderKeyStore.sharedKeys(inEnvFile: Self.example), [:], "empty values are not keys")
    }
}
