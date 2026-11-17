//
//  LaunchRecord.swift
//  AII
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: How a server was last launched: the binary, its arguments, its working
//        directory, the environment it was given, where it logs and where its run
//        record goes — written beside the run record by the launcher that spawned
//        it, and kept after the server stops, so a server can be started again the
//        way its launcher started it, by anyone on this Mac (ManagedServer.relaunch).
//  IN:   ManagedServer.spawn (write).
//  OUT:  ManagedServer.relaunch, AIILocal (read).
//  PIN:  NOTHING SECRET. argv is never secret already (LaunchSpec's PIN); the
//        environment is kept without any name that reads like a credential
//        (`recordable`), and the server reads its secrets from its home, as it
//        always does. Mode 0600 all the same.
//  PIN:  KEPT AFTER A STOP, unlike the run record: a run record says what runs,
//        this says how to run it again. A launch replaces it; removing the home
//        removes it.
//

import Foundation

public struct LaunchRecord: Codable, Sendable, Equatable {
    public var role: LaunchSpec.Role
    /// The executable, as the launcher named it.
    public var binary: String
    public var arguments: [String]
    public var workingDirectory: String
    /// The environment it was given, without any credential-like name.
    public var environment: [String: String]
    public var ports: AIIPorts
    public var runRecord: String
    public var logFile: String
    /// The identity whose launcher wrote it.
    public var launcher: StackIdentity?
    public var recordedAt: Date

    public init(role: LaunchSpec.Role, binary: String, arguments: [String], workingDirectory: String,
                environment: [String: String], ports: AIIPorts, runRecord: String, logFile: String,
                launcher: StackIdentity?, recordedAt: Date) {
        self.role = role
        self.binary = binary
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.ports = ports
        self.runRecord = runRecord
        self.logFile = logFile
        self.launcher = launcher
        self.recordedAt = recordedAt
    }

    /// What `spec` launches, as a record.
    public init(spec: LaunchSpec, launcher: StackIdentity?, recordedAt: Date = Date()) {
        self.init(role: spec.role, binary: PrivateFile.path(spec.executable), arguments: spec.arguments,
                  workingDirectory: PrivateFile.path(spec.workingDirectory),
                  environment: Self.recordable(spec.environment), ports: spec.ports,
                  runRecord: PrivateFile.path(spec.runRecord), logFile: PrivateFile.path(spec.logFile),
                  launcher: launcher, recordedAt: recordedAt)
    }

    /// The launch again, as a spec: the recorded environment over `inherited` (the
    /// relauncher's own, filtered as every launch filters it). Challenged as no one:
    /// a relaunch confirms its server with the keyless /health.
    public func spec(inherited: [String: String]) -> LaunchSpec {
        var environment = LaunchSpecs.inherited(inherited)
        environment.merge(self.environment) { _, recorded in recorded }
        return LaunchSpec(role: role, executable: URL(fileURLWithPath: binary), arguments: arguments,
                          environment: environment, workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
                          ports: ports, runRecord: URL(fileURLWithPath: runRecord), logFile: URL(fileURLWithPath: logFile),
                          challenge: nil)
    }

    // MARK: - What is kept

    /// Name endings that read like a credential: never written down.
    static let credentialSuffixes = ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD"]

    static func isRecordable(_ name: String) -> Bool {
        let upper = name.uppercased()
        return !credentialSuffixes.contains { upper.hasSuffix($0) }
    }

    /// `environment` without any credential-like name.
    public static func recordable(_ environment: [String: String]) -> [String: String] {
        environment.filter { isRecordable($0.key) }
    }

    // MARK: - The file

    /// Beside a run record: `thread.json` → `thread.launch.json`.
    public static func url(beside runRecord: URL) -> URL {
        runRecord.deletingLastPathComponent()
            .appendingPathComponent(runRecord.deletingPathExtension().lastPathComponent + ".launch.json")
    }

    public static func load(_ url: URL) -> LaunchRecord? {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(url)) else { return nil }
        return try? AIIHome.decoder.decode(LaunchRecord.self, from: data)
    }

    public func write(_ url: URL) throws {
        try PrivateFile.ensureDirectory(url.deletingLastPathComponent())
        try PrivateFile.writeAtomically(try AIIHome.encoder.encode(self), to: url, mode: 0o600)
    }
}
