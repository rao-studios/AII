//
//  LauncherTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Leases, the installer's rules, and a real adopt-or-spawn against a small
//  stand-in server that proves a secret on /health the way Sewn and Thread do.
//

import Darwin
import Foundation
import XCTest
@testable import AII

final class LauncherTestHome {
    let home: AIIHome
    let base: URL

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rao-launcher-\(UUID().uuidString)", isDirectory: true)
        home = AIIHome(root: base.appendingPathComponent("home", isDirectory: true))
        try? home.provision(by: .ambient)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func file(_ name: String, contents: String, mode: mode_t = 0o755) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        chmod(PrivateFile.path(url), mode)
        return url
    }
}

func freeLoopbackPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return Int(UInt16(bigEndian: address.sin_port))
}

func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
}

final class ProcessProbeTests: XCTestCase {
    func testThisProcessIsItself() {
        let me = ProcessProbe.current
        XCTAssertEqual(me.pid, getpid())
        XCTAssertNotNil(me.processStart)
        XCTAssertTrue(ProcessProbe.isRunning(me))
        XCTAssertFalse(ProcessProbe.isRunning(ProcessStamp(pid: getpid(), processStart: (me.processStart ?? 0) + 1)),
                       "a pid with another start time is another process")
        XCTAssertNotNil(ProcessProbe.executablePath(of: getpid()))
        XCTAssertEqual(ProcessProbe.parsePIDs("12\n 34 \nx\n"), [12, 34])
    }
}

final class AIILeasesTests: XCTestCase {
    func testLiveDeadAndPinnedLeases() throws {
        let test = LauncherTestHome()
        let leases = AIILeases(home: test.home)
        try leases.acquire(for: .ambient)
        XCTAssertEqual(leases.liveHolders(), [.app(.ambient)])
        XCTAssertFalse(leases.othersAlive(excluding: .app(.ambient)))
        XCTAssertTrue(PrivateFile.exists(test.home.aiiLease(for: .ambient)))

        // Craft crashed: its lease names a process that is gone.
        try leases.acquire(for: .craft, process: ProcessStamp(pid: 999_999, processStart: 1))
        XCTAssertEqual(leases.liveHolders(), [.app(.ambient)])
        XCTAssertFalse(PrivateFile.exists(test.home.aiiLease(for: .craft)), "swept")

        // A dev script's pinned lease counts, whatever process wrote it.
        try leases.acquire(for: .veil, pinned: true, process: ProcessStamp(pid: 999_999, processStart: 1))
        XCTAssertTrue(leases.othersAlive(excluding: .app(.ambient)))
        XCTAssertEqual(leases.others(excluding: .app(.ambient)), [.app(.veil)])

        leases.release(for: .veil, pinned: true)
        leases.release(for: .ambient)
        XCTAssertTrue(leases.liveHolders().isEmpty)
    }

    func testAnotherLiveProcessesLeaseIsNotDroppedByThisOne() throws {
        let test = LauncherTestHome()
        let leases = AIILeases(home: test.home)
        let parent = ProcessStamp(pid: getppid(), processStart: ProcessProbe.startTime(of: getppid()))
        try leases.acquire(for: .craft, process: parent)
        leases.release(for: .craft)
        XCTAssertEqual(leases.liveHolders(), [.app(.craft)])
    }
}

final class AIIInstallerTests: XCTestCase {
    private func record(_ contract: Int = AIIContract.version, sha: String = "aa", by installer: StackIdentity = .app(.ambient),
                        source: AIIInstallSource = .bundled) -> AIIInstallRecord {
        AIIInstallRecord(contract: contract, sha256: sha, installedBy: installer, source: source,
                         checkout: source == .local ? AIICheckoutRecord(path: "/checkout", commit: "256e699a1c0f", configuration: "release") : nil,
                         appVersion: source == .local ? "AII 256e699a1c0f" : "Ambient 1.0.0", installedAt: Date())
    }

    func testTheRules() {
        let v = AIIContract.version
        let bundled = record()
        let local = record(by: .stack, source: .local)
        func decide(_ contract: Int, _ sha: String, by installer: StackIdentity, existing: AIIInstallRecord?) -> AIIInstaller.Decision {
            AIIInstaller.decision(bundled: contract, sha: sha, by: installer, existing: existing)
        }
        // Between apps' bundled builds.
        XCTAssertEqual(decide(v, "aa", by: .app(.craft), existing: nil), .install)
        XCTAssertEqual(decide(v, "aa", by: .app(.craft), existing: bundled), .current)
        XCTAssertEqual(decide(v + 1, "bb", by: .app(.craft), existing: bundled), .install, "newer contract")
        XCTAssertEqual(decide(v, "bb", by: .app(.ambient), existing: bundled), .install, "the installing app's own update replaces its build")
        XCTAssertEqual(decide(v, "bb", by: .app(.craft), existing: bundled), .keep, "another app's equal-contract build is kept")
        XCTAssertEqual(decide(v - 1, "bb", by: .app(.ambient), existing: bundled), .keep, "never downgrade")
        // The person's own build.
        XCTAssertEqual(decide(v, "bb", by: .app(.ambient), existing: local), .keep, "no app replaces it")
        XCTAssertEqual(decide(v + 1, "bb", by: .app(.ambient), existing: local), .keep, "not even on a newer contract")
        XCTAssertEqual(decide(v, "aa", by: .app(.ambient), existing: local), .current)
        // The person's command.
        XCTAssertEqual(decide(v, "bb", by: .stack, existing: local), .install, "aii install replaces their build")
        XCTAssertEqual(decide(v - 1, "bb", by: .stack, existing: bundled), .install, "and any app's, whatever its contract")
    }

    func testInstallVerifyAndTamper() throws {
        let test = LauncherTestHome()
        let server = try test.file("build-1/AIIServer", contents: "#!/bin/sh\necho v1\n")
        let metallib = try test.file("build-1/real.metallib", contents: "metal", mode: 0o644)
        let link = server.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: metallib)
        let installer = AIIInstaller(home: test.home, policy: .unchecked)
        let payload = AIIInstallPayload(server: server, metallib: link, appVersion: "Ambient 1.0.0 (1)",
                                        publicEnvironment: ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"])

        guard case .installed(let record, nil) = try installer.installIfNeeded(payload, by: .app(.ambient)) else {
            return XCTFail("expected a first install")
        }
        XCTAssertEqual(record.sha256, try FileDigest.sha256(of: server))
        XCTAssertEqual(record.contract, AIIContract.version)
        XCTAssertEqual(record.installedBy, .app(.ambient))
        XCTAssertEqual(record.source, .bundled)
        XCTAssertEqual(record.summary, "Installed by Ambient 1.0.0 (1)")
        XCTAssertEqual(try String(contentsOf: test.home.metallib, encoding: .utf8), "metal", "the link was resolved")
        XCTAssertEqual(PrivateFile.ownerAndMode(test.home.serverBinary)?.mode, 0o755)
        XCTAssertEqual(EnvFile.read(test.home.aiiEnvFile)["SUPABASE_URL"], "u")
        XCTAssertNoThrow(try installer.verifyInstalled())
        XCTAssertTrue(installer.isInstalled)

        guard case .alreadyCurrent = try installer.installIfNeeded(payload, by: .app(.ambient)) else { return XCTFail("current") }

        let server2 = try test.file("build-2/AIIServer", contents: "#!/bin/sh\necho v2\n")
        var craftPayload = payload
        craftPayload.server = server2
        guard case .keptExisting = try installer.installIfNeeded(craftPayload, by: .app(.craft)) else {
            return XCTFail("craft's equal-contract build doesn't replace ambient's")
        }
        guard case .installed(let second, let replaced) = try installer.installIfNeeded(craftPayload, by: .app(.ambient)) else {
            return XCTFail("ambient's own update does")
        }
        XCTAssertEqual(replaced?.sha256, record.sha256)
        XCTAssertEqual(second.sha256, try FileDigest.sha256(of: server2))

        try Data("#!/bin/sh\necho tampered\n".utf8).write(to: test.home.serverBinary)
        XCTAssertThrowsError(try installer.verifyInstalled()) { error in
            guard case .modified = error as? AIIInstallError else { return XCTFail("\(error)") }
        }
    }

    func testACheckoutPayloadIsThePersonsOwnBuild() throws {
        let test = LauncherTestHome()
        XCTAssertNil(AIIInstallPayload.checkout(test.base), "no build here")
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\n")
        _ = try test.file(".env", contents: "SUPABASE_URL=u\nSUPABASE_ANON_KEY=a\nMISTRAL_API_KEY=never\nTINKER_API_KEY=\n", mode: 0o600)
        XCTAssertEqual(ProviderKeyStore.sharedKeys(inEnvFile: test.base.appendingPathComponent(".env")), ["MISTRAL_API_KEY": "never"],
                       "the provider keys go to providers.json, not aii.env; an empty one is nothing")
        let payload = try XCTUnwrap(AIIInstallPayload.checkout(test.base))
        XCTAssertNil(payload.metallib, "no metallib built yet")
        XCTAssertEqual(payload.contract, AIIContract.version)
        XCTAssertEqual(payload.source, .local)
        XCTAssertEqual(payload.checkout?.path, PrivateFile.path(test.base.resolvingSymlinksInPath()))
        XCTAssertEqual(payload.checkout?.configuration, "release")
        XCTAssertEqual(payload.checkout?.commit, "unknown", "not a git checkout")
        XCTAssertEqual(payload.appVersion, "AII unknown")
        XCTAssertEqual(payload.publicEnvironment, ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"], "public values only")
        _ = try test.file(".build/release/mlx.metallib", contents: "metal", mode: 0o644)
        XCTAssertNotNil(AIIInstallPayload.checkout(test.base)?.metallib)
        XCTAssertNil(AIIInstallPayload.checkout(test.base, configuration: "debug"), "the named configuration only")
    }

    /// A pair typed into `aii setup` or `aii keys supabase` survives an install: the
    /// checkout's values fill what is missing and never replace what is there.
    func testAnInstallFillsMissingPublicValuesAndKeepsWhatWasTyped() throws {
        let test = LauncherTestHome()
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\n")
        _ = try test.file(".env", contents: "SUPABASE_URL=u\nSUPABASE_ANON_KEY=\n", mode: 0o600)
        XCTAssertEqual(try XCTUnwrap(AIIInstallPayload.checkout(test.base)).publicEnvironment, ["SUPABASE_URL": "u"], "an empty value is not a value")

        try AIIEnvironmentFile.update(home: test.home) { $0["SUPABASE_ANON_KEY"] = "typed" }
        let installer = AIIInstaller(home: test.home, policy: .unchecked)
        _ = try installer.installLocal(from: test.base)
        XCTAssertEqual(EnvFile.read(test.home.aiiEnvFile), ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "typed"])

        _ = try test.file(".env", contents: "SUPABASE_URL=other\nSUPABASE_ANON_KEY=other\n", mode: 0o600)
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\necho again\n")
        _ = try installer.installLocal(from: test.base)
        XCTAssertEqual(EnvFile.read(test.home.aiiEnvFile), ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "typed"], "an install never overwrites")
    }

    /// The person's build: installed as the stack, kept by every app, run without a signature.
    func testALocalBuildIsTheStacksAndNeverAnApps() throws {
        let test = LauncherTestHome()
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\necho mine\n")
        let installer = AIIInstaller(home: test.home, policy: .unchecked)

        guard case .installed(let mine, nil) = try installer.installLocal(from: test.base) else {
            return XCTFail("expected an install")
        }
        XCTAssertEqual(mine.installedBy, .stack)
        XCTAssertEqual(mine.source, .local)
        XCTAssertEqual(mine.summary, "Your build @ unknown from \(PrivateFile.path(test.base.resolvingSymlinksInPath()))")

        // Ambient ships its own build: same contract, newer contract — Ambient keeps the person's.
        let bundled = try test.file("Ambient.app/Contents/Helpers/AIIServer", contents: "#!/bin/sh\necho ambient\n")
        var payload = AIIInstallPayload(server: bundled, metallib: nil, appVersion: "Ambient 1.0.0")
        guard case .keptExisting = try installer.installIfNeeded(payload, by: .app(.ambient)) else { return XCTFail("kept") }
        payload.contract = AIIContract.version + 1
        guard case .keptExisting = try installer.installIfNeeded(payload, by: .app(.ambient)) else { return XCTFail("kept, newer") }

        // A rebuild replaces the person's build.
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\necho mine, again\n")
        guard case .installed(_, let replaced) = try installer.installLocal(from: test.base) else { return XCTFail("rebuilt") }
        XCTAssertEqual(replaced?.sha256, mine.sha256)

        XCTAssertThrowsError(try installer.installLocal(from: test.base, configuration: "debug")) { error in
            guard case .notBuilt = error as? AIIInstallError else { return XCTFail("\(error)") }
        }
    }

    /// The person installing bytes an app already had makes the install theirs.
    func testInstallingAnAppsBytesAsTheStackMakesThemLocal() throws {
        let test = LauncherTestHome()
        let built = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\necho same\n")
        let installer = AIIInstaller(home: test.home, policy: .unchecked)
        _ = try installer.installIfNeeded(AIIInstallPayload(server: built, metallib: nil, appVersion: "Ambient 1.0.0"), by: .app(.ambient))
        guard case .alreadyCurrent(let record) = try installer.installLocal(from: test.base) else { return XCTFail("current") }
        XCTAssertEqual(record.source, .local)
        XCTAssertEqual(record.installedBy, .stack)
        let onDisk = try XCTUnwrap(installer.installedRecord())
        XCTAssertEqual(onDisk.source, .local, "written down, not only returned")
        XCTAssertEqual(onDisk.installedBy, .stack)
        XCTAssertEqual(onDisk.checkout, record.checkout)
    }

    /// An unsigned script passes the Developer ID policy as the person's build, and only
    /// while its record is a private file of theirs.
    func testALocalRecordStandsInForASignatureOnlyWhenPrivate() throws {
        let test = LauncherTestHome()
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\necho unsigned\n")
        try AIIInstaller(home: test.home, policy: .unchecked).installLocal(from: test.base)
        let strict = AIIInstaller(home: test.home, policy: .developerID(teamID: SignaturePolicy.teamID))
        XCTAssertNoThrow(try strict.verifyInstalled(as: .app(.ambient)))

        let recordPath = PrivateFile.path(test.home.aiiInstallRecord)
        chmod(recordPath, 0o644)
        XCTAssertThrowsError(try strict.verifyInstalled()) { error in
            guard case .untrustedRecord = error as? AIIInstallError else { return XCTFail("\(error)") }
        }
        chmod(recordPath, 0o600)

        let copy = test.base.appendingPathComponent("record-copy.json")
        try FileManager.default.copyItem(at: test.home.aiiInstallRecord, to: copy)
        try FileManager.default.removeItem(at: test.home.aiiInstallRecord)
        try FileManager.default.createSymbolicLink(at: test.home.aiiInstallRecord, withDestinationURL: copy)
        XCTAssertThrowsError(try strict.verifyInstalled()) { error in
            guard case .untrustedRecord = error as? AIIInstallError else { return XCTFail("\(error)") }
        }

        // The same bytes as an app's bundled build must carry Rao's signature.
        try FileManager.default.removeItem(at: test.home.aiiInstallRecord)
        var record = try AIIHome.decoder.decode(AIIInstallRecord.self, from: Data(contentsOf: copy))
        record.source = .bundled
        record.installedBy = .app(.ambient)
        try record.write(home: test.home)
        XCTAssertThrowsError(try strict.verifyInstalled()) { error in
            XCTAssertTrue(error is SignatureError, "\(error)")
        }
    }

    func testAnAppRefusesThePersonsBuildBehindItsContract() throws {
        let test = LauncherTestHome()
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\n")
        let installer = AIIInstaller(home: test.home, policy: .unchecked)
        try installer.installLocal(from: test.base)
        var record = try XCTUnwrap(installer.installedRecord())
        record.contract = AIIContract.version - 1
        try record.write(home: test.home)

        let expected = AIIInstallError.localBuildBehind(installed: AIIContract.version - 1, needed: AIIContract.version, app: "Craft")
        XCTAssertThrowsError(try installer.verifyInstalled(as: .app(.craft))) { error in
            XCTAssertEqual(error as? AIIInstallError, expected)
        }
        XCTAssertEqual(expected.description,
                       "Your AII build is on contract \(AIIContract.version - 1); Craft needs contract \(AIIContract.version). "
                       + "Run aii update, or aii uninstall to let Craft install its own.")
        XCTAssertEqual(installer.installProblem(as: .app(.craft)), expected.description)
        XCTAssertNoThrow(try installer.verifyInstalled(as: .stack), "the person's command speaks its own build")
        XCTAssertNil(installer.installProblem(as: .stack))
    }

    func testUninstallRemovesTheBinaryAndTheRecord() throws {
        let test = LauncherTestHome()
        _ = try test.file(".build/release/AIIServer", contents: "#!/bin/sh\n")
        _ = try test.file(".build/release/mlx.metallib", contents: "metal", mode: 0o644)
        let installer = AIIInstaller(home: test.home, policy: .unchecked)
        try installer.installLocal(from: test.base)
        XCTAssertTrue(installer.isInstalled)
        try installer.uninstall()
        XCTAssertFalse(installer.isInstalled)
        XCTAssertFalse(PrivateFile.exists(test.home.serverBinary))
        XCTAssertFalse(PrivateFile.exists(test.home.metallib))
        XCTAssertFalse(PrivateFile.exists(test.home.aiiInstallRecord))
        XCTAssertNoThrow(try installer.uninstall(), "nothing left to remove is not an error")
    }
}

/// A stand-in for AIIServer in either role: answers /health with the v1 proof for the
/// secret of the identity X-AII-App names, read from AII_HOME the way the real servers
/// do. Takes the role as its first argument and `--port N` like them; `STAND_IN_CONTRACT`
/// in its environment is the contract it claims (this build's when unset).
let standInServer = """
#!/usr/bin/env python3
import hashlib, hmac, http.server, json, os, sys
args = sys.argv[1:]
port = int(args[args.index("--port") + 1])
home = os.environ.get("AII_HOME")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        nonce = self.headers.get("X-Ambient-Nonce") or ""
        who = (self.headers.get("X-AII-App") or "").strip().lower()
        body = {"stack": "proof", "contract": int(os.environ.get("STAND_IN_CONTRACT", "\(AIIContract.version)"))}
        secret = ""
        if home and who:
            try:
                with open(os.path.join(home, "secrets", who)) as f: secret = f.read().strip()
                body["app"] = who
            except OSError:
                secret = ""
        if nonce and secret:
            body["proof"] = hmac.new(secret.encode(), ("ambient-stack-health-v1:" + nonce).encode(), hashlib.sha256).hexdigest()
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"""

final class ManagedServerTests: XCTestCase {

    /// The stand-in proves craft's secret from the home, so every challenge here is craft's.
    private func spec(_ test: LauncherTestHome, script: URL, secret: String, port: Int,
                      role: LaunchSpec.Role = .thread, contract: Int = AIIContract.version) -> LaunchSpec {
        LaunchSpec(role: role, executable: script, arguments: [role.subcommand, "--port", String(port)],
                   environment: ["PATH": "/usr/bin:/bin", "AII_HOME": PrivateFile.path(test.home.root),
                                 "STAND_IN_CONTRACT": String(contract)],
                   workingDirectory: test.home.aiiDirectory, ports: AIIPorts(http: port, grpc: port),
                   runRecord: role == .sewn ? test.home.sewnRunRecord : test.home.threadRunRecord,
                   logFile: role == .sewn ? test.home.sewnLogFile : test.home.threadLogFile,
                   challenge: .app(.craft))
    }

    func testSpawnAdoptAndStop() async throws {
        let test = LauncherTestHome()
        let script = try test.file("stand-in-thread", contents: standInServer)
        let secret = try test.home.ensureSecret(for: .craft)
        let port = freeLoopbackPort()
        let spec = spec(test, script: script, secret: secret, port: port)

        let first = ManagedServer(spec: spec, secret: secret, launcherApp: .craft)
        let started = try await first.ensureRunning(timeout: 20)
        XCTAssertFalse(started.adopted)
        XCTAssertEqual(started.launchedBy, .app(.craft))
        XCTAssertTrue(ProcessProbe.isAlive(started.pid))
        let record = try XCTUnwrap(RunRecord.load(spec.runRecord))
        XCTAssertEqual(record.process.pid, started.pid)
        XCTAssertEqual(record.launcher?.identity, .app(.craft))
        XCTAssertEqual(record.launcher?.process, ProcessProbe.current)

        // Another app's supervisor adopts the one Thread rather than starting a second one.
        let second = ManagedServer(spec: spec, secret: secret, launcherApp: .veil)
        let adopted = try await second.ensureRunning(timeout: 20)
        XCTAssertTrue(adopted.adopted)
        XCTAssertEqual(adopted.pid, started.pid)
        XCTAssertEqual(adopted.launchedBy, .app(.craft))

        // The wrong secret is never ours: the port is in use.
        let impostor = ManagedServer(spec: spec, secret: StackSecret.generate(), launcherApp: .craft)
        RunRecord.remove(spec.runRecord)
        do {
            _ = try await impostor.ensureRunning(timeout: 5)
            XCTFail("expected portInUse")
        } catch let error as ManagedServerError {
            guard case .portInUse = error else { return XCTFail("\(error)") }
        }

        await first.stop()
        let gone = await waitUntil { !ProcessProbe.isAlive(started.pid) }
        XCTAssertTrue(gone)
        XCTAssertNil(RunRecord.load(spec.runRecord))
    }

    func testAnOrphanIsReplacedOnlyWhenOutdated() throws {
        let test = LauncherTestHome()
        let binary = try test.file("installed/AIIServer", contents: "#!/bin/sh\n")
        let recorded = ProcessProbe.resolvedPath(binary)
        let modified = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: recorded))[.modificationDate] as? Date)
        let before = UInt64(modified.timeIntervalSince1970 * 1_000_000)
        XCTAssertFalse(ManagedServer.isOutdated(recordedBinary: recorded, processStart: before + 5_000_000, wanted: binary),
                       "started after the binary was built: current, adopt it")
        XCTAssertTrue(ManagedServer.isOutdated(recordedBinary: recorded, processStart: before - 5_000_000, wanted: binary),
                      "the binary was rebuilt after it started: replace it")
        let other = try test.file("other/AIIServer", contents: "#!/bin/sh\n")
        XCTAssertTrue(ManagedServer.isOutdated(recordedBinary: recorded, processStart: before + 5_000_000, wanted: other),
                      "this launch runs another binary: replace it")
        XCTAssertTrue(ManagedServer.isOutdated(recordedBinary: recorded, processStart: nil, wanted: binary),
                      "no start time to compare: replace it, as before")
    }

    /// The installer copies a server into place, and a copy keeps the build's mtime: one
    /// installed after the running one started must still read as newer than it.
    func testAReinstallIsNewerThanTheProcessWhateverItsMtime() throws {
        let test = LauncherTestHome()
        let binary = try test.file("installed/AIIServer", contents: "#!/bin/sh\n")
        let path = ProcessProbe.resolvedPath(binary)
        let startedFiveSecondsAgo = UInt64(Date().timeIntervalSince1970 * 1_000_000) - 5_000_000
        let anHourAgo = timeval(tv_sec: time(nil) - 3600, tv_usec: 0)
        var times = [anHourAgo, anHourAgo]
        XCTAssertEqual(utimes(path, &times), 0)
        XCTAssertTrue(ManagedServer.isOutdated(recordedBinary: path, processStart: startedFiveSecondsAgo, wanted: binary),
                      "built an hour ago, put in place just now: newer than a process five seconds old")
    }

    func testWhenAServerIsStale() throws {
        let test = LauncherTestHome()
        let installed = try test.file("installed/AIIServer", contents: "#!/bin/sh\n")
        let path = ProcessProbe.resolvedPath(installed)
        let changed = try XCTUnwrap(ProcessProbe.changeTime(ofFile: path))
        let before = changed - 5_000_000, after = changed + 5_000_000
        let checkout = ProcessProbe.resolvedPath(try test.file("checkout/.build/release/AIIServer", contents: "#!/bin/sh\n"))
        let current = AIIContract.version

        XCTAssertFalse(ManagedServer.isStale(recordedBinary: path, processStart: after, contract: current, wanted: installed),
                       "the build this app runs, started after it was installed: adopt it")
        XCTAssertTrue(ManagedServer.isStale(recordedBinary: path, processStart: before, contract: current, wanted: installed),
                      "installed again while it ran: replace it, same contract or not")
        XCTAssertTrue(ManagedServer.isStale(recordedBinary: path, processStart: before, contract: nil, wanted: installed),
                      "unproven, and an old build: replace it")
        XCTAssertFalse(ManagedServer.isStale(recordedBinary: checkout, processStart: before, contract: current, wanted: installed),
                       "a checkout build someone chose, on this contract: adopt it")
        XCTAssertTrue(ManagedServer.isStale(recordedBinary: checkout, processStart: after, contract: current - 1, wanted: installed),
                      "another build on an older contract: replace it")
        XCTAssertFalse(ManagedServer.isStale(recordedBinary: checkout, processStart: before, contract: nil, wanted: installed),
                       "an unproven checkout build: its holders decide, not its build")
    }

    /// Either server is one per Mac, and any app may bring it up to date or restart it
    /// while other apps hold it.
    func testAnyAppReplacesAStaleServerAndRestartsItWhoeverHoldsIt() async throws {
        let test = LauncherTestHome()
        let script = try test.file("stand-in-sewn", contents: standInServer)
        let secret = try test.home.ensureSecret(for: .craft)
        let port = freeLoopbackPort()
        let veilHoldsIt: @Sendable () -> [AIIApp] = { [.veil] }

        let older = ManagedServer(spec: spec(test, script: script, secret: secret, port: port, role: .sewn,
                                             contract: AIIContract.version - 1),
                                  secret: secret, launcherApp: .ambient)
        let old = try await older.ensureRunning(timeout: 20)
        XCTAssertEqual(old.contract, AIIContract.version - 1)

        let current = spec(test, script: script, secret: secret, port: port, role: .sewn)
        let craft = ManagedServer(spec: current, secret: secret, launcherApp: .craft, othersNeedIt: veilHoldsIt)
        let replaced = try await craft.ensureRunning(timeout: 20)
        XCTAssertFalse(replaced.adopted, "an older contract is replaced though Veil holds it")
        XCTAssertNotEqual(replaced.pid, old.pid)
        XCTAssertEqual(replaced.contract, AIIContract.version)
        let oldGone = await waitUntil { !ProcessProbe.isAlive(old.pid) }
        XCTAssertTrue(oldGone)

        let ambient = ManagedServer(spec: current, secret: secret, launcherApp: .ambient, othersNeedIt: veilHoldsIt)
        let adopted = try await ambient.ensureRunning(timeout: 20)
        XCTAssertTrue(adopted.adopted, "a current server is shared, not replaced")
        XCTAssertEqual(adopted.pid, replaced.pid)

        let restarted = try await ambient.restart(timeout: 20)
        XCTAssertFalse(restarted.adopted, "an asked-for restart happens though Craft and Veil hold it")
        XCTAssertNotEqual(restarted.pid, replaced.pid)
        XCTAssertEqual(RunRecord.load(current.runRecord)?.process.pid, restarted.pid)

        // Craft's handle names the server Ambient replaced; its next check finds the new one.
        let followed = try await craft.ensureRunning(timeout: 20)
        XCTAssertEqual(followed.pid, restarted.pid)
        XCTAssertTrue(followed.adopted)

        await ambient.stop()
        let gone = await waitUntil { !ProcessProbe.isAlive(restarted.pid) }
        XCTAssertTrue(gone)
    }

    /// What may be exec'd is the launcher's verifier's call, made at spawn.
    func testAVerifierThatThrowsStopsTheSpawn() async throws {
        let test = LauncherTestHome()
        let script = try test.file("stand-in-refused", contents: standInServer)
        let secret = try test.home.ensureSecret(for: .craft)
        let spec = spec(test, script: script, secret: secret, port: freeLoopbackPort())
        let server = ManagedServer(spec: spec, secret: secret, launcher: .app(.craft),
                                   verify: { _ in throw AIIInstallError.untrustedRecord("install.json") })
        do {
            _ = try await server.ensureRunning(timeout: 5)
            XCTFail("expected the verifier to refuse")
        } catch let error as ManagedServerError {
            guard case .signature(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("install.json"))
        }
        XCTAssertNil(RunRecord.load(spec.runRecord), "nothing was started")
    }

    func testAServerThatExitsReportsItsLog() async throws {
        let test = LauncherTestHome()
        let script = try test.file("dies", contents: "#!/bin/sh\necho 'bad flag' >&2\nexit 3\n")
        let secret = try test.home.ensureSecret(for: .craft)
        let server = ManagedServer(spec: spec(test, script: script, secret: secret, port: freeLoopbackPort()),
                                   secret: secret, launcherApp: .craft)
        do {
            _ = try await server.ensureRunning(timeout: 10)
            XCTFail("expected exited")
        } catch let error as ManagedServerError {
            guard case .exited(let tail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(tail.contains("bad flag"))
        }
    }
}
