//
//  AIISupervisorTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The one supervisor every app runs, against a stand-in AIIServer that proves the caller's
//  secret from AII_HOME the way the real one does in either role: both roles come up,
//  status says so, a hold is taken, and the last app out stops both.
//

import Foundation
import XCTest
@testable import AII

final class AIIStatusTests: XCTestCase {
    private func detail(_ role: LaunchSpec.Role, _ state: AIIStatus.ServerDetail.State, detail: String? = nil) -> AIIStatus.ServerDetail {
        AIIStatus.ServerDetail(role: role, state: state, ports: AIIPorts(http: 1, grpc: 2), detail: detail,
                               logFile: URL(fileURLWithPath: "/tmp/\(role.rawValue).log"))
    }

    func testTwoServersMakeOnePhase() {
        typealias S = AIIStatus.ServerDetail.State
        func phase(_ sewn: S, _ thread: S, installed: Bool = true, installing: String? = nil) -> AIIStatus.Phase {
            AIIStatus.phase(sewn: detail(.sewn, sewn), thread: detail(.thread, thread), installed: installed, installing: installing)
        }
        XCTAssertEqual(phase(.up, .up), .up)
        XCTAssertEqual(phase(.stopped, .stopped), .down(nil))
        XCTAssertEqual(phase(.stopped, .stopped, installed: false), .notInstalled(nil))
        XCTAssertEqual(phase(.up, .up, installing: "building"), .installing(step: "building"))
        XCTAssertEqual(phase(.starting, .stopped), .starting)
        XCTAssertEqual(phase(.up, .starting), .starting)
        XCTAssertEqual(phase(.up, .stopped), .degraded("Thread is stopped"))
        XCTAssertEqual(phase(.stopped, .up), .degraded("Sewn is stopped"))
        XCTAssertEqual(phase(.up, .unhealthy("health check failing")), .degraded("Thread: health check failing"))
        XCTAssertEqual(phase(.unhealthy("x"), .stopped), .down("Sewn: x"))
        XCTAssertFalse(phase(.up, .starting).isUp)
    }
}

final class AIISupervisorTests: XCTestCase {

    private func makeSupervisor(_ test: LauncherTestHome, app: AIIApp, hold: AIISupervisor.Hold = .lease) throws -> AIISupervisor {
        try makeSupervisor(test, identity: .app(app), hold: hold)
    }

    private func makeSupervisor(_ test: LauncherTestHome, identity: StackIdentity, hold: AIISupervisor.Hold = .lease) throws -> AIISupervisor {
        let script = try test.file("stand-in-\(identity.rawValue)", contents: standInServer)
        return AIISupervisor(
            identity: identity, home: test.home, policy: .unchecked, hold: hold,
            executables: .init(server: script, workingDirectory: test.home.aiiDirectory),
            threadOptions: ThreadLaunchOptions(useMLX: false, mlxModel: nil, mothership: false),
            environment: ["PATH": "/usr/bin:/bin"],
            pollInterval: .milliseconds(250))
    }

    func testBothServersComeUpAndTheLastAppOutStopsThem() async throws {
        let test = LauncherTestHome()
        // Scratch ports, never the plan's: a real stack may be running on this Mac.
        try AIIConfig(sewn: .init(httpPort: freeLoopbackPort(), grpcPort: freeLoopbackPort()),
                      thread: .init(httpPort: freeLoopbackPort(), grpcPort: freeLoopbackPort())).write(home: test.home)
        let craft = try makeSupervisor(test, app: .craft)
        let secret = try await craft.prepare()
        XCTAssertTrue(StackSecret.isWellFormedSecret(secret))
        XCTAssertNotNil(try AIIDeviceKey.load(home: test.home), "prepare makes the device key")
        XCTAssertNotNil(try AIILanes.load(home: test.home), "and registers the lanes")

        try await craft.ensureRunning(timeout: 30)
        let up = await craft.snapshot()
        XCTAssertEqual(up.phase, .up)
        XCTAssertTrue(up.sewn.verified)
        XCTAssertTrue(up.thread.verified)
        XCTAssertFalse(up.sewn.adopted)
        XCTAssertEqual(up.sewn.launchedBy, .app(.craft))
        XCTAssertTrue(up.holdsLease)
        XCTAssertEqual(AIILeases(home: test.home).liveHolders(), [.app(.craft)])
        let sewnPID = try XCTUnwrap(up.sewn.pid)
        let threadPID = try XCTUnwrap(up.thread.pid)

        // Veil arrives: adopts both, holds its own lease, sees Craft holding it too.
        let veil = try makeSupervisor(test, app: .veil)
        _ = try await veil.prepare()
        try await veil.ensureRunning(timeout: 30)
        let shared = await veil.snapshot()
        XCTAssertEqual(shared.phase, .up)
        XCTAssertTrue(shared.sewn.adopted)
        XCTAssertEqual(shared.sewn.pid, sewnPID)
        XCTAssertEqual(shared.thread.pid, threadPID)
        XCTAssertEqual(shared.sharedWith, [.app(.craft)])

        // Craft quits: its lease goes, nothing stops, Veil still has the stack.
        await craft.stop()
        XCTAssertTrue(ProcessProbe.isAlive(sewnPID))
        XCTAssertTrue(ProcessProbe.isAlive(threadPID))
        XCTAssertEqual(AIILeases(home: test.home).liveHolders(), [.app(.veil)])

        // Veil quits: the last hold is gone, so both stop — Thread first, then Sewn.
        await veil.stop()
        let gone = await waitUntil { !ProcessProbe.isAlive(sewnPID) && !ProcessProbe.isAlive(threadPID) }
        XCTAssertTrue(gone)
        XCTAssertNil(RunRecord.load(test.home.sewnRunRecord))
        XCTAssertNil(RunRecord.load(test.home.threadRunRecord))
        let down = await veil.snapshot()
        XCTAssertEqual(down.phase, .down(nil))
        XCTAssertFalse(down.holdsLease)
    }

    func testAOneShotCLIHoldsNoLeaseAndStopsNothing() async throws {
        let test = LauncherTestHome()
        try AIIConfig(sewn: .init(httpPort: freeLoopbackPort(), grpcPort: freeLoopbackPort()),
                      thread: .init(httpPort: freeLoopbackPort(), grpcPort: freeLoopbackPort())).write(home: test.home)
        let cli = try makeSupervisor(test, app: .craft, hold: .none)
        _ = try await cli.prepare()
        try await cli.ensureRunning(timeout: 30)
        let up = await cli.snapshot()
        XCTAssertEqual(up.phase, .up)
        XCTAssertFalse(up.holdsLease)
        XCTAssertTrue(AIILeases(home: test.home).live().isEmpty)
        let pids = [up.sewn.pid, up.thread.pid].compactMap { $0 }
        cli.shutdownSync()
        XCTAssertTrue(pids.allSatisfy(ProcessProbe.isAlive), "the servers outlive a CLI run")
        // Clean up: an app that holds a lease and is the last one out.
        let app = try makeSupervisor(test, app: .ambient)
        _ = try await app.prepare()
        try await app.ensureRunning(timeout: 30)
        await app.stop()
        let gone = await waitUntil { pids.allSatisfy { !ProcessProbe.isAlive($0) } }
        XCTAssertTrue(gone)
    }

    func testTheInstalledServerIsRequiredWhenNoCheckoutIsNamed() async throws {
        let test = LauncherTestHome()
        let supervisor = AIISupervisor(app: .ambient, home: test.home, policy: .unchecked, environment: ["PATH": "/usr/bin:/bin"])
        let before = await supervisor.snapshot()
        XCTAssertEqual(before.phase, .notInstalled(nil))
        do {
            try await supervisor.ensureRunning(timeout: 5)
            XCTFail("nothing is installed")
        } catch let error as AIIInstallError {
            XCTAssertEqual(error, .notInstalled)
        }
        let after = await supervisor.snapshot()
        XCTAssertEqual(after.sewn.state, .stopped)
        XCTAssertTrue(after.sewn.detail?.contains("not installed") ?? false)
    }

    private func scratchPorts(_ test: LauncherTestHome) throws {
        // Scratch ports, never the plan's: a real stack may be running on this Mac.
        try AIIConfig(sewn: .init(httpPort: freeLoopbackPort(), grpcPort: freeLoopbackPort()),
                      thread: .init(httpPort: freeLoopbackPort(), grpcPort: freeLoopbackPort())).write(home: test.home)
    }

    /// The aii command starts the stack as `aii` and pins it; an app shares it; the
    /// command's stop takes it down once the app has left.
    func testTheStackIdentityHoldsAPinnedLeaseAndAnAppSharesIt() async throws {
        let test = LauncherTestHome()
        try scratchPorts(test)
        let cli = try makeSupervisor(test, identity: .stack, hold: .pinned)
        let secret = try await cli.prepare()
        XCTAssertEqual(secret, try test.home.readSecret(for: .stack))
        try await cli.ensureRunning(timeout: 30)
        let up = await cli.snapshot()
        XCTAssertEqual(up.phase, .up)
        XCTAssertEqual(up.sewn.launchedBy, .stack)
        XCTAssertTrue(PrivateFile.exists(test.home.aiiPinnedLease(for: .stack)))
        let pids = [up.sewn.pid, up.thread.pid].compactMap { $0 }

        let craft = try makeSupervisor(test, app: .craft)
        _ = try await craft.prepare()
        try await craft.ensureRunning(timeout: 30)
        let shared = await craft.snapshot()
        XCTAssertTrue(shared.sewn.adopted)
        XCTAssertEqual(shared.sharedWith, [.stack])
        await craft.stop()
        XCTAssertTrue(pids.allSatisfy(ProcessProbe.isAlive), "the command's pinned lease keeps them up")

        await cli.stop()
        let gone = await waitUntil { pids.allSatisfy { !ProcessProbe.isAlive($0) } }
        XCTAssertTrue(gone)
    }

    /// Looking holds nothing: `inspect` reads the run records and the ports.
    func testInspectReadsWhatRunsWithoutHoldingIt() async throws {
        let test = LauncherTestHome()
        try scratchPorts(test)
        let craft = try makeSupervisor(test, app: .craft)
        _ = try await craft.prepare()
        try await craft.ensureRunning(timeout: 30)
        let started = await craft.snapshot()

        let look = try makeSupervisor(test, identity: .stack, hold: .none)
        let seen = await look.inspect()
        XCTAssertEqual(seen.phase, .up)
        XCTAssertTrue(seen.sewn.verified)
        XCTAssertEqual(seen.sewn.pid, started.sewn.pid)
        XCTAssertEqual(seen.thread.pid, started.thread.pid)
        XCTAssertEqual(seen.thread.launchedBy, .app(.craft))
        XCTAssertFalse(seen.holdsLease)
        XCTAssertEqual(AIILeases(home: test.home).liveHolders(), [.app(.craft)], "no lease taken by looking")

        await craft.stop()
        let stopped = await look.inspect()
        XCTAssertEqual(stopped.phase, .down(nil))
    }

    /// The aii command can stop what an app still holds, when told to.
    func testAForcedStopStopsWhatOthersHold() async throws {
        let test = LauncherTestHome()
        try scratchPorts(test)
        let craft = try makeSupervisor(test, app: .craft)
        _ = try await craft.prepare()
        try await craft.ensureRunning(timeout: 30)
        let up = await craft.snapshot()
        let pids = [up.sewn.pid, up.thread.pid].compactMap { $0 }

        let cli = try makeSupervisor(test, identity: .stack, hold: .none)
        await cli.stop()
        XCTAssertTrue(pids.allSatisfy(ProcessProbe.isAlive), "Craft holds it: an unforced stop leaves it")
        await cli.stop(force: true)
        let gone = await waitUntil { pids.allSatisfy { !ProcessProbe.isAlive($0) } }
        XCTAssertTrue(gone)
        await craft.stop()
    }

    /// An app never replaces the person's build; on an older contract it says so.
    func testAnAppSeesThePersonsBuildBehindItsContractAsNotInstalled() async throws {
        let test = LauncherTestHome()
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\n")
        let installer = AIIInstaller(home: test.home, policy: .unchecked)
        try installer.installLocal(from: test.base)
        var record = try XCTUnwrap(installer.installedRecord())
        record.contract = AIIContract.version - 1
        try record.write(home: test.home)

        let ambient = AIISupervisor(app: .ambient, home: test.home, policy: .unchecked, environment: ["PATH": "/usr/bin:/bin"])
        let message = AIIInstallError.localBuildBehind(installed: AIIContract.version - 1, needed: AIIContract.version,
                                                       app: "Ambient").description
        let before = await ambient.snapshot()
        XCTAssertEqual(before.phase, .notInstalled(message))
        XCTAssertEqual(before.installProblem, message)
        XCTAssertEqual(before.installSummary, record.summary)
        do {
            try await ambient.ensureRunning(timeout: 5)
            XCTFail("the person's build is behind")
        } catch let error as AIIInstallError {
            guard case .localBuildBehind = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(installer.installedRecord()?.source, .local, "nothing was replaced")
        await ambient.stop()
    }

    /// Joining registers the app's lane, adopts or starts the servers, and returns once
    /// both have proved the app's secret.
    func testJoiningRegistersTheLaneAndWaitsForProof() async throws {
        let test = LauncherTestHome()
        try scratchPorts(test)
        let supervisor = try makeSupervisor(test, identity: .app("notes"))
        let aii = AIIInstance(app: "notes", displayName: "My Notes", bundleIdentifier: "com.example.notes", home: test.home,
                              bundle: nil, appVersion: nil, supervisor: supervisor, wire: FakeThreadWire(),
                              session: AIIAnswer.makeSession(), joined: false)
        try await aii.join(timeout: 30)
        XCTAssertEqual(test.home.lane("notes")?.displayName, "My Notes")
        XCTAssertEqual(test.home.lane("notes")?.bundleIdentifier, "com.example.notes")
        XCTAssertEqual(test.home.lane("notes")?.owner, .app("notes"), "no owner asked for: the app's own")
        let status = await supervisor.snapshot()
        XCTAssertTrue(status.sewn.verified && status.thread.verified)
        XCTAssertEqual(status.sewn.launchedBy, .app("notes"))
        _ = try await aii.recall("anything")   // joined: no longer refused
        await aii.leave()
        let pids = [status.sewn.pid, status.thread.pid].compactMap { $0 }
        let gone = await waitUntil { pids.allSatisfy { !ProcessProbe.isAlive($0) } }
        XCTAssertTrue(gone, "the last app out stops them")
    }
}

