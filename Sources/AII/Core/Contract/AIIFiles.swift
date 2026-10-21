//
//  AIIFiles.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The small files that describe the Ambient Intelligence Index and who is
//        using it: its optional config, its install record, its environment file,
//        the run records launchers leave for each server, and the leases apps
//        hold while they need the stack.
//  IN:   Launchers (write), Sewn (reads aii.env), every app (reads).
//  OUT:  Agreement between apps on where the servers listen, what is installed,
//        who started what, and whether anyone else still needs the stack.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - config.json

/// Optional overrides for the two servers. Nothing writes this by default; a
/// missing or unreadable file means the contract's defaults.
///
///     { "sewn": { "httpPort": …, "grpcPort": …, "dataDir": "…" },
///       "thread": { "httpPort": …, "grpcPort": …, "dataDir": "…", "graphBackend": "mlx" } }
public struct AIIConfig: Codable, Sendable, Equatable {
    public struct Server: Codable, Sendable, Equatable {
        public var httpPort: Int?
        public var grpcPort: Int?
        /// The server's data directory; `~` is expanded. Default under AII_HOME/aii.
        /// For Thread this is the one index, wherever the person puts it (an
        /// external drive, say) — never one per app.
        public var dataDir: String?
        /// Thread only: `--graph-backend mlx|mistral|keyword`. Process-wide, so
        /// it is a stack setting, not an app's.
        public var graphBackend: String?

        public init(httpPort: Int? = nil, grpcPort: Int? = nil, dataDir: String? = nil, graphBackend: String? = nil) {
            self.httpPort = httpPort
            self.grpcPort = grpcPort
            self.dataDir = dataDir
            self.graphBackend = graphBackend
        }
    }

    public var sewn: Server
    public var thread: Server
    // No models folder here: HF_HOME is always AII_HOME/models/huggingface, where
    // every Rao app keeps its models.

    public init(sewn: Server = Server(), thread: Server = Server()) {
        self.sewn = sewn
        self.thread = thread
    }

    public static func load(from url: URL) -> AIIConfig {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else { return AIIConfig() }
        return (try? JSONDecoder().decode(AIIConfig.self, from: data)) ?? AIIConfig()
    }

    public static func load(home: AIIHome) -> AIIConfig { load(from: home.aiiConfigFile) }

    public func write(home: AIIHome) throws {
        try PrivateFile.ensureDirectory(home.aiiDirectory)
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(self), to: home.aiiConfigFile, mode: 0o600)
    }

    public var sewnPorts: AIIPorts {
        AIIPorts(http: sewn.httpPort ?? AIIPortPlan.sewn.http, grpc: sewn.grpcPort ?? AIIPortPlan.sewn.grpc)
    }

    public var threadPorts: AIIPorts {
        AIIPorts(http: thread.httpPort ?? AIIPortPlan.thread.http, grpc: thread.grpcPort ?? AIIPortPlan.thread.grpc)
    }

    public func sewnDataDirectory(home: AIIHome) -> URL {
        guard let dataDir = sewn.dataDir, !dataDir.isEmpty else { return home.sewnDataDirectory }
        return URL(fileURLWithPath: AIIHome.expandTilde(dataDir), isDirectory: true)
    }

    public func threadDataDirectory(home: AIIHome) -> URL {
        guard let dataDir = thread.dataDir, !dataDir.isEmpty else { return home.threadDataDirectory }
        return URL(fileURLWithPath: AIIHome.expandTilde(dataDir), isDirectory: true)
    }

    public func ports(for role: LaunchSpec.Role) -> AIIPorts {
        switch role {
        case .sewn: return sewnPorts
        case .thread: return threadPorts
        }
    }
}

// MARK: - install.json

/// Where the installed AIIServer came from.
public enum AIIInstallSource: String, Codable, Sendable {
    /// A Rao app's signed helper, from its bundle's Contents/Helpers.
    case bundled
    /// The person's own build, from an AII checkout (`aii install`). Every app keeps it.
    case local
}

/// The checkout a local build came from, so `aii update` and `aii status` can find it again.
public struct AIICheckoutRecord: Codable, Sendable, Equatable {
    /// The checkout's root, resolved.
    public var path: String
    /// Its commit, 12 hex characters, with `-dirty` when the tree had changes; `unknown`
    /// when git couldn't say.
    public var commit: String
    /// `debug` or `release`.
    public var configuration: String

    public init(path: String, commit: String, configuration: String) {
        self.path = path
        self.commit = commit
        self.configuration = configuration
    }
}

/// What sits in AII_HOME/aii/bin — AIIServer — and who put it there.
public struct AIIInstallRecord: Codable, Sendable, Equatable {
    public var contract: Int
    public var sha256: String
    /// An app for a bundled build; the stack (`aii`) for the person's own.
    public var installedBy: StackIdentity
    public var source: AIIInstallSource
    /// For a local build: the checkout it was built from.
    public var checkout: AIICheckoutRecord?
    /// Free text: "Ambient 1.0.0 (1) e093af71e523", or "AII 256e699a1c0f" for a local build.
    public var appVersion: String
    public var installedAt: Date

    public init(contract: Int, sha256: String, installedBy: StackIdentity, source: AIIInstallSource,
                checkout: AIICheckoutRecord? = nil, appVersion: String, installedAt: Date) {
        self.contract = contract
        self.sha256 = sha256
        self.installedBy = installedBy
        self.source = source
        self.checkout = checkout
        self.appVersion = appVersion
        self.installedAt = installedAt
    }

    /// One line for any status: whose build this is.
    public var summary: String {
        switch source {
        case .local:
            guard let checkout else { return "Your build (\(appVersion))" }
            return "Your build @ \(checkout.commit) from \(checkout.path)"
        case .bundled:
            return "Installed by \(appVersion)"
        }
    }

    public static func load(home: AIIHome) -> AIIInstallRecord? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(home.aiiInstallRecord)) else { return nil }
        return try? AIIHome.decoder.decode(AIIInstallRecord.self, from: data)
    }

    public func write(home: AIIHome) throws {
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(self), to: home.aiiInstallRecord, mode: 0o600)
    }
}

// MARK: - Run records and leases

/// A process, named so that a recycled pid can't pass for it: its pid and
/// when it started (microseconds since 1970). A nil start means the launcher
/// couldn't read it; the pid alone is then trusted.
public struct ProcessStamp: Codable, Sendable, Hashable {
    public var pid: Int32
    public var processStart: UInt64?

    public init(pid: Int32, processStart: UInt64?) {
        self.pid = pid
        self.processStart = processStart
    }
}

/// What a launcher leaves beside a server it started: enough for the next
/// launcher, in this app or another, to decide whether that process is still
/// the one it claims to be.
public struct RunRecord: Codable, Sendable, Equatable {
    public struct Launcher: Codable, Sendable, Equatable {
        /// The app, or the stack (`aii`), whose launcher started it.
        public var identity: StackIdentity
        public var process: ProcessStamp

        public init(identity: StackIdentity, process: ProcessStamp) {
            self.identity = identity
            self.process = process
        }
    }

    public var process: ProcessStamp
    /// The executable it runs, resolved.
    public var binary: String
    public var ports: AIIPorts
    public var launcher: Launcher?
    public var startedAt: Date

    public init(process: ProcessStamp, binary: String, ports: AIIPorts, launcher: Launcher?, startedAt: Date) {
        self.process = process
        self.binary = binary
        self.ports = ports
        self.launcher = launcher
        self.startedAt = startedAt
    }

    public static func load(_ url: URL) -> RunRecord? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else { return nil }
        return try? AIIHome.decoder.decode(RunRecord.self, from: data)
    }

    public func write(_ url: URL) throws {
        try PrivateFile.ensureDirectory(url.deletingLastPathComponent())
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(self), to: url, mode: 0o600)
    }

    public static func remove(_ url: URL) {
        unlink(PrivateFile.path(url))
    }
}

/// An app, or the stack itself, saying "I still need the stack". Live while its process
/// is; a pinned lease (the aii command's) lasts until it is released.
public struct AIILease: Codable, Sendable, Equatable {
    public var identity: StackIdentity
    public var process: ProcessStamp
    public var pinned: Bool
    public var acquiredAt: Date

    public init(identity: StackIdentity, process: ProcessStamp, pinned: Bool = false, acquiredAt: Date) {
        self.identity = identity
        self.process = process
        self.pinned = pinned
        self.acquiredAt = acquiredAt
    }
}

// MARK: - Environment files

/// `KEY=value` files: `#` comments, blank lines, optional `export `, quotes
/// stripped. The shape Sewn's and Thread's `.env` loaders read.
public enum EnvFile {

    public static func parse(_ contents: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            pairs.append((key, value))
        }
        return pairs
    }

    public static func read(_ url: URL) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else { return [:] }
        var values: [String: String] = [:]
        for pair in parse(String(decoding: data, as: UTF8.self)) { values[pair.key] = pair.value }
        return values
    }

    /// Sets each variable from `url` in this process — unless it is already
    /// set (with `overwrite` false) or `denying` names it. Returns the keys
    /// applied.
    @discardableResult
    public static func apply(_ url: URL, overwrite: Bool = false, denying: Set<String> = []) -> [String] {
        var applied: [String] = []
        for (key, value) in read(url).sorted(by: { $0.key < $1.key }) where !denying.contains(key) {
            if setenv(key, value, overwrite ? 1 : 0) == 0 { applied.append(key) }
        }
        return applied
    }
}

/// AII_HOME/aii/aii.env: the stack's public configuration — the Supabase project
/// an app with accounts ships with — written by the installing app or the aii
/// command, read by Sewn at start.
public enum AIIEnvironmentFile {
    /// All a writer may put there.
    public static let allowedKeys: Set<String> = ["SUPABASE_URL", "SUPABASE_ANON_KEY"]
    /// Never taken from it, whatever it says: secrets and keys have homes of
    /// their own (the provider keys: keys/providers.json).
    public static let deniedKeys: Set<String> = Set([AIIHome.environmentKey]).union(ProviderKeyStore.sharedKeyNames)

    public enum WriteError: Error, Equatable, CustomStringConvertible {
        case disallowedKeys([String])

        public var description: String {
            switch self {
            case .disallowedKeys(let keys): return "aii.env may not hold \(keys.joined(separator: ", ")): SUPABASE_URL and SUPABASE_ANON_KEY only"
            }
        }
    }

    public static func write(_ values: [String: String], to url: URL) throws {
        let disallowed = values.keys.filter { !allowedKeys.contains($0) }.sorted()
        guard disallowed.isEmpty else { throw WriteError.disallowedKeys(disallowed) }
        var lines = ["# Written by a Rao app or the aii command. Public values only."]
        for key in values.keys.sorted() {
            lines.append("\(key)=\(values[key]!)")
        }
        try PrivateFile.ensureDirectory(url.deletingLastPathComponent())
        try PrivateFile.writeAtomically(Data((lines.joined(separator: "\n") + "\n").utf8), to: url, mode: 0o600)
    }

    /// Read → keep the allowed keys → `change` → drop empty values → write (0600), or
    /// remove the file when nothing is left. Under aii/.aii.env.lock, so two writers
    /// merge instead of clobbering. True when the file changed.
    @discardableResult
    public static func update(home: AIIHome, _ change: (inout [String: String]) throws -> Void) throws -> Bool {
        try PrivateFile.ensureDirectory(home.aiiDirectory)
        return try PrivateFile.withExclusiveLock(home.aiiEnvLockFile) {
            let before = EnvFile.read(home.aiiEnvFile).filter { allowedKeys.contains($0.key) && !$0.value.isEmpty }
            var values = before
            try change(&values)
            values = values.filter { !$0.value.isEmpty }
            let disallowed = values.keys.filter { !allowedKeys.contains($0) }.sorted()
            guard disallowed.isEmpty else { throw WriteError.disallowedKeys(disallowed) }
            guard values != before else { return false }
            if values.isEmpty {
                if PrivateFile.exists(home.aiiEnvFile) { try FileManager.default.removeItem(at: home.aiiEnvFile) }
                return true
            }
            try write(values, to: home.aiiEnvFile)
            return true
        }
    }
}
