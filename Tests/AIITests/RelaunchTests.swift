//
//  RelaunchTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A server started again the way its launcher started it, with no secret: the launch
//  record every spawn leaves, kept after a stop; a relaunch that never starts over a live
//  one; and finding, stopping and starting a home's server by the port it listens on.
//

import Darwin
import Foundation
import XCTest
@testable import AII

final class LaunchRecordTests: XCTestCase {

    func testItSitsBesideTheRunRecord() {
        let home = AIIHome(root: URL(fileURLWithPath: "/tmp/h"))
        XCTAssertEqual(home.threadLaunchRecord.lastPathComponent, "thread.launch.json")
        XCTAssertEqual(home.sewnLaunchRecord.lastPathComponent, "sewn.launch.json")
        XCTAssertEqual(home.threadLaunchRecord.deletingLastPathComponent(), home.aiiRunDirectory)
    }

    func testNothingCredentialLikeIsWrittenDown() {
        let environment = ["PATH": "/usr/bin", "AII_HOME": "/h", "HF_HOME": "/h/models/huggingface", "SEWN_REGION": "us",
                           "SEWN_TOKEN": "t", "SEWN_DEV_PASSWORD": "p", "MISTRAL_API_KEY": "k", "SUPABASE_ANON_KEY": "a",
                           "SOME_SECRET": "s"]
        XCTAssertEqual(LaunchRecord.recordable(environment),
                       ["PATH": "/usr/bin", "AII_HOME": "/h", "HF_HOME": "/h/models/huggingface", "SEWN_REGION": "us"])
    }

    func testTheLaunchAgainIsTheRecordedOneOverTheRelaunchersEnvironment() {
        let record = LaunchRecord(role: .thread, binary: "/bin/AIIServer", arguments: ["thread", "--port", "48001"],
                                  workingDirectory: "/h/aii", environment: ["AII_HOME": "/h", "PATH": "/recorded"],
                                  ports: AIIPorts(http: 48001, grpc: 48002), runRecord: "/h/aii/run/thread.json",
                                  logFile: "/h/aii/run/thread.log", launcher: .app(.craft), recordedAt: Date())
        let spec = record.spec(inherited: ["PATH": "/mine", "LANG": "en_US.UTF-8", "MISTRAL_API_KEY": "k", "AII_HOME": "/other"])
        XCTAssertEqual(spec.environment, ["AII_HOME": "/h", "PATH": "/recorded", "LANG": "en_US.UTF-8"],
                       "the record wins; the relauncher adds only what any launch inherits")
        XCTAssertEqual(spec.arguments, ["thread", "--port", "48001"])
        XCTAssertEqual(spec.ports, AIIPorts(http: 48001, grpc: 48002))
        XCTAssertNil(spec.challenge, "a relaunch proves nothing")
    }
}

final class RelaunchTests: XCTestCase {

    private func spec(_ test: LauncherTestHome, script: URL, port: Int) -> LaunchSpec {
        LaunchSpec(role: .thread, executable: script, arguments: ["thread", "--port", String(port)],
                   environment: ["PATH": "/usr/bin:/bin", "AII_HOME": PrivateFile.path(test.home.root), "SEWN_TOKEN": "t"],
                   workingDirectory: test.home.aiiDirectory, ports: AIIPorts(http: port, grpc: port),
                   runRecord: test.home.threadRunRecord, logFile: test.home.threadLogFile, challenge: .app(.craft))
    }

    private func resolved(_ home: AIIHome) -> String { PrivateFile.path(home.root.resolvingSymlinksInPath()) }

    func testASpawnLeavesItsLaunchAndAStopKeepsIt() async throws {
        let test = LauncherTestHome()
        let script = try test.file("stand-in-thread", contents: standInServer)
        let secret = try test.home.ensureSecret(for: .craft)
        let port = freeLoopbackPort()
        let server = ManagedServer(spec: spec(test, script: script, port: port), secret: secret, launcherApp: .craft)
        let started = try await server.ensureRunning(timeout: 20)

        let launch = try XCTUnwrap(LaunchRecord.load(test.home.threadLaunchRecord))
        XCTAssertEqual(launch.role, .thread)
        XCTAssertEqual(launch.arguments, ["thread", "--port", String(port)])
        XCTAssertEqual(launch.ports.http, port)
        XCTAssertEqual(launch.launcher, .app(.craft))
        XCTAssertNil(launch.environment["SEWN_TOKEN"], "a credential-like name is never written down")
        XCTAssertEqual(PrivateFile.ownerAndMode(test.home.threadLaunchRecord)?.mode, 0o600)

        await server.stop()
        _ = await waitUntil { !ProcessProbe.isAlive(started.pid) }
        XCTAssertNil(RunRecord.load(test.home.threadRunRecord))
        XCTAssertNotNil(LaunchRecord.load(test.home.threadLaunchRecord), "how to start it again outlives the stop")
    }

    func testARelaunchStartsItAgainAndNeverOverALiveOne() async throws {
        let test = LauncherTestHome()
        let script = try test.file("stand-in-thread", contents: standInServer)
        let secret = try test.home.ensureSecret(for: .craft)
        let port = freeLoopbackPort()
        let server = ManagedServer(spec: spec(test, script: script, port: port), secret: secret, launcherApp: .craft)
        let started = try await server.ensureRunning(timeout: 20)

        do {
            _ = try await ManagedServer.relaunch(launchRecord: test.home.threadLaunchRecord, launcher: .app(.veil))
            XCTFail("expected running")
        } catch let error as RelaunchError {
            XCTAssertEqual(error, .running(pid: started.pid))
        }

        await server.stop()
        _ = await waitUntil { !ProcessProbe.isAlive(started.pid) && ProcessProbe.listeningPIDs(port: port).isEmpty }

        let again = try await ManagedServer.relaunch(launchRecord: test.home.threadLaunchRecord, launcher: .app(.veil))
        defer { kill(again.pid, SIGKILL) }
        XCTAssertNotEqual(again.pid, started.pid)
        let record = try XCTUnwrap(RunRecord.load(test.home.threadRunRecord))
        XCTAssertEqual(record.process, again)
        XCTAssertEqual(record.launcher?.identity, .app(.veil), "recorded as the relauncher's")
        let answers = await waitUntil { ProcessProbe.listeningPIDs(port: port).contains(again.pid) }
        XCTAssertTrue(answers, "the same server, on the same port")
        // Its own session: it outlives whoever started it.
        XCTAssertEqual(getsid(again.pid), again.pid)

        // Any launcher adopts it, as it would one it started itself.
        let adopted = try await ManagedServer(spec: spec(test, script: script, port: port), secret: secret, launcherApp: .craft)
            .ensureRunning(timeout: 20)
        XCTAssertTrue(adopted.adopted)
        XCTAssertEqual(adopted.pid, again.pid)
    }

    func testNoLaunchRecordNothingToStart() async {
        let test = LauncherTestHome()
        do {
            _ = try await ManagedServer.relaunch(launchRecord: test.home.threadLaunchRecord, launcher: .app(.craft))
            XCTFail("expected noLaunchRecord")
        } catch let error as RelaunchError {
            guard case .noLaunchRecord = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAHomesServerIsFoundStoppedAndStartedByItsPort() async throws {
        let test = LauncherTestHome()
        let script = try test.file("stand-in-thread", contents: standInServer)
        let secret = try test.home.ensureSecret(for: .craft)
        let port = freeLoopbackPort()
        let server = ManagedServer(spec: spec(test, script: script, port: port), secret: secret, launcherApp: .craft)
        let started = try await server.ensureRunning(timeout: 20)

        let home = try XCTUnwrap(AIILocal.locate(port: port), "it runs in <home>/aii and its run record names the port")
        XCTAssertEqual(resolved(home), resolved(test.home))
        XCTAssertEqual(AIILocal.role(home: home, port: port), .thread)
        XCTAssertNil(AIILocal.locate(port: freeLoopbackPort()), "nothing listens there")
        XCTAssertNil(AIILocal.locate(port: port, pid: started.pid, workingDirectory: "/tmp"), "not an AII home's")

        XCTAssertEqual(AIILocal.running(home: home, port: port)?.pid, started.pid)
        XCTAssertTrue(AIILocal.startable(home: home, port: port))
        XCTAssertNotNil(AIILocal.log(home: home, port: port))
        XCTAssertNil(AIILocal.role(home: home, port: port + 1), "another port is none of this home's")
        XCTAssertNil(AIILocal.running(home: home, port: port + 1))
        XCTAssertFalse(AIILocal.startable(home: home, port: port + 1))
        XCTAssertNil(AIILocal.log(home: home, port: port + 1))

        let stopped = try await AIILocal.stop(home: home, port: port, grace: 5)
        XCTAssertTrue(stopped)
        XCTAssertFalse(ProcessProbe.isAlive(started.pid))
        XCTAssertNil(AIILocal.running(home: home, port: port))
        XCTAssertTrue(AIILocal.startable(home: home, port: port), "the launch record outlives the stop")
        let again = try await AIILocal.stop(home: home, port: port)
        XCTAssertFalse(again, "nothing running: nothing stopped")

        _ = await waitUntil { ProcessProbe.listeningPIDs(port: port).isEmpty }
        let restarted = try await AIILocal.start(home: home, port: port, launcher: .app(.craft))
        defer { kill(restarted.pid, SIGKILL) }
        XCTAssertEqual(AIILocal.running(home: home, port: port)?.pid, restarted.pid)
    }
}
