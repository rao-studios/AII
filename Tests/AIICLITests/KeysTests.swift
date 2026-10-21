//
//  KeysTests.swift
//  AIICLITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  `aii keys` never prints a value, refuses to replace an account's key by accident, takes
//  only a Supabase URL that looks like one, and asks nothing without a terminal.
//

import AII
import Foundation
import XCTest
@testable import AIICLI

final class KeysTests: XCTestCase {
    private let home = AIIHome(root: URL(fileURLWithPath: "/tmp/rao-keys-test"))
    private let when = Date(timeIntervalSince1970: 1_792_000_000)

    func testAValueIsMaskedToItsLastFour() {
        XCTAssertEqual(KeysCommand.mask("abcdefghijk9Qz"), "…k9Qz")
        XCTAssertEqual(KeysCommand.mask("abcdefgh"), "…efgh")
        XCTAssertEqual(KeysCommand.mask("short"), "····")
        XCTAssertEqual(KeysCommand.mask(""), "····")
    }

    func testTheRowsSayWhatIsSetAndWhereEachLands() {
        let records = ["MISTRAL_API_KEY": ProviderKeyRecord(value: "mistral-key-k9Qz", source: .typed, writtenBy: .app(.ambient), updatedAt: when)]
        let rows = KeysCommand.rows(records: records, environment: [:], home: home)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], "MISTRAL_API_KEY   …k9Qz  typed  ambient  \(Stamp.minute(when))")
        XCTAssertFalse(rows[0].contains("mistral-key"), "never the value")
        XCTAssertEqual(rows[1], "TINKER_API_KEY    none → aii keys set tinker")
        XCTAssertEqual(rows[2], "SUPABASE_URL      none · no accounts layer → aii keys supabase --url … --anon-key …")
        XCTAssertTrue(rows[3].contains("read per call: a change is live, no restart"), rows[3])

        let withSupabase = KeysCommand.rows(records: [:], environment: ["SUPABASE_URL": "https://x.supabase.co", "SUPABASE_ANON_KEY": "anon-key-1234"], home: home)
        XCTAssertEqual(withSupabase[2], "SUPABASE_URL      https://x.supabase.co  aii.env")
        XCTAssertEqual(withSupabase[3], "SUPABASE_ANON_KEY …1234  aii.env")
    }

    func testAnAccountsKeyIsRefusedWithoutForce() {
        let account = ProviderKeyRecord(value: "from-account", source: .account, writtenBy: .app(.ambient), updatedAt: when)
        let typed = ProviderKeyRecord(value: "typed", source: .typed, writtenBy: .stack, updatedAt: when)
        let refusal = KeysCommand.refusal(existing: account, force: false, provider: .mistral)
        XCTAssertEqual(refusal?.code, .usage)
        XCTAssertEqual(refusal?.message, "MISTRAL_API_KEY came from an account (written by ambient)")
        XCTAssertNil(KeysCommand.refusal(existing: account, force: true, provider: .mistral))
        XCTAssertNil(KeysCommand.refusal(existing: typed, force: false, provider: .mistral))
        XCTAssertNil(KeysCommand.refusal(existing: nil, force: false, provider: .tinker))
    }

    func testOnlyAProjectURLIsASupabaseURL() throws {
        XCTAssertEqual(try KeysCommand.supabaseURL(" https://xyz.supabase.co "), "https://xyz.supabase.co")
        XCTAssertThrowsError(try KeysCommand.supabaseURL("http://xyz.supabase.co")) { XCTAssertEqual(($0 as? AIIFailure)?.code, .usage) }
        XCTAssertThrowsError(try KeysCommand.supabaseURL("xyz"))
        XCTAssertThrowsError(try KeysCommand.supabaseURL(""))
    }

    func testThePromptAnswersNilWithoutATerminal() {
        XCTAssertNil(TerminalPrompt.readSecret("key: ", reader: .scripted([nil])))
        let reader = TerminalPrompt.Reader.scripted([" first ", "second"])
        XCTAssertEqual(TerminalPrompt.readSecret("key: ", reader: reader), "first")
        XCTAssertEqual(TerminalPrompt.readLine("url: ", reader: reader), "second")
        XCTAssertNil(TerminalPrompt.readLine("more: ", reader: reader), "out of answers")
        XCTAssertEqual(KeysCommand.Provider.mistral.keyName, ProviderKeyStore.mistralAPIKey)
        XCTAssertEqual(KeysCommand.Provider(argument: "tinker")?.label, "Tinker")
        XCTAssertNil(KeysCommand.Provider(argument: "openai"))
    }
}
