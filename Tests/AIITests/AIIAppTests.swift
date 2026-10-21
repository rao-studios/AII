//
//  AIIAppTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Any app may be a lane: an app is a validated name, never the stack's own `aii`;
//  registering one writes its secret and its manifest entry, the first time only, and an
//  explicit owner updates the entry; lanes are added in place; a manifest in another format
//  is rebuilt; and the servers' registry finds a lane registered, or an owner changed,
//  after they started. An owner is aii-local, local-<app> or an account.
//

import Foundation
import XCTest
@testable import AII

final class AIIAppTests: XCTestCase {

    func testTheNameGrammar() {
        for name in ["notes", "myapp2", "ab", "a" + String(repeating: "b", count: 31), "ambient"] {
            XCTAssertNotNil(AIIApp(rawValue: name), name)
        }
        for name in ["aii", "Notes", "n", "-x", "2go", "a_b", "my-app", "notes-memory", "has space",
                     "a" + String(repeating: "b", count: 32), "", "éapp"] {
            XCTAssertNil(AIIApp(rawValue: name), name)
        }
        XCTAssertEqual(AIIApp(header: "  Notes\n"), "notes")
        XCTAssertNil(AIIApp(header: "AII"))
        XCTAssertEqual(AIIApp.ambient.rawValue, "ambient")
        XCTAssertEqual(AIIApp.allCases, [.ambient, .craft, .veil], "the apps every home starts with")
    }

    func testANamedAppSaysWhatIsWrong() throws {
        XCTAssertEqual(try AIIApp.named("notes"), "notes")
        XCTAssertThrowsError(try AIIApp.named("aii")) { XCTAssertEqual($0 as? AIIHomeError, .reservedName("aii")) }
        XCTAssertThrowsError(try AIIApp.named("Notes")) { XCTAssertEqual($0 as? AIIHomeError, .invalidAppName("Notes")) }
    }

    func testItCodesAsItsName() throws {
        let encoded = String(decoding: try JSONEncoder().encode(["apps": [AIIApp("notes"), .craft]]), as: UTF8.self)
        XCTAssertEqual(encoded, #"{"apps":["notes","craft"]}"#)
        XCTAssertEqual(try JSONDecoder().decode([AIIApp].self, from: Data(#"["notes"]"#.utf8)), ["notes"])
        XCTAssertThrowsError(try JSONDecoder().decode([AIIApp].self, from: Data(#"["aii"]"#.utf8)), "never the stack")
    }

    func testDisplayNames() throws {
        XCTAssertEqual(AIIApp("notes").displayName, "Notes")
        XCTAssertEqual(AIIApp.ambient.displayName, "Ambient")
        let test = TestHome()
        try test.home.register("mynotes", displayName: "My Notes")
        XCTAssertEqual(AIIApp("mynotes").displayName(in: test.home), "My Notes")
        XCTAssertEqual(AIIApp("other").displayName(in: test.home), "Other", "unregistered: the name, capitalized")
        XCTAssertEqual(StackIdentity.stack.displayName(in: test.home), "Ambient Intelligence Index")
    }
}

final class AIIRegistrationTests: XCTestCase {

    func testRegisteringWritesTheSecretAndTheManifestEntry() throws {
        let test = TestHome()
        let lane = try test.home.register("notes", displayName: "Notes", bundleIdentifier: "com.example.notes")
        XCTAssertEqual(lane.registeredBy, .app("notes"))
        XCTAssertEqual(lane.bundleIdentifier, "com.example.notes")
        XCTAssertEqual(lane.owner, .app("notes"), "an app's own owner unless it opts in")
        XCTAssertEqual(test.mode(test.home.secretFile(for: AIIApp("notes"))), 0o600)
        XCTAssertNotNil(try test.home.readSecret(for: AIIApp("notes")))
        XCTAssertEqual(test.mode(test.home.lanesFile), 0o600)
        let key = try XCTUnwrap(try AIIDeviceKey.load(home: test.home))
        XCTAssertEqual(lane.id, AIILanes.derive(app: "notes", from: key))
        XCTAssertEqual(lane.derivedFrom, key.fingerprint)
        XCTAssertEqual(test.home.lane("notes"), lane, "the manifest is the registration")
        XCTAssertEqual(test.home.registeredApps(), ["notes"])
        XCTAssertFalse(PrivateFile.exists(test.home.appDirectory("notes").appendingPathComponent("app.json")), "no app.json")
    }

    func testTheFirstRegistrationWinsAndAnExplicitOwnerUpdatesIt() throws {
        let test = TestHome()
        let first = try test.home.register("notes", displayName: "Notes", by: .stack)
        let secret = try test.home.readSecret(for: AIIApp("notes"))
        let second = try test.home.register("notes", displayName: "Another Notes")
        XCTAssertEqual(second.displayName, "Notes")
        XCTAssertEqual(second.registeredBy, .stack, "registered from the terminal first")
        XCTAssertEqual(second.registeredAt.timeIntervalSince1970, first.registeredAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(second.owner, .app("notes"), "no owner given: the entry's stays")
        XCTAssertEqual(try test.home.readSecret(for: AIIApp("notes")), secret)
        XCTAssertEqual(second.id, first.id)

        let shared = try test.home.register("notes", owner: .local)
        XCTAssertEqual(shared.owner, .local)
        XCTAssertEqual(shared.displayName, "Notes")
        XCTAssertEqual(test.home.lane("notes")?.owner, .local)
        try test.home.setOwner(.app("notes"), for: "notes")
        XCTAssertEqual(test.home.lane("notes")?.owner, .app("notes"))
    }

    func testALaneIsOwnedByAIILocalOrTheAppItself() throws {
        let test = TestHome()
        XCTAssertThrowsError(try test.home.register("notes", owner: .app(.craft))) {
            XCTAssertEqual($0 as? AIIHomeError, .invalidOwner("local-craft", app: "notes"))
        }
        XCTAssertThrowsError(try test.home.register("notes", owner: .account("person-1")))
        XCTAssertThrowsError(try test.home.setOwner(.local, for: "notes"), "not registered yet")
        try test.home.register("notes")
        XCTAssertThrowsError(try test.home.setOwner(.app(.veil), for: "notes"))
        XCTAssertEqual(test.home.lane("notes")?.owner, .app("notes"))
    }

    func testRegisteredAppsAreTheSecretsAndTheLanesButNeverTheStack() throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: AIIApp("fromasecret"))
        _ = try test.home.ensureSecret(for: .stack)
        try AIILanes.ensure(home: test.home, apps: ["fromalane"])
        try PrivateFile.writeAtomically(Data(StackSecret.generate().utf8), to: test.home.secretsDirectory.appendingPathComponent("Not An App"))
        XCTAssertEqual(test.home.registeredApps(), ["fromalane", "fromasecret"])
    }

    func testAManifestInAnotherFormatIsRebuiltWithTheSameIds() throws {
        let test = TestHome()
        let lane = try test.home.register("notes", displayName: "My Notes", owner: .local)
        try PrivateFile.writeAtomically(Data(#"{"lanes":{"notes":{"id":"x","derivedFrom":"y","createdAt":"2025-01-01T00:00:00Z"}}}"#.utf8),
                                        to: test.home.lanesFile, mode: 0o600)
        XCTAssertNil(try AIILanes.load(home: test.home), "another format reads as absent")
        XCTAssertEqual(test.home.registeredApps(), ["notes"], "the secret still names the app")
        let rebuilt = try test.home.register("notes")
        XCTAssertEqual(rebuilt.id, lane.id, "derived again from the same device key")
        XCTAssertEqual(rebuilt.displayName, "Notes", "start fresh: what only the old file knew is gone")
        XCTAssertEqual(rebuilt.owner, .app("notes"))
    }

    func testUnregisteringRemovesOnlyThatApp() throws {
        let test = TestHome()
        try test.home.provision(by: "notes")
        try PrivateFile.writeAtomically(Data("private".utf8), to: test.home.appDirectory("notes").appendingPathComponent("data"))
        try test.home.unregister("notes")
        XCTAssertNil(try test.home.readSecret(for: AIIApp("notes")))
        XCTAssertNil(test.home.lane("notes"))
        XCTAssertTrue(PrivateFile.exists(test.home.appDirectory("notes").appendingPathComponent("data")), "its own files stay")
        XCTAssertEqual(test.home.registeredApps(), AIIApp.allCases, "the others are untouched")
        XCTAssertNoThrow(try test.home.unregister("notes"), "nothing left to remove is not an error")
    }

    func testAnAppProvisioningAHomeRegistersItselfBesideTheRaoApps() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: "notes", displayName: "Notes")
        XCTAssertEqual(Set(secrets.keys), [.stack, .app(.ambient), .app(.craft), .app(.veil), .app("notes")])
        XCTAssertEqual(test.home.registeredApps(), [.ambient, .craft, "notes", .veil])
        XCTAssertEqual(test.home.layout()?.createdBy, .app("notes"))
        XCTAssertEqual(test.home.lane(.craft)?.registeredBy, .app("notes"), "provisioned for Craft by Notes")
        XCTAssertEqual(test.home.lane(.craft)?.owner, .local, "the Rao apps file under aii-local")
        XCTAssertEqual(test.home.lane("notes")?.owner, .app("notes"))
        XCTAssertEqual(test.home.lane("notes")?.displayName, "Notes")
    }

    func testTheStackProvisionsWithoutAnAppOfItsOwn() throws {
        let test = TestHome()
        let secrets = try test.home.provision()
        XCTAssertEqual(Set(secrets.keys), [.stack, .app(.ambient), .app(.craft), .app(.veil)])
        XCTAssertEqual(test.home.layout()?.createdBy, .stack)
    }

    func testConcurrentRegistrationsAgree() throws {
        let test = TestHome()
        let names: [AIIApp] = ["one", "two", "three", "four"]
        let records = LockedRecords()
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            if let record = try? test.home.register(names[index % names.count]) { records.append(record) }
        }
        XCTAssertEqual(records.all.count, 12)
        XCTAssertEqual(test.home.registeredApps(), names.sorted())
        let lanes = try XCTUnwrap(try AIILanes.load(home: test.home))
        XCTAssertEqual(Set(lanes.apps), Set(names), "no registration lost to a race")
        XCTAssertEqual(test.mode(test.home.lanesFile), 0o600)
    }
}

final class AIILanesTests: XCTestCase {

    func testEnsureAddsMissingAppsInPlaceAndNeverChangesAnId() throws {
        let test = TestHome()
        try AIILanes.ensure(home: test.home, apps: [.ambient, .craft])
        let first = try XCTUnwrap(try AIILanes.load(home: test.home))
        let ambient = try XCTUnwrap(first.id(for: .ambient))
        let craftRegistered = try XCTUnwrap(first.lane(for: .craft)?.registeredAt)

        let second = try AIILanes.ensure(home: test.home, apps: ["notes"])
        XCTAssertEqual(second.apps, [.ambient, .craft, "notes"])
        XCTAssertEqual(second.id(for: .ambient), ambient)
        XCTAssertEqual(second.lane(for: .craft)?.registeredAt, craftRegistered)
        let key = try XCTUnwrap(try AIIDeviceKey.load(home: test.home))
        XCTAssertEqual(second.id(for: "notes"), AIILanes.derive(app: "notes", from: key))
        XCTAssertNotEqual(second.id(for: "notes"), ambient)
        XCTAssertEqual(test.mode(test.home.lanesFile), 0o600)
    }

    func testEnsureWithNoAppsRegistersEveryAppWithASecret() throws {
        let test = TestHome()
        _ = try test.home.ensureSecret(for: AIIApp("notes"))
        _ = try test.home.ensureSecret(for: .stack)
        XCTAssertEqual(try AIILanes.ensure(home: test.home).apps, ["notes"])
    }

    func testRemoveTakesOneAppOut() throws {
        let test = TestHome()
        try AIILanes.ensure(home: test.home, apps: [.ambient, "notes"])
        try AIILanes.remove(home: test.home, app: "notes")
        XCTAssertEqual(try AIILanes.load(home: test.home)?.apps, [.ambient])
    }

    func testTheOwnerANewLaneStartsWith() throws {
        XCTAssertEqual(AIILanes.defaultOwner(for: .ambient), .local)
        XCTAssertEqual(AIILanes.defaultOwner(for: .veil), .local)
        XCTAssertEqual(AIILanes.defaultOwner(for: "notes"), .app("notes"))
        let lanes = AIILanes(lanes: [:])
        XCTAssertEqual(lanes.owner(for: "notes"), .app("notes"), "no entry: the default")
    }
}

final class AIIOwnerTests: XCTestCase {

    func testTheThreeOwners() throws {
        XCTAssertEqual(AIIOwner.local.rawValue, "aii-local")
        XCTAssertEqual(AIIOwner.app("notes").rawValue, "local-notes")
        XCTAssertEqual(AIIOwner.account("Person-1").rawValue, "person-1", "lowercased, as Sewn does")
        XCTAssertTrue(AIIOwner.local.isLocal)
        XCTAssertTrue(AIIOwner.app("notes").isLocal)
        XCTAssertFalse(AIIOwner.account("person-1").isLocal, "claimed by an account")
        XCTAssertTrue(AIIOwner.local.isLaneOwner(for: "notes"))
        XCTAssertTrue(AIIOwner.app("notes").isLaneOwner(for: "notes"))
        XCTAssertFalse(AIIOwner.app(.craft).isLaneOwner(for: "notes"))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(["owner": AIIOwner.local]), as: UTF8.self), #"{"owner":"aii-local"}"#)
        XCTAssertEqual(try JSONDecoder().decode(AIIOwner.self, from: Data(#""local-notes""#.utf8)), .app("notes"))
    }
}

final class AIILaneRegistryTests: XCTestCase {

    func testAMissRegistersTheLaneInPlace() throws {
        let test = TestHome()
        try AIILanes.ensure(home: test.home, apps: [.ambient])
        let registry = AIILaneRegistry(home: test.home)
        let notes = try registry.id(for: "notes")
        XCTAssertEqual(try AIILanes.load(home: test.home)?.id(for: "notes"), notes, "written to lanes.json")
        XCTAssertEqual(registry.app(for: notes), "notes")
        XCTAssertEqual(try registry.id(for: "notes"), notes, "the same lane every time")
    }

    func testAReloadSeesALaneAnotherProcessAdded() throws {
        let test = TestHome()
        try AIILanes.ensure(home: test.home, apps: [.ambient])
        let clock = Clock(Date())
        let registry = AIILaneRegistry(home: test.home, minimumReloadInterval: 2, now: { clock.now })
        let notes = try AIILanes.ensure(home: test.home, app: "notes")
        XCTAssertNil(registry.app(for: notes), "within the throttle: no reload")
        clock.advance(3)
        XCTAssertEqual(registry.app(for: notes), "notes")
        XCTAssertTrue(registry.contains(notes))
        XCTAssertEqual(registry.displayName(for: "notes"), "Notes")
    }

    func testAnOwnerChangeReachesARunningRegistry() throws {
        let test = TestHome()
        try test.home.register("notes")
        let clock = Clock(Date())
        let registry = AIILaneRegistry(home: test.home, minimumReloadInterval: 2, now: { clock.now })
        XCTAssertEqual(registry.owner(for: "notes"), .app("notes"))
        try test.home.setOwner(.local, for: "notes")
        XCTAssertEqual(registry.owner(for: "notes"), .app("notes"), "within the throttle: no reload")
        clock.advance(3)
        XCTAssertEqual(registry.owner(for: "notes"), .local, "the manifest changed: read again")
        XCTAssertEqual(registry.owner(for: "unlisted"), .app("unlisted"), "no entry: the default")
    }

    func testAFixedRegistryNeverRegisters() {
        let registry = AIILaneRegistry(fixed: AIILanes(lanes: [:]))
        XCTAssertThrowsError(try registry.id(for: "notes")) { error in
            XCTAssertEqual(error as? AIILaneRegistryError, .unregistered("notes"))
        }
    }
}

final class AIIResetTests: XCTestCase {
    func testAResetRemovesTheInstallAndRunStateOnly() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        try PrivateFile.writeAtomically(Data("x".utf8), to: test.home.serverBinary)
        try PrivateFile.writeAtomically(Data("{}".utf8), to: test.home.aiiInstallRecord)
        try PrivateFile.ensureDirectory(test.home.aiiRunDirectory)
        try PrivateFile.ensureDirectory(test.home.cliDirectory)
        let plan = AIIReset.plan(home: test.home)
        XCTAssertEqual(Set(plan.map(PrivateFile.path)), Set([test.home.aiiBinDirectory, test.home.aiiInstallRecord,
                                                               test.home.aiiRunDirectory, test.home.aiiLeasesDirectory,
                                                               test.home.layoutFile].map(PrivateFile.path)))
        try AIIReset.apply(plan)
        XCTAssertTrue(AIIReset.plan(home: test.home).isEmpty)
        for kept in [test.home.secretsDirectory, test.home.deviceKeyFile, test.home.lanesFile, test.home.threadDataDirectory,
                     test.home.sewnDataDirectory, test.home.cliDirectory, test.home.appDirectory(.ambient)] {
            XCTAssertTrue(PrivateFile.exists(kept), PrivateFile.path(kept))
        }
    }
}

final class LockedRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AIILanes.Lane] = []
    func append(_ value: AIILanes.Lane) { lock.withLock { values.append(value) } }
    var all: [AIILanes.Lane] { lock.withLock { values } }
}
