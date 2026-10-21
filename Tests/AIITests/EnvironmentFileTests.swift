//
//  EnvironmentFileTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  aii/aii.env is merged, never clobbered: `update` reads what is there, keeps only the
//  allowed keys, drops empty values, writes 0600 under its lock, and removes the file when
//  nothing is left.
//

import Foundation
import XCTest
@testable import AII

final class EnvironmentFileTests: XCTestCase {

    func testUpdateMergesAndKeepsTheFilePrivate() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        XCTAssertTrue(try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_URL"] = "https://x.supabase.co" })
        XCTAssertEqual(EnvFile.read(test.home.aiiEnvFile), ["SUPABASE_URL": "https://x.supabase.co"])
        XCTAssertEqual(test.mode(test.home.aiiEnvFile), 0o600)

        XCTAssertTrue(try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_ANON_KEY"] = "anon" })
        XCTAssertEqual(EnvFile.read(test.home.aiiEnvFile), ["SUPABASE_URL": "https://x.supabase.co", "SUPABASE_ANON_KEY": "anon"], "merged, not replaced")
        XCTAssertFalse(try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_ANON_KEY"] = "anon" }, "the same value is no change")
        XCTAssertTrue(PrivateFile.exists(test.home.aiiEnvLockFile))
    }

    func testUpdateRefusesOtherKeysAndDropsEmptyValues() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        XCTAssertThrowsError(try AIIEnvironmentFile.update(home: test.home) { $0["MISTRAL_API_KEY"] = "k" }) { error in
            XCTAssertEqual(error as? AIIEnvironmentFile.WriteError, .disallowedKeys(["MISTRAL_API_KEY"]))
        }
        XCTAssertFalse(PrivateFile.exists(test.home.aiiEnvFile), "nothing written")

        XCTAssertFalse(try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_URL"] = "" }, "an empty value is nothing")
        XCTAssertFalse(PrivateFile.exists(test.home.aiiEnvFile))
    }

    func testUpdateRemovesTheFileWhenNothingIsLeft() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_URL"] = "u"; $0["SUPABASE_ANON_KEY"] = "a" }
        XCTAssertTrue(try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_URL"] = nil; $0["SUPABASE_ANON_KEY"] = nil })
        XCTAssertFalse(PrivateFile.exists(test.home.aiiEnvFile))
    }

    func testUpdateDropsWhatAWriterMayNotHold() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        try PrivateFile.ensureDirectory(test.home.aiiDirectory)
        try PrivateFile.writeAtomically(Data("SUPABASE_URL=u\nMISTRAL_API_KEY=sneaked\n".utf8), to: test.home.aiiEnvFile)
        XCTAssertTrue(try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_ANON_KEY"] = "a" })
        XCTAssertEqual(EnvFile.read(test.home.aiiEnvFile), ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"], "the denied key is gone")
        XCTAssertEqual(AIIEnvironmentFile.deniedKeys, Set([AIIHome.environmentKey]).union(ProviderKeyStore.sharedKeyNames))
    }
}
