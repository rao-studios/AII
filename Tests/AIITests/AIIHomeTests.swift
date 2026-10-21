//
//  AIIHomeTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import XCTest
@testable import AII

final class AIIHomeTests: XCTestCase {

    func testTheLayoutIsTheContract() {
        let home = AIIHome(root: URL(fileURLWithPath: "/tmp/r"))
        XCTAssertEqual(PrivateFile.path(home.secretFile(for: .craft)), "/tmp/r/secrets/craft")
        XCTAssertEqual(PrivateFile.path(home.secretFile(for: .stack)), "/tmp/r/secrets/aii")
        XCTAssertEqual(PrivateFile.path(home.providersFile), "/tmp/r/keys/providers.json")
        XCTAssertEqual(PrivateFile.path(home.deviceKeyFile), "/tmp/r/keys/device.key")
        XCTAssertEqual(PrivateFile.path(home.keptDeviceKeyFile(fingerprint: "abcd1234")), "/tmp/r/keys/device-abcd1234.key")
        XCTAssertEqual(PrivateFile.path(home.serverBinary), "/tmp/r/aii/bin/AIIServer")
        XCTAssertEqual(PrivateFile.path(home.metallib), "/tmp/r/aii/bin/mlx.metallib")
        XCTAssertEqual(PrivateFile.path(home.aiiInstallRecord), "/tmp/r/aii/install.json")
        XCTAssertEqual(PrivateFile.path(home.aiiEnvFile), "/tmp/r/aii/aii.env")
        XCTAssertEqual(PrivateFile.path(home.aiiConfigFile), "/tmp/r/aii/config.json")
        XCTAssertEqual(PrivateFile.path(home.lanesFile), "/tmp/r/aii/lanes.json")
        XCTAssertEqual(PrivateFile.path(home.sewnDataDirectory), "/tmp/r/aii/sewn/db")
        XCTAssertEqual(PrivateFile.path(home.threadDataDirectory), "/tmp/r/aii/thread/db")
        XCTAssertEqual(PrivateFile.path(home.sewnRunRecord), "/tmp/r/aii/run/sewn.json")
        XCTAssertEqual(PrivateFile.path(home.threadRunRecord), "/tmp/r/aii/run/thread.json")
        XCTAssertEqual(PrivateFile.path(home.startLockFile), "/tmp/r/aii/run/start.lock")
        XCTAssertEqual(PrivateFile.path(home.aiiLease(for: .veil)), "/tmp/r/aii/leases/veil.json")
        XCTAssertEqual(PrivateFile.path(home.aiiPinnedLease(for: .veil)), "/tmp/r/aii/leases/veil.pinned.json")
        XCTAssertEqual(PrivateFile.path(home.appDirectory(.craft)), "/tmp/r/apps/craft")
        XCTAssertEqual(PrivateFile.path(home.huggingFaceHome), "/tmp/r/models/huggingface")
    }

    func testServersOnlyUseAHomeTheirLauncherNamed() throws {
        XCTAssertNil(try AIIHome.fromEnvironment([:]))
        XCTAssertNil(try AIIHome.fromEnvironment(["AII_HOME": "  "]))
        XCTAssertEqual(try AIIHome.fromEnvironment(["AII_HOME": "/x/y"]).map { PrivateFile.path($0.root) }, "/x/y")
        XCTAssertThrowsError(try AIIHome.fromEnvironment(["AII_HOME": "relative/path"]))
        let tilde = try AIIHome.fromEnvironment(["AII_HOME": "~/.rao-test"])
        XCTAssertTrue(PrivateFile.path(tilde!.root).hasPrefix(PrivateFile.path(AIIHome.userHomeDirectory)))
    }

    func testAppsAlwaysGetAHome() {
        XCTAssertEqual(PrivateFile.path(AIIHome.resolved([:]).root),
                       PrivateFile.path(AIIHome.userHomeDirectory.appendingPathComponent(".rao")))
        XCTAssertEqual(PrivateFile.path(AIIHome.resolved(["AII_HOME": "/elsewhere"]).root), "/elsewhere")
        XCTAssertEqual(PrivateFile.path(AIIHome.resolved(["AII_HOME": "not/absolute"]).root),
                       PrivateFile.path(AIIHome.userHomeDirectory.appendingPathComponent(".rao")))
    }

    func testProvisioningIsPrivateAndGivesEveryIdentityItsOwnSecret() throws {
        let test = TestHome()
        let secrets = try test.home.provision(by: .ambient)
        let everyone: [StackIdentity] = [.stack, .app(.ambient), .app(.craft), .app(.veil)]
        XCTAssertEqual(Set(secrets.keys), Set(everyone), "the apps every home starts with, and the stack itself")
        XCTAssertEqual(Set(secrets.values).count, everyone.count)
        XCTAssertTrue(secrets.values.allSatisfy(StackSecret.isWellFormedSecret))
        XCTAssertEqual(test.mode(test.home.root), 0o700)
        XCTAssertEqual(test.mode(test.home.secretsDirectory), 0o700)
        XCTAssertEqual(test.mode(test.home.aiiDirectory), 0o700)
        XCTAssertEqual(test.mode(test.home.threadDataDirectory), 0o700)
        for identity in everyone {
            XCTAssertEqual(test.mode(test.home.secretFile(for: identity)), 0o600, identity.rawValue)
        }
        XCTAssertEqual(test.home.layout()?.createdBy, .app(.ambient))
        XCTAssertEqual(test.home.registeredApps(), AIIApp.allCases, "each registered: secret, lane, record")
        XCTAssertEqual(try AIILanes.load(home: test.home)?.apps, AIIApp.allCases)
        XCTAssertEqual(test.home.layout()?.version, AIIContract.layoutVersion)
    }

    func testProvisioningAgainKeepsEverySecret() throws {
        let test = TestHome()
        let first = try test.home.provision(by: .ambient)
        let second = try test.home.provision(by: .craft)
        XCTAssertEqual(first, second)
        XCTAssertEqual(test.home.layout()?.createdBy, .app(.ambient), "the first app to arrive is recorded")
    }

    func testConcurrentProvisionersAgreeOnOneSecretPerIdentity() throws {
        let test = TestHome()
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            let app = AIIApp.allCases[index % AIIApp.allCases.count]
            if let secrets = try? test.home.provision(by: app) { results.append(secrets) }
        }
        XCTAssertEqual(results.all.count, 12)
        XCTAssertEqual(Set(results.all).count, 1, "every provisioner read the same secrets back")
    }

    func testALooseDirectoryIsTightenedAndALooseSecretRefused() throws {
        let test = TestHome()
        try FileManager.default.createDirectory(at: test.home.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try test.home.provision(by: .veil)
        XCTAssertEqual(test.mode(test.home.root), 0o700)

        chmod(PrivateFile.path(test.home.secretFile(for: .veil)), 0o644)
        XCTAssertThrowsError(try test.home.readSecret(for: .veil))
    }

    func testAMalformedSecretIsRefused() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        try PrivateFile.writeAtomically(Data("short".utf8), to: test.home.secretFile(for: .craft))
        XCTAssertThrowsError(try test.home.readSecret(for: .craft)) { error in
            XCTAssertEqual(error as? AIIHomeError, .malformedSecret(.app(.craft)))
        }
    }

    func testEnsureSecretTouchesOnlyItsIdentity() throws {
        let test = TestHome()
        let veil = try test.home.ensureSecret(for: .veil)
        XCTAssertEqual(try test.home.readSecret(for: .veil), veil)
        XCTAssertNil(try test.home.readSecret(for: .ambient))
        XCTAssertNil(try test.home.readSecret(for: .stack))
        let stack = try test.home.ensureSecret(for: .stack)
        XCTAssertEqual(try test.home.readSecret(for: .stack), stack)
        XCTAssertNotEqual(stack, veil)
    }

    func testStackIdentityNames() throws {
        XCTAssertEqual(StackIdentity(header: " AII\n"), .stack)
        XCTAssertEqual(StackIdentity(header: "craft"), .app(.craft))
        XCTAssertEqual(StackIdentity(header: "mary"), .app("mary"), "any app name")
        XCTAssertNil(StackIdentity(header: "Not An App"))
        XCTAssertNil(AIIApp(header: "aii"), "the stack is never an app")
        XCTAssertEqual(StackIdentity.stack.rawValue, "aii")
        let encoded = String(decoding: try JSONEncoder().encode([StackIdentity.app(.veil), .stack]), as: UTF8.self)
        XCTAssertEqual(encoded, #"["veil","aii"]"#, "encoded as the name it always was on the wire")
        XCTAssertEqual(try JSONDecoder().decode([StackIdentity].self, from: Data(encoded.utf8)), [.app(.veil), .stack])
    }
}

final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[StackIdentity: String]] = []
    func append(_ value: [StackIdentity: String]) { lock.withLock { values.append(value) } }
    var all: [[StackIdentity: String]] { lock.withLock { values } }
}
