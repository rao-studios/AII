//
//  AIIInstaller.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Puts AIIServer, with its Metal library, into AII_HOME/aii/bin, where every
//        app runs both roles from, and checks what is there before anyone runs it. The
//        build is either an app's signed helper (bundled) or the person's own, built
//        from an AII checkout (local).
//  IN:   An app at launch, from its bundle's Contents/Helpers (AIISupervisor.install);
//        `aii install`, `aii update` and Ambient's Rebuild, from a checkout
//        (installLocal).
//  OUT:  aii/bin/{AIIServer,mlx.metallib}, install.json, aii.env.
//  PIN:  One binary, one metallib, one record: Sewn and Thread are two processes of the
//        same build, so no app can leave Ambient's Sewn beside Craft's Thread.
//        Who wins: the person's command (`aii`, the stack identity) always installs, and
//        no app ever replaces a local build, at any contract. Between apps' bundled
//        builds, install when nothing is there, when the bundled contract is newer, or
//        when it is the same contract, this app installed it, and the bytes differ (an
//        update); never downgrade, never replace another app's newer or equal install.
//        Trust: a bundled build runs only when it passes the signature policy. A local
//        build runs when its sha matches install.json and install.json is a regular,
//        0600 file of this user's: the person put it there with their own command into
//        their own private home, and anyone who can forge that record already runs as
//        the person. The signature check guards the bundled path against a tampered
//        helper, not against the owner. An app that needs a newer contract than the
//        person's build reports the gap and replaces nothing.
//        Files are copied beside their destination and renamed into place: overwriting
//        a signed executable in place can get a running copy killed, and a reader must
//        never see half a binary. Symlinks are resolved (the app bundle keeps
//        mlx.metallib as one); quarantine is stripped.
//

#if os(macOS)
import Darwin
import Foundation

public struct AIIInstallPayload: Sendable, Equatable {
    /// AIIServer, as built or as a bundle carries it.
    public var server: URL
    public var metallib: URL?
    /// Free text for install.json, e.g. "Ambient 1.0.0 (1) 5984003", or "AII 256e699a1c0f".
    public var appVersion: String
    public var contract: Int
    /// Written to aii.env (AIIEnvironmentFile.allowedKeys only).
    public var publicEnvironment: [String: String]
    public var source: AIIInstallSource
    /// For a local build: the checkout it comes from.
    public var checkout: AIICheckoutRecord?

    public init(server: URL, metallib: URL?, appVersion: String, contract: Int = AIIContract.version,
                publicEnvironment: [String: String] = [:], source: AIIInstallSource = .bundled,
                checkout: AIICheckoutRecord? = nil) {
        self.server = server
        self.metallib = metallib
        self.appVersion = appVersion
        self.contract = contract
        self.publicEnvironment = publicEnvironment
        self.source = source
        self.checkout = checkout
    }

    /// AIIServer as a shipped app carries it: `Contents/Helpers/AIIServer` and
    /// `mlx.metallib` beside it (a symlink into Resources, resolved on install).
    /// Nil when the bundle ships no helper (a dev build).
    public static func bundled(in bundle: Bundle, appVersion: String, publicEnvironment: [String: String] = [:]) -> AIIInstallPayload? {
        let helpers = bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let server = helpers.appendingPathComponent(LaunchSpec.executableName)
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: PrivateFile.path(server)) else { return nil }
        let candidates = [helpers.appendingPathComponent("mlx.metallib"),
                          bundle.bundleURL.appendingPathComponent("Contents/Resources/mlx.metallib")]
        let metallib = candidates.first { manager.fileExists(atPath: PrivateFile.path($0)) }
        return AIIInstallPayload(server: server, metallib: metallib, appVersion: appVersion,
                                 publicEnvironment: publicEnvironment, source: .bundled)
    }

    /// AIIServer as an AII checkout builds it: `.build/<configuration>/AIIServer`, with
    /// `mlx.metallib` beside it (Scripts/build-servers.sh). The person's own build:
    /// `local`, named after the checkout's commit. The public environment is the
    /// checkout's `.env` values that aii.env may hold, non-empty, unless one is given.
    public static func checkout(_ root: URL, configuration: String = "release",
                                publicEnvironment: [String: String]? = nil) -> AIIInstallPayload? {
        let root = root.resolvingSymlinksInPath()
        let server = root.appendingPathComponent(".build/\(configuration)/\(LaunchSpec.executableName)")
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: PrivateFile.path(server)) else { return nil }
        let metallib = root.appendingPathComponent(".build/\(configuration)/mlx.metallib")
        let commit = AIICheckout.commit(of: root)
        let environment = publicEnvironment
            ?? EnvFile.read(root.appendingPathComponent(".env")).filter { AIIEnvironmentFile.allowedKeys.contains($0.key) && !$0.value.isEmpty }
        return AIIInstallPayload(
            server: server,
            metallib: manager.fileExists(atPath: PrivateFile.path(metallib)) ? metallib : nil,
            appVersion: "AII \(commit)",
            publicEnvironment: environment,
            source: .local,
            checkout: AIICheckoutRecord(path: PrivateFile.path(root), commit: commit, configuration: configuration))
    }
}

public enum AIIInstallOutcome: Sendable, Equatable {
    /// This call put AIIServer in place; `replaced` is what was there.
    case installed(AIIInstallRecord, replaced: AIIInstallRecord?)
    /// This build was already installed.
    case alreadyCurrent(AIIInstallRecord)
    /// Another install stays: the person's own, or another app's newer or equal one.
    case keptExisting(AIIInstallRecord)

    public var record: AIIInstallRecord {
        switch self {
        case .installed(let record, _), .alreadyCurrent(let record), .keptExisting(let record): return record
        }
    }
}

public enum AIIInstallError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case modified(expected: String, found: String)
    case copyFailed(String)
    /// A checkout with no AIIServer built for the configuration.
    case notBuilt(String)
    /// install.json for a local build that isn't a regular, private file of this user's.
    case untrustedRecord(String)
    /// The person's build speaks an older contract than the app.
    case localBuildBehind(installed: Int, needed: Int, app: String)

    public var description: String {
        switch self {
        case .notInstalled: return "the Ambient Intelligence Index is not installed in ~/.rao"
        case .modified: return "the installed \(LaunchSpec.executableName) no longer matches install.json"
        case .copyFailed(let reason): return "couldn't install the Ambient Intelligence Index: \(reason)"
        case .notBuilt(let path): return "no \(LaunchSpec.executableName) is built at \(path)"
        case .untrustedRecord(let path): return "\(path) must be a regular file of yours, mode 0600, to vouch for your build"
        case .localBuildBehind(let installed, let needed, let app):
            return "Your AII build is on contract \(installed); \(app) needs contract \(needed). "
                + "Run aii update, or aii uninstall to let \(app) install its own."
        }
    }
}

public struct AIIInstaller: Sendable {
    public let home: AIIHome
    public let policy: SignaturePolicy

    public init(home: AIIHome, policy: SignaturePolicy = .standard) {
        self.home = home
        self.policy = policy
    }

    /// The record, when the binary is there to go with it.
    public func installedRecord() -> AIIInstallRecord? {
        guard PrivateFile.exists(home.serverBinary) else { return nil }
        return AIIInstallRecord.load(home: home)
    }

    public var isInstalled: Bool { installedRecord() != nil }

    public enum Decision: Sendable, Equatable {
        case install, current, keep
    }

    /// What an installer would do with a payload, without doing it.
    public static func decision(bundled contract: Int, sha: String, by installer: StackIdentity,
                                existing: AIIInstallRecord?) -> Decision {
        guard let existing else { return .install }
        if existing.sha256 == sha { return .current }
        if installer.isStack { return .install }
        if existing.source == .local { return .keep }
        if contract > existing.contract { return .install }
        if contract == existing.contract && existing.installedBy == installer { return .install }
        return .keep
    }

    /// Installs `payload` when the rules say so. Serialized across processes.
    /// `policy` overrides the installer's for this call (`.unchecked` for a local build).
    @discardableResult
    public func installIfNeeded(_ payload: AIIInstallPayload, by installer: StackIdentity, policy override: SignaturePolicy? = nil,
                                now: Date = Date()) throws -> AIIInstallOutcome {
        let policy = override ?? self.policy
        try PrivateFile.ensureDirectory(home.aiiDirectory)
        try PrivateFile.ensureDirectory(home.aiiBinDirectory)
        return try PrivateFile.withExclusiveLock(home.aiiInstallLockFile) {
            let source = payload.server.resolvingSymlinksInPath()
            let sha = try FileDigest.sha256(of: source)
            let existing = installedRecord()
            switch Self.decision(bundled: payload.contract, sha: sha, by: installer, existing: existing) {
            case .current:
                var record = existing!
                // A metallib added since, or removed by hand: put it back.
                if let metallib = payload.metallib, !PrivateFile.exists(home.metallib) {
                    try place(metallib.resolvingSymlinksInPath(), at: home.metallib, mode: 0o644)
                }
                try writeEnvironmentIfMissing(payload.publicEnvironment)
                // The person installed the bytes an app had: from now on it is theirs.
                if installer.isStack, record.source == .bundled {
                    record = AIIInstallRecord(contract: payload.contract, sha256: sha, installedBy: installer,
                                              source: payload.source, checkout: payload.checkout,
                                              appVersion: payload.appVersion, installedAt: now)
                    try record.write(home: home)
                }
                return .alreadyCurrent(record)
            case .keep:
                return .keptExisting(existing!)
            case .install:
                try policy.check(source)
                try place(source, at: home.serverBinary, mode: 0o755)
                if let metallib = payload.metallib {
                    try place(metallib.resolvingSymlinksInPath(), at: home.metallib, mode: 0o644)
                }
                let record = AIIInstallRecord(contract: payload.contract, sha256: sha, installedBy: installer,
                                              source: payload.source, checkout: payload.checkout,
                                              appVersion: payload.appVersion, installedAt: now)
                try record.write(home: home)
                try writeEnvironmentIfMissing(payload.publicEnvironment)
                return .installed(record, replaced: existing)
            }
        }
    }

    /// The person's own build from an AII checkout, already built: installed as the
    /// stack, whatever is there, never signature-checked. `local`, naming the checkout.
    @discardableResult
    public func installLocal(from checkout: URL, configuration: String = "release", now: Date = Date()) throws -> AIIInstallOutcome {
        guard let payload = AIIInstallPayload.checkout(checkout, configuration: configuration) else {
            throw AIIInstallError.notBuilt(PrivateFile.path(checkout.appendingPathComponent(".build/\(configuration)")))
        }
        return try installIfNeeded(payload, by: .stack, policy: .unchecked, now: now)
    }

    /// Removes the installed binary, its Metal library and install.json, so the next app
    /// to launch installs its own. Data, models, secrets and aii.env stay.
    public func uninstall() throws {
        try PrivateFile.ensureDirectory(home.aiiDirectory)
        try PrivateFile.withExclusiveLock(home.aiiInstallLockFile) {
            for file in [home.serverBinary, home.metallib, home.aiiInstallRecord] where PrivateFile.exists(file) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Throws unless the installed AIIServer is what install.json says, is trusted by its
    /// source's rule, and — for an app on the person's build — speaks the app's contract.
    /// Run before every exec of it.
    public func verifyInstalled(as identity: StackIdentity = .stack) throws {
        guard let record = installedRecord() else { throw AIIInstallError.notInstalled }
        let binary = home.serverBinary
        let found = try FileDigest.sha256(of: binary)
        guard found == record.sha256 else {
            throw AIIInstallError.modified(expected: record.sha256, found: found)
        }
        switch record.source {
        case .bundled:
            try policy.check(binary)
        case .local:
            try verifyLocalRecord()
            if let gap = contractGap(record, for: identity) { throw gap }
        }
    }

    /// Why `identity` can't run what is installed, from the record alone: cheap enough
    /// for every status update. Nil when nothing stands in the way that the record shows.
    public func installProblem(as identity: StackIdentity) -> String? {
        guard let record = installedRecord() else { return nil }
        return contractGap(record, for: identity)?.description
    }

    private func contractGap(_ record: AIIInstallRecord, for identity: StackIdentity) -> AIIInstallError? {
        guard case .app(let app) = identity, record.source == .local, record.contract < AIIContract.version else { return nil }
        return .localBuildBehind(installed: record.contract, needed: AIIContract.version, app: app.displayName(in: home))
    }

    private func verifyLocalRecord() throws {
        let file = home.aiiInstallRecord
        guard let found = PrivateFile.ownerAndMode(file), found.isRegularFile,
              found.uid == geteuid(), found.mode == 0o600 else {
            throw AIIInstallError.untrustedRecord(PrivateFile.path(file))
        }
    }

    // MARK: - Building

    /// Runs `Scripts/build-servers.sh <configuration>` in `checkout`, handing each line of
    /// its output to `line`. True when it exited 0. `aii install` and Ambient's Rebuild
    /// both build through here.
    public static func build(checkout: URL, configuration: String,
                             line: @escaping @Sendable (String) -> Void) async -> Bool {
        let script = checkout.appendingPathComponent("Scripts/build-servers.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [PrivateFile.path(script), configuration]
        process.currentDirectoryURL = checkout
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            line("error: \(script.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        do {
            for try await text in pipe.fileHandleForReading.bytes.lines { line(text) }
        } catch {
            line("error: reading \(script.lastPathComponent)'s output: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            line("error: \(script.lastPathComponent) exited with status \(process.terminationStatus)")
            return false
        }
        return true
    }

    // MARK: - Files

    /// Each public value lands only where aii.env has none: a pair typed into `aii setup`
    /// or `aii keys supabase` survives an install. An app that wants its own values to
    /// win writes them itself (Ambient does, from its bundle).
    private func writeEnvironmentIfMissing(_ values: [String: String]) throws {
        guard !values.isEmpty else { return }
        try AIIEnvironmentFile.update(home: home) { current in
            for (key, value) in values where current[key] == nil { current[key] = value }
        }
    }

    /// Copies `source` beside `destination` and renames it into place.
    private func place(_ source: URL, at destination: URL, mode: mode_t) throws {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(getpid()).\(UInt32.random(in: .min ... .max)).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: temp)
        } catch {
            throw AIIInstallError.copyFailed("\(error.localizedDescription)")
        }
        let tempPath = PrivateFile.path(temp)
        _ = chmod(tempPath, mode)
        _ = removexattr(tempPath, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard rename(tempPath, PrivateFile.path(destination)) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(tempPath)
            throw AIIInstallError.copyFailed("rename: \(reason)")
        }
    }
}
#endif
