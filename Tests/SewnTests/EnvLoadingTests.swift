//
//  EnvLoadingTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Where Sewn's configuration comes from on a shared ~/.rao stack, in the
//  order SewnServer applies it: the process environment wins over
//  AII_HOME/aii/aii.env, which is applied through AII's EnvFile with
//  AIIEnvironmentFile's denylist so it can never supply a secret, a key or
//  AII_HOME itself; and provider keys come from AII_HOME's providers.json
//  before the environment. Every variable touched is cleared again.
//

import Foundation
import AII
import XCTest
@testable import Sewn

final class EnvLoadingTests: XCTestCase {
    private var home: AIIHome!
    private var touched: Set<String> = []

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sewn-env-\(UUID().uuidString)", isDirectory: true)
        home = AIIHome(root: root)
        try? FileManager.default.createDirectory(at: home.aiiDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for key in touched { unsetenv(key) }
        try? FileManager.default.removeItem(at: home.root)
        super.tearDown()
    }

    private func set(_ key: String, _ value: String) {
        touched.insert(key)
        setenv(key, value, 1)
    }

    private func clear(_ key: String) {
        touched.insert(key)
        unsetenv(key)
    }

    private func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    private func writeSewnEnv(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: home.aiiEnvFile, atomically: true, encoding: .utf8)
    }

    private func applySewnEnv() -> [String] {
        EnvFile.apply(home.aiiEnvFile, denying: AIIEnvironmentFile.deniedKeys)
    }

    func testTheProcessEnvironmentWinsOverSewnEnv() throws {
        set("SUPABASE_URL", "https://from-process.example")
        clear("SUPABASE_ANON_KEY")
        try writeSewnEnv([
            "# written by an app",
            "SUPABASE_URL=https://from-file.example",
            "SUPABASE_ANON_KEY=\"anon-from-file\"",
        ])

        let applied = applySewnEnv()

        XCTAssertEqual(env("SUPABASE_URL"), "https://from-process.example", "a value the launcher set is never overwritten")
        XCTAssertEqual(env("SUPABASE_ANON_KEY"), "anon-from-file", "a value the launcher left unset comes from the file, quotes stripped")
        // `applied` names every key offered, not only those that took effect:
        // the environment decides, and the assertions above are the contract.
        XCTAssertEqual(Set(applied), ["SUPABASE_ANON_KEY", "SUPABASE_URL"])
    }

    func testDenylistedKeysAreNeverApplied() throws {
        for key in AIIEnvironmentFile.deniedKeys { clear(key) }
        clear("SUPABASE_ANON_KEY")
        try writeSewnEnv([
            "MISTRAL_API_KEY=leaked-mistral",
            "TINKER_API_KEY=leaked-tinker",
            "AII_HOME=/somewhere/else",
            "SUPABASE_ANON_KEY=anon-from-file",
        ])

        let applied = applySewnEnv()

        for key in AIIEnvironmentFile.deniedKeys {
            XCTAssertNil(env(key), "\(key) must never come from aii.env")
        }
        XCTAssertEqual(env("SUPABASE_ANON_KEY"), "anon-from-file")
        XCTAssertEqual(applied, ["SUPABASE_ANON_KEY"])
        XCTAssertTrue(AIIEnvironmentFile.deniedKeys.isSuperset(of: [
            "MISTRAL_API_KEY", "TINKER_API_KEY", "AII_HOME",
        ]), "the denylist names every provider key and the home itself")
    }

    func testAMissingSewnEnvAppliesNothing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.aiiEnvFile.path))
        XCTAssertEqual(applySewnEnv(), [])
    }

    func testTheDotEnvLoaderNeverOverwritesEither() throws {
        set("SUPABASE_URL", "https://from-process.example")
        clear("SEWN_ENV_LOADING_PROBE")
        let dotEnv = home.root.appendingPathComponent(".env")
        try "SUPABASE_URL=https://from-dotenv.example\nSEWN_ENV_LOADING_PROBE='probe'\n"
            .write(to: dotEnv, atomically: true, encoding: .utf8)

        loadDotEnv(path: dotEnv.path)

        XCTAssertEqual(env("SUPABASE_URL"), "https://from-process.example", ".env is last in line")
        XCTAssertEqual(env("SEWN_ENV_LOADING_PROBE"), "probe")
    }

    func testProviderKeysComeFromTheSharedFileBeforeTheEnvironment() throws {
        let store = ProviderKeyStore(home: home, environment: { ["MISTRAL_API_KEY": "from-env"] })
        XCTAssertTrue(store.isFileBacked)
        XCTAssertEqual(store.value(for: ProviderKeyStore.mistralAPIKey), "from-env", "no file yet: the environment answers")

        try store.write(ProviderKeyStore.mistralAPIKey, value: "from-file", source: .typed, writtenBy: .ambient)
        XCTAssertEqual(store.value(for: ProviderKeyStore.mistralAPIKey), "from-file", "a key any app saved wins")
        XCTAssertNil(store.value(for: ProviderKeyStore.tinkerAPIKey), "a key nobody set is nil, not empty")

        try store.write(ProviderKeyStore.mistralAPIKey, value: "", source: .typed, writtenBy: .craft)
        XCTAssertEqual(store.value(for: ProviderKeyStore.mistralAPIKey), "from-env", "an emptied record falls back to the environment")

        let environmentOnly = ProviderKeyStore(home: nil, environment: { ["MISTRAL_API_KEY": "hosted"] })
        XCTAssertFalse(environmentOnly.isFileBacked)
        XCTAssertEqual(environmentOnly.value(for: ProviderKeyStore.mistralAPIKey), "hosted", "without AII_HOME nothing changes for a hosted Sewn")
    }

    func testSewnsEndpointsNameTheSharedKeys() {
        XCTAssertEqual(NetworkService.BaseEndpoint.mistral.apiKeyEnvVar, ProviderKeyStore.mistralAPIKey)
        XCTAssertEqual(NetworkService.BaseEndpoint.tinker.apiKeyEnvVar, ProviderKeyStore.tinkerAPIKey)
        XCTAssertEqual(NetworkService.BaseEndpoint.supabase.apiKeyEnvVar, "SUPABASE_ANON_KEY")

        // Supabase reads the environment alone; a shared file can't supply it.
        set("SUPABASE_ANON_KEY", "anon")
        XCTAssertEqual(NetworkService.BaseEndpoint.supabase.apiKeyIfPresent, "anon")
        set("SUPABASE_ANON_KEY", "")
        XCTAssertNil(NetworkService.BaseEndpoint.supabase.apiKeyIfPresent, "an empty value is no key")
    }
}
