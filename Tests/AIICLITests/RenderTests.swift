//
//  RenderTests.swift
//  AIICLITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  What `aii status` prints, from a report: one row per fact, the fix after `→`; and the
//  doctor's checks against scratch homes, each saying what is wrong and how to fix it.
//

import AII
import Foundation
import XCTest
@testable import AIICLI

/// A throwaway AII_HOME under the temp directory, removed on deinit.
final class ScratchHome {
    let home: AIIHome
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("aii-cli-\(UUID().uuidString)", isDirectory: true)
        home = AIIHome(root: url.appendingPathComponent("rao", isDirectory: true))
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: String, mode: mode_t = 0o755) throws -> URL {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        chmod(PrivateFile.path(file), mode)
        return file
    }
}

final class RenderTests: XCTestCase {
    private let installedAt = Date(timeIntervalSince1970: 1_792_000_000)

    private func server(_ role: String, _ state: String, pid: Int32? = nil, detail: String? = nil, embedder: String? = nil) -> StatusReport.Server {
        StatusReport.Server(role: role, state: state, healthy: state == "up", detail: detail, pid: pid,
                            http: role == "sewn" ? 47080 : 47081, grpc: role == "sewn" ? 47091 : 47090,
                            verified: state == "up", contract: 1, binary: nil, launchedBy: nil, startedAt: nil, embedder: embedder)
    }

    private func report(install: StatusReport.Install?, servers: [StatusReport.Server], holders: [StatusReport.Holder] = [],
                        models: [StatusReport.Model]? = nil) -> StatusReport {
        StatusReport(home: "/tmp/rao", layout: 1, provisionedBy: "Ambient", install: install, contract: 1,
                     servers: servers, holders: holders, lanes: ["ambient", "craft", "notes"], models: models)
    }

    private func local(contract: Int = 1) -> StatusReport.Install {
        StatusReport.Install(summary: "", source: "local", installedBy: "aii", appVersion: "AII 256e699a1c0f", contract: contract,
                             sha256: "ab", installedAt: installedAt, checkout: "/src/AII", commit: "256e699a1c0f", configuration: "release")
    }

    func testAStackThatIsUpOnYourBuild() {
        let lines = Render.status(report(
            install: local(),
            servers: [server("sewn", "up", pid: 4123), server("thread", "up", pid: 4130, embedder: "ready")],
            holders: [.init(identity: "ambient", pinned: false), .init(identity: "aii", pinned: true)],
            models: [.init(role: "embedding", id: "e", revision: "r", state: "installed", progress: nil, kept: true),
                     .init(role: "coding", id: "c", revision: "r", state: "absent", progress: nil, kept: false)]))
        XCTAssertEqual(lines, [
            "home      /tmp/rao · layout 1, provisioned by Ambient",
            "install   Your build @ 256e699a1c0f from /src/AII · release · \(Stamp.minute(installedAt))",
            "contract  1 · this aii speaks 1",
            "Sewn      ✓ up · pid 4123 · http 47080 grpc 47091 · verified",
            "Thread    ✓ up · pid 4130 · http 47081 grpc 47090 · verified · embedder ready",
            "held by   ambient, aii (pinned)",
            "lanes     ambient, craft, notes",
            "keys      none → aii keys set mistral, or aii setup",
            "models    1 of 2 pinned on this Mac · missing coding",
        ])
    }

    func testTheKeysRowNamesEachProviderAndNeverAValue() {
        let when = Date(timeIntervalSince1970: 1_792_000_000)
        let records = ["MISTRAL_API_KEY": ProviderKeyRecord(value: "secret-value", source: .typed, writtenBy: .app(.ambient), updatedAt: when)]
        let keys = StatusReport.providerKeys(records)
        XCTAssertEqual(keys.map(\.set), [true, false])
        XCTAssertEqual(keys[0].writtenBy, "ambient")
        XCTAssertEqual(Render.keys(keys, supabase: true), "Mistral ✓ (ambient) · Tinker none · Supabase ✓")
        XCTAssertEqual(Render.keys(keys, supabase: false), "Mistral ✓ (ambient) · Tinker none · Supabase none")
        XCTAssertEqual(Render.keys(StatusReport.providerKeys([:]), supabase: false), "none → aii keys set mistral, or aii setup")
        XCTAssertEqual(Render.keys(StatusReport.providerKeys([:]), supabase: true), "Mistral none · Tinker none · Supabase ✓")
        var report = self.report(install: nil, servers: [])
        report.keys = keys
        XCTAssertFalse(try report.json().contains("secret-value"), "the JSON report carries no value")
    }

    func testAStackThatIsDownOrBehind() {
        var down = report(install: local(contract: 0), servers: [server("sewn", "down"), server("thread", "down", detail: "exited")])
        down.modelsProblem = "Sewn is down"
        let lines = Render.status(down)
        XCTAssertEqual(lines[2], "contract  0 · this aii speaks 1 → aii update")
        XCTAssertEqual(lines[3], "Sewn      ✗ down → aii start")
        XCTAssertEqual(lines[4], "Thread    ✗ down · exited → aii logs thread")
        XCTAssertEqual(lines[5], "held by   nobody")
        XCTAssertEqual(lines[8], "models    (Sewn is down)")

        let bundled = StatusReport.Install(summary: "", source: "bundled", installedBy: "ambient", appVersion: "Ambient 1.0.0 (1)",
                                           contract: 1, sha256: "ab", installedAt: installedAt)
        XCTAssertEqual(Render.install(bundled), "Installed by Ambient 1.0.0 (1) · \(Stamp.minute(installedAt))")
        XCTAssertEqual(Render.install(nil), "none → aii install, or launch a Rao app")
        XCTAssertEqual(Render.server(server("sewn", "port 47080 is answered by another program")),
                       "Sewn      ✗ port 47080 is answered by another program → aii logs sewn")
    }

    func testTheJSONReportRoundTrips() throws {
        let original = report(install: local(), servers: [server("sewn", "up", pid: 1), server("thread", "down")])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(StatusReport.self, from: Data(try original.json().utf8)), original)
    }
}

final class ChecksTests: XCTestCase {

    func testAnEmptyHomeSaysHowToBegin() {
        let scratch = ScratchHome()
        XCTAssertEqual(Checks.home(scratch.home).fix, "aii start, or launch a Rao app")
        XCTAssertFalse(Checks.home(scratch.home).ok)
        XCTAssertFalse(Checks.install(scratch.home).ok)
        XCTAssertEqual(Checks.install(scratch.home).fix, "aii install, or launch a Rao app")
    }

    func testAProvisionedHomePasses() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        for check in [Checks.home(scratch.home), Checks.secrets(scratch.home), Checks.deviceKey(scratch.home), Checks.lanes(scratch.home)] {
            XCTAssertTrue(check.ok, check.line)
        }
        XCTAssertEqual(Checks.lanes(scratch.home).detail, "ambient, craft, veil · 3 under aii-local")
    }

    func testASecretAndItsManifestEntryGoTogether() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        _ = try scratch.home.ensureSecret(for: AIIApp("notes"))
        var check = Checks.lanes(scratch.home)
        XCTAssertFalse(check.ok, "an unlisted lane")
        XCTAssertEqual(check.detail, "notes has a secret but no lane in the manifest")
        XCTAssertEqual(check.fix, "aii lanes add notes")

        try scratch.home.register("notes")
        XCTAssertTrue(Checks.lanes(scratch.home).ok)
        try FileManager.default.removeItem(at: scratch.home.secretFile(for: AIIApp("notes")))
        check = Checks.lanes(scratch.home)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.detail, "notes has a lane but no secret")
    }

    func testALooseSecretFails() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        chmod(PrivateFile.path(scratch.home.secretFile(for: .craft)), 0o644)
        let check = Checks.secrets(scratch.home)
        XCTAssertFalse(check.ok)
        XCTAssertTrue(check.detail.hasPrefix("craft: "), check.detail)
    }

    func testTheInstallIsCheckedAgainstItsRecord() throws {
        let scratch = ScratchHome()
        _ = try scratch.file("checkout/.build/release/AIIServer", contents: "#!/bin/sh\n")
        try AIIInstaller(home: scratch.home, policy: .unchecked).installLocal(from: scratch.url.appendingPathComponent("checkout"))
        XCTAssertTrue(Checks.install(scratch.home).ok, Checks.install(scratch.home).line)
        let record = try XCTUnwrap(AIIInstallRecord.load(home: scratch.home))
        XCTAssertTrue(Checks.source(scratch.home, record: record).ok, "your build needs no signature")
        XCTAssertTrue(Checks.contract(record).ok)

        try Data("#!/bin/sh\necho changed\n".utf8).write(to: scratch.home.serverBinary)
        XCTAssertEqual(Checks.install(scratch.home).fix, "aii install")

        chmod(PrivateFile.path(scratch.home.aiiInstallRecord), 0o644)
        XCTAssertFalse(Checks.source(scratch.home, record: record).ok)

        var behind = record
        behind.contract = AIIContract.version - 1
        XCTAssertEqual(Checks.contract(behind).fix, "aii update")
        XCTAssertTrue(Checks.contract(behind).detail.contains("speaks \(AIIContract.version - 1)"))
    }

    func testAnUnreadableRecordIsNotNothing() throws {
        let scratch = ScratchHome()
        try PrivateFile.ensureDirectory(scratch.home.aiiBinDirectory)
        try PrivateFile.writeAtomically(Data("x".utf8), to: scratch.home.serverBinary)
        try PrivateFile.writeAtomically(Data(#"{"installedBy":"ambient"}"#.utf8), to: scratch.home.aiiInstallRecord)
        XCTAssertEqual(Checks.install(scratch.home).detail, "an AIIServer is there, but not an install.json this aii can read")
    }

    func testTheModelsTheIndexNeeds() {
        XCTAssertEqual(Checks.models(nil).fix, "aii start")
        XCTAssertEqual(Checks.models(nil, problem: "Sewn didn't list them: refused").fix, "aii install, then aii restart")
        let absent = AIIModels.all.map { AIIModelState(id: $0.id, disk: .absent, entry: $0) }
        XCTAssertEqual(Checks.models(absent).fix, "aii models pull embedding")
        let kept = AIIModels.all.map { AIIModelState(id: $0.id, disk: AIIModels.kept.contains($0.id) ? .installed : .absent, entry: $0) }
        XCTAssertTrue(Checks.models(kept).ok, "the others are an app's choice")
    }

    func testTheCommandOnPath() throws {
        let scratch = ScratchHome()
        XCTAssertEqual(Checks.command(path: "/usr/bin", home: scratch.home).fix, "Scripts/setup.sh")
        try PrivateFile.ensureDirectory(scratch.home.cliDirectory)
        try PrivateFile.writeAtomically(Data("#!/bin/sh\n".utf8), to: scratch.home.cliBinary, mode: 0o755)
        XCTAssertFalse(Checks.command(path: "/usr/bin", home: scratch.home).ok)
        XCTAssertEqual(Checks.command(path: "/usr/bin", home: scratch.home).fix, "Scripts/setup.sh --add-to-path")
        XCTAssertTrue(Checks.command(path: "/usr/bin:" + PrivateFile.path(scratch.home.cliDirectory), home: scratch.home).ok)
    }

    func testNoProviderKeyIsASupportedState() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        let check = Checks.providerKeys(scratch.home)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.detail, "none yet · the index runs on device · aii keys set mistral adds one")
        try ProviderKeyStore(home: scratch.home).write(ProviderKeyStore.mistralAPIKey, value: "m", source: .typed, writtenBy: .stack)
        XCTAssertEqual(Checks.providerKeys(scratch.home).detail, "MISTRAL_API_KEY (typed, aii) · 0600 · read per call")
    }

    func testALooseOrMalformedProvidersFileFails() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        try ProviderKeyStore(home: scratch.home).write(ProviderKeyStore.mistralAPIKey, value: "m", source: .typed, writtenBy: .stack)
        chmod(PrivateFile.path(scratch.home.providersFile), 0o644)
        var check = Checks.providerKeys(scratch.home)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.fix, "chmod 600 \(tilde(scratch.home.providersFile))")

        try PrivateFile.writeAtomically(Data("not json".utf8), to: scratch.home.providersFile)
        check = Checks.providerKeys(scratch.home)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.fix, "aii keys set mistral writes it again")
        XCTAssertTrue(check.detail.contains("doesn't decode"), check.detail)
    }

    func testNoSupabaseIsASupportedStateAndHalfAPairIsNot() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        XCTAssertTrue(Checks.environment(scratch.home).ok)
        XCTAssertTrue(Checks.environment(scratch.home).detail.hasPrefix("none · no accounts layer"))

        try AIIEnvironmentFile.update(home: scratch.home) { $0["SUPABASE_URL"] = "https://xyz.supabase.co" }
        var check = Checks.environment(scratch.home)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.detail, "aii.env has SUPABASE_URL but no SUPABASE_ANON_KEY")
        XCTAssertEqual(check.fix, "aii keys supabase --anon-key …")

        try AIIEnvironmentFile.update(home: scratch.home) { $0["SUPABASE_ANON_KEY"] = "anon" }
        check = Checks.environment(scratch.home)
        XCTAssertTrue(check.ok, check.line)
        XCTAssertEqual(check.detail, "xyz.supabase.co · read by Sewn at start")
    }

    func testADeniedKeyOrALooseAiiEnvFails() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        try PrivateFile.ensureDirectory(scratch.home.aiiDirectory)
        try PrivateFile.writeAtomically(Data("SUPABASE_URL=https://x.supabase.co\nSUPABASE_ANON_KEY=a\nMISTRAL_API_KEY=k\n".utf8), to: scratch.home.aiiEnvFile)
        var check = Checks.environment(scratch.home)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.detail, "aii.env holds MISTRAL_API_KEY, which Sewn ignores there")
        XCTAssertEqual(check.fix, "aii keys set mistral, then remove it from aii.env")

        try AIIEnvironmentFile.update(home: scratch.home) { _ in }
        chmod(PrivateFile.path(scratch.home.aiiEnvFile), 0o644)
        check = Checks.environment(scratch.home)
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.fix, "chmod 600 \(tilde(scratch.home.aiiEnvFile))")
    }
}

final class RefusalTests: XCTestCase {

    func testStopNamesWhoHoldsTheStack() {
        let home = AIIHome(root: URL(fileURLWithPath: "/tmp/none"))
        XCTAssertNil(StopCommand.refusal(holders: [], force: false, home: home))
        XCTAssertNil(StopCommand.refusal(holders: [.app(.ambient)], force: true, home: home))
        let refusal = StopCommand.refusal(holders: [.app(.ambient), .app(.craft)], force: false, home: home)
        XCTAssertEqual(refusal?.description, "aii: Ambient and Craft hold the stack; it stays up\n  pass --force to stop it anyway")
        XCTAssertEqual(refusal?.code, .usage)
    }

    func testUninstallTakesOnlyYourBuildWithTheServersStoppedAndYes() {
        let home = AIIHome(root: URL(fileURLWithPath: "/tmp/none"))
        let mine = AIIInstallRecord(contract: 1, sha256: "ab", installedBy: .stack, source: .local, appVersion: "AII x", installedAt: Date())
        let ambients = AIIInstallRecord(contract: 1, sha256: "ab", installedBy: .app(.ambient), source: .bundled, appVersion: "Ambient 1", installedAt: Date())
        XCTAssertEqual(UninstallCommand.refusal(record: nil, serversUp: false, yes: true, home: home)?.code, .missing)
        XCTAssertEqual(UninstallCommand.refusal(record: ambients, serversUp: false, yes: true, home: home)?.code, .missing)
        XCTAssertEqual(UninstallCommand.refusal(record: mine, serversUp: true, yes: true, home: home)?.code, .temporary)
        XCTAssertEqual(UninstallCommand.refusal(record: mine, serversUp: false, yes: false, home: home)?.code, .usage)
        XCTAssertNil(UninstallCommand.refusal(record: mine, serversUp: false, yes: true, home: home))
    }

    func testLibraryErrorsBecomeTheCommandsWords() {
        XCTAssertEqual(AIIFailure.from(AIIInstallError.notInstalled).code, .missing)
        XCTAssertEqual(AIIFailure.from(AIIInstallError.localBuildBehind(installed: 0, needed: 1, app: "Ambient")).hint, "aii update")
        XCTAssertEqual(AIIFailure.from(AIIHomeError.reservedName("aii")).code, .usage)
        XCTAssertEqual(AIIFailure.from(AIIClientError.transport("down")).code, .unavailable)
        XCTAssertEqual(AIIFailure.sentence("Your AII build is on contract 0."), "your AII build is on contract 0")
        XCTAssertEqual(AIIFailure.sentence("AIIServer is missing."), "AIIServer is missing")
    }
}
