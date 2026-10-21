//
//  AIIHome.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where the shared stack lives: one hidden directory per user, ~/.rao,
//        holding the Ambient Intelligence Index — one Sewn and one Thread for
//        every app, with the index in lanes — each app's secret, the stack's
//        own, the device key, and the provider keys the user gave any of them.
//  IN:   AII_HOME (a launcher's override, and how tests and dev runs use a
//        scratch home); otherwise the user's home directory.
//  OUT:  Every path the apps and the servers read or write. Nothing outside
//        this file spells a path under ~/.rao.
//  PIN:  Two entry points on purpose. Apps call `resolved()` and always get a
//        home. Servers call `fromEnvironment()` and get one only when their
//        launcher set AII_HOME — a hosted Sewn that happens to run as a user
//        with a ~/.rao must not change how it behaves.
//
//        ~/.rao/                               layout 1
//          layout.json
//          secrets/<identity>                  0600, 64 hex: every app's, and the stack's (aii)
//          keys/providers.json                 0600
//          keys/device.key                     0600, 64 hex — the Rao device key
//          keys/device-<fingerprint>.key       an earlier device key, kept
//          bin/aii, bin/aii.json               the aii command and the checkout it was built from
//          aii/bin/{AIIServer,mlx.metallib}
//          aii/{install.json,aii.env,config.json}, aii/.aii.env.lock
//          aii/lanes.json                      the lanes manifest (aii-lanes/1): every app's lane
//          aii/sewn/db/                        Sewn's own data
//          aii/thread/db/                      the one index, every app a lane
//          aii/run/{sewn.json,thread.json,sewn.log,thread.log,start.lock}
//          aii/leases/<identity>.json, <identity>.pinned.json
//          apps/<app>/                         an app's private data (Craft's index, projects, evals)
//          models/huggingface/
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct AIIHome: Sendable, Hashable, CustomStringConvertible {
    public static let environmentKey = "AII_HOME"
    public static let directoryName = ".rao"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var description: String { PrivateFile.path(root) }

    // MARK: - Finding the home

    /// For servers: the home their launcher named in AII_HOME, or nil when it
    /// named none. Throws for a value that isn't an absolute path (after `~`).
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AIIHome? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let expanded = expandTilde(raw)
        guard expanded.hasPrefix("/") else { throw AIIHomeError.notAbsolute(raw) }
        return AIIHome(root: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    /// For apps: AII_HOME when it names an absolute path, otherwise ~/.rao.
    public static func resolved(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AIIHome {
        if let home = try? fromEnvironment(environment) { return home }
        return AIIHome(root: userHomeDirectory.appendingPathComponent(directoryName, isDirectory: true))
    }

    /// The user's real home directory from the password database, so a
    /// sandbox container or a stray $HOME can't move the shared stack.
    public static var userHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~` and `~/…` against the user's home; anything else unchanged.
    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return PrivateFile.path(userHomeDirectory) }
        if path.hasPrefix("~/") {
            return PrivateFile.path(userHomeDirectory) + String(path.dropFirst(1))
        }
        return path
    }

    // MARK: - Layout

    public var layoutFile: URL { root.appendingPathComponent("layout.json") }

    // Secrets: one per identity — every registered app and the stack itself.
    public var secretsDirectory: URL { root.appendingPathComponent("secrets", isDirectory: true) }
    public func secretFile(for identity: StackIdentity) -> URL { secretsDirectory.appendingPathComponent(identity.fileName) }
    public func secretFile(for app: AIIApp) -> URL { secretFile(for: .app(app)) }

    // Keys: the provider keys the user typed or an account gave, and the device key.
    public var keysDirectory: URL { root.appendingPathComponent("keys", isDirectory: true) }
    public var providersFile: URL { keysDirectory.appendingPathComponent("providers.json") }
    public var providersLockFile: URL { keysDirectory.appendingPathComponent(".providers.lock") }
    public var deviceKeyFile: URL { keysDirectory.appendingPathComponent("device.key") }
    /// An earlier device key, kept under its fingerprint when a new one was made.
    public func keptDeviceKeyFile(fingerprint: String) -> URL { keysDirectory.appendingPathComponent("device-\(fingerprint).key") }

    // The Ambient Intelligence Index: the two servers, their files, their data, their run state.
    public var aiiDirectory: URL { root.appendingPathComponent("aii", isDirectory: true) }
    public var aiiBinDirectory: URL { aiiDirectory.appendingPathComponent("bin", isDirectory: true) }
    /// The one binary, run as `AIIServer sewn …` and `AIIServer thread …`.
    public var serverBinary: URL { aiiBinDirectory.appendingPathComponent(LaunchSpec.executableName) }
    public var metallib: URL { aiiBinDirectory.appendingPathComponent("mlx.metallib") }
    public var aiiInstallRecord: URL { aiiDirectory.appendingPathComponent("install.json") }
    public var aiiInstallLockFile: URL { aiiDirectory.appendingPathComponent(".install.lock") }
    public var aiiEnvFile: URL { aiiDirectory.appendingPathComponent("aii.env") }
    /// Held while aii.env is read and rewritten, so two writers merge.
    public var aiiEnvLockFile: URL { aiiDirectory.appendingPathComponent(".aii.env.lock") }
    public var aiiConfigFile: URL { aiiDirectory.appendingPathComponent("config.json") }
    public var lanesFile: URL { aiiDirectory.appendingPathComponent("lanes.json") }
    /// Held while lanes.json gains or loses an app.
    public var lanesLockFile: URL { aiiDirectory.appendingPathComponent(".lanes.lock") }
    public var sewnDataDirectory: URL { aiiDirectory.appendingPathComponent("sewn", isDirectory: true).appendingPathComponent("db", isDirectory: true) }
    public var threadDataDirectory: URL { aiiDirectory.appendingPathComponent("thread", isDirectory: true).appendingPathComponent("db", isDirectory: true) }
    public var aiiRunDirectory: URL { aiiDirectory.appendingPathComponent("run", isDirectory: true) }
    public var sewnRunRecord: URL { aiiRunDirectory.appendingPathComponent("sewn.json") }
    public var threadRunRecord: URL { aiiRunDirectory.appendingPathComponent("thread.json") }
    public var sewnLogFile: URL { aiiRunDirectory.appendingPathComponent("sewn.log") }
    public var threadLogFile: URL { aiiRunDirectory.appendingPathComponent("thread.log") }
    /// Held by whichever launcher is starting or stopping a server, in any app.
    public var startLockFile: URL { aiiRunDirectory.appendingPathComponent("start.lock") }
    public var aiiLeasesDirectory: URL { aiiDirectory.appendingPathComponent("leases", isDirectory: true) }
    public func aiiLease(for identity: StackIdentity) -> URL { aiiLeasesDirectory.appendingPathComponent("\(identity.rawValue).json") }
    public func aiiLease(for app: AIIApp) -> URL { aiiLease(for: .app(app)) }
    /// A pinned lease (the aii command's, a dev script's): held until released, whatever process wrote it.
    public func aiiPinnedLease(for identity: StackIdentity) -> URL { aiiLeasesDirectory.appendingPathComponent("\(identity.rawValue).pinned.json") }
    public func aiiPinnedLease(for app: AIIApp) -> URL { aiiPinnedLease(for: .app(app)) }

    // An app's own files, beside the index: Craft's code index, projects and evals live here.
    public var appsDirectory: URL { root.appendingPathComponent("apps", isDirectory: true) }
    public func appDirectory(_ app: AIIApp) -> URL { appsDirectory.appendingPathComponent(app.rawValue, isDirectory: true) }

    // The aii command, installed by Scripts/install-cli.sh.
    public var cliDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var cliBinary: URL { cliDirectory.appendingPathComponent("aii") }
    /// The checkout the installed aii was built from, written beside it by Scripts/install-cli.sh.
    public var cliRecord: URL { cliDirectory.appendingPathComponent("aii.json") }

    public var modelsDirectory: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var huggingFaceHome: URL { modelsDirectory.appendingPathComponent("huggingface", isDirectory: true) }

}

public enum AIIHomeError: Error, Equatable, CustomStringConvertible {
    case notAbsolute(String)
    case missing(String)
    case missingSecret(StackIdentity)
    case malformedSecret(StackIdentity)
    case duplicateSecret([StackIdentity])
    case invalidAppName(String)
    case reservedName(String)
    case invalidOwner(String, app: String)

    public var description: String {
        switch self {
        case .notAbsolute(let value): return "AII_HOME must be an absolute path, got \"\(value)\""
        case .missing(let path): return "\(path) does not exist — a Rao app provisions it on first launch"
        case .missingSecret(let identity): return "no secret for \(identity.rawValue) in AII_HOME/secrets"
        case .malformedSecret(let identity): return "secrets/\(identity.rawValue) is not 64 hex characters"
        case .duplicateSecret(let identities): return "identities share one secret: \(identities.map(\.rawValue).joined(separator: ", "))"
        case .invalidAppName(let name): return "\"\(name)\" is not an app name: 2 to 32 of a-z and 0-9, starting with a letter"
        case .reservedName(let name): return "\"\(name)\" is the stack's own name, never an app's"
        case .invalidOwner(let owner, let app): return "\"\(owner)\" can't own \(app)'s lane: aii-local or local-\(app)"
        }
    }
}
