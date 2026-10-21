//
//  ProviderKeyStoreTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import XCTest
@testable import AII

final class ProviderKeyStoreTests: XCTestCase {

    func testTheEnvironmentAnswersWithoutAFile() {
        let store = ProviderKeyStore(home: nil, environment: { ["MISTRAL_API_KEY": "from-env"] })
        XCTAssertFalse(store.isFileBacked)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env")
        XCTAssertNil(store.value(for: "TINKER_API_KEY"))
    }

    func testTheFileBeatsTheEnvironmentAndAChangeIsSeenWithoutANewStore() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let store = ProviderKeyStore(home: test.home, environment: { ["MISTRAL_API_KEY": "from-env"] })
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env")

        let writer = ProviderKeyStore(home: test.home)
        try writer.write("MISTRAL_API_KEY", value: "typed-1", source: .typed, writtenBy: .ambient)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "typed-1")
        try writer.write("MISTRAL_API_KEY", value: "typed-2", source: .typed, writtenBy: .ambient)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "typed-2")
        XCTAssertEqual(store.record(for: "MISTRAL_API_KEY")?.writtenBy, .app(.ambient))

        try writer.remove("MISTRAL_API_KEY")
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env", "removed: back to the environment")
    }

    func testACheckoutsKeysAreAdoptedAndAnAccountsKept() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let store = ProviderKeyStore(home: test.home)
        XCTAssertEqual(try store.adopt(["MISTRAL_API_KEY": "m1", "TINKER_API_KEY": "", "SUPABASE_URL": "u"]), ["MISTRAL_API_KEY": .set])
        let record = try XCTUnwrap(store.record(for: "MISTRAL_API_KEY"))
        XCTAssertEqual(record.source, .typed)
        XCTAssertEqual(record.writtenBy, .stack)
        XCTAssertNil(store.record(for: "TINKER_API_KEY"), "an empty value is nothing")
        XCTAssertNil(store.record(for: "SUPABASE_URL"), "not a provider key")

        XCTAssertEqual(try store.adopt(["MISTRAL_API_KEY": "m1"]), ["MISTRAL_API_KEY": .alreadySet])
        XCTAssertEqual(store.record(for: "MISTRAL_API_KEY")?.updatedAt, record.updatedAt, "untouched")
        XCTAssertEqual(try store.adopt(["MISTRAL_API_KEY": "m2"]), ["MISTRAL_API_KEY": .set])
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "m2")

        try store.write("TINKER_API_KEY", value: "from-account", source: .account, writtenBy: .ambient)
        XCTAssertEqual(try store.adopt(["TINKER_API_KEY": "typed"]), ["TINKER_API_KEY": .keptAccount])
        XCTAssertEqual(store.value(for: "TINKER_API_KEY"), "from-account", "the account's key stays")
        XCTAssertEqual(test.mode(test.home.providersFile), 0o600)
    }

    func testAdoptingNothingWritesNoFile() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        XCTAssertEqual(try ProviderKeyStore(home: test.home).adopt(["TINKER_API_KEY": "", "OTHER": "x"]), [:])
        XCTAssertFalse(PrivateFile.exists(test.home.providersFile))
        XCTAssertEqual(try ProviderKeyStore(home: nil).adopt(["MISTRAL_API_KEY": "m"]), [:], "no file, nothing to adopt into")
    }

    func testTheStackIsAWriterAndAnAppsRecordStillReads() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let store = ProviderKeyStore(home: test.home)
        try store.write("MISTRAL_API_KEY", value: "m", source: .typed, writtenBy: .stack)
        try store.write("TINKER_API_KEY", value: "t", source: .typed, writtenBy: .ambient)
        let raw = String(decoding: try XCTUnwrap(FileManager.default.contents(atPath: PrivateFile.path(test.home.providersFile))), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"aii\""), "the stack writes as aii: \(raw)")
        XCTAssertTrue(raw.contains("\"ambient\""), "an app writes as its name, as it always did: \(raw)")
        let fresh = ProviderKeyStore(home: test.home).records()
        XCTAssertEqual(fresh["MISTRAL_API_KEY"]?.writtenBy, .stack)
        XCTAssertEqual(fresh["TINKER_API_KEY"]?.writtenBy, .app(.ambient))
    }

    func testAMalformedFileIsNamedByCheckedRecordsOnly() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let store = ProviderKeyStore(home: test.home)
        XCTAssertEqual(try store.checkedRecords(), [:], "no file: nothing")
        try PrivateFile.writeAtomically(Data("not json".utf8), to: test.home.providersFile)
        XCTAssertTrue(store.records().isEmpty, "a server never fails on it")
        XCTAssertThrowsError(try store.checkedRecords()) { error in
            guard case .malformed = error as? ProviderKeyStoreError else { return XCTFail("\(error)") }
        }
        try store.write("MISTRAL_API_KEY", value: "m", source: .typed, writtenBy: .stack)
        XCTAssertEqual(try store.checkedRecords().count, 1, "written again, it reads")
        chmod(PrivateFile.path(test.home.providersFile), 0o644)
        XCTAssertThrowsError(try store.checkedRecords()) { error in
            guard case .tooOpen = error as? PrivateFileError else { return XCTFail("\(error)") }
        }
    }

    func testAnEmptyValueFallsBackAndTheFileIsPrivate() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let store = ProviderKeyStore(home: test.home, environment: { ["MISTRAL_API_KEY": "from-env"] })
        try store.write("MISTRAL_API_KEY", value: "", source: .typed, writtenBy: .ambient)
        XCTAssertEqual(store.value(for: "MISTRAL_API_KEY"), "from-env")
        XCTAssertEqual(test.mode(test.home.providersFile), 0o600)
    }

    func testWritersOfDifferentKeysBothSurvive() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let store = ProviderKeyStore(home: test.home)
            try? store.write("KEY_\(index)", value: "v\(index)", source: .typed, writtenBy: .craft)
        }
        let records = ProviderKeyStore(home: test.home).records()
        XCTAssertEqual(records.count, 20)
    }

    func testAnUnreadableFileIsNoKeys() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        try PrivateFile.writeAtomically(Data("not json".utf8), to: test.home.providersFile)
        XCTAssertTrue(ProviderKeyStore(home: test.home).records().isEmpty)
    }
}
