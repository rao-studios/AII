//
//  AIILocal.swift
//  AII
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The server of some AII home on this Mac, known by the port it listens on:
//        which home it belongs to, whether it runs, whether it can be started
//        again, and stopping or starting it — for any app that found an AII by its
//        port and is asked by the person to stop, start or restart it.
//  IN:   A port (locate), or a home and a port (the rest).
//  OUT:  A home and a role; a status; a stop; a start (ManagedServer.relaunch).
//  PIN:  NO SECRET ANYWHERE. A home is found by the listening process's working
//        directory (every launch runs in `<home>/aii`) and confirmed by that home's
//        own records; a stop signals the process the run record names, checked by
//        its start time and binary; a start replays the launch record. Nothing here
//        reads a secret, takes a lease or challenges a server.
//  PIN:  ONLY WHAT A LAUNCHER STARTED. A home is one whose records name the port;
//        a start needs the launch record a spawn left. A process nobody recorded is
//        never signalled from here.
//

#if os(macOS)
import Darwin
import Foundation

public enum AIILocal {
    /// A server of an AII home.
    public struct Server: Sendable, Equatable {
        public var home: AIIHome
        public var role: LaunchSpec.Role

        public init(home: AIIHome, role: LaunchSpec.Role) {
            self.home = home
            self.role = role
        }
    }

    /// What a home says of its server on a port.
    public struct Status: Sendable, Equatable {
        /// Which of the home's servers the port is, when its records say.
        public var role: LaunchSpec.Role?
        /// The process its run record names, while that process runs.
        public var running: ProcessStamp?
        /// A launch record names the port: it can be started again.
        public var startable: Bool

        public init(role: LaunchSpec.Role?, running: ProcessStamp?, startable: Bool) {
            self.role = role
            self.running = running
            self.startable = startable
        }
    }

    // MARK: - Finding

    /// The home whose server listens on `port`, when exactly one process listens there,
    /// it runs in `<home>/aii`, and that home's records name the port.
    public static func locate(port: Int) -> Server? {
        let pids = ProcessProbe.listeningPIDs(port: port)
        guard pids.count == 1, let pid = pids.first else { return nil }
        return locate(port: port, pid: pid, workingDirectory: ProcessProbe.workingDirectory(of: pid))
    }

    /// `locate` once the listening process and where it runs are known.
    static func locate(port: Int, pid: pid_t, workingDirectory: String?) -> Server? {
        guard let workingDirectory else { return nil }
        let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        guard directory.lastPathComponent == "aii" else { return nil }
        let home = AIIHome(root: directory.deletingLastPathComponent())
        for role in LaunchSpec.Role.allCases {
            if let record = RunRecord.load(home.runRecord(for: role)), record.process.pid == pid, record.ports.http == port {
                return Server(home: home, role: role)
            }
        }
        // Started without a run record left behind (adopted by port, say): its launch says the port.
        guard let role = role(home: home, port: port) else { return nil }
        return Server(home: home, role: role)
    }

    /// Which of `home`'s servers listens on `port`, by its run record or its launch record.
    public static func role(home: AIIHome, port: Int) -> LaunchSpec.Role? {
        LaunchSpec.Role.allCases.first { role in
            RunRecord.load(home.runRecord(for: role))?.ports.http == port
                || LaunchRecord.load(home.launchRecord(for: role))?.ports.http == port
        }
    }

    /// What `home` says of its server on `port`.
    public static func status(home: AIIHome, port: Int) -> Status {
        guard let role = role(home: home, port: port) else { return Status(role: nil, running: nil, startable: false) }
        let running = RunRecord.load(home.runRecord(for: role)).flatMap { record -> ProcessStamp? in
            guard record.ports.http == port, ProcessProbe.isRunning(record.process),
                  ProcessProbe.executablePath(of: record.process.pid) == record.binary else { return nil }
            return record.process
        }
        let startable = LaunchRecord.load(home.launchRecord(for: role))?.ports.http == port
        return Status(role: role, running: running, startable: startable)
    }

    // MARK: - Stopping and starting

    /// Stops `home`'s server on `port`: SIGTERM to the process its run record names, SIGKILL
    /// after `grace`. Returns whether something was stopped.
    @discardableResult
    public static func stop(home: AIIHome, port: Int, grace: TimeInterval = 15, lockWait: TimeInterval = 10) async throws -> Bool {
        guard let role = role(home: home, port: port), status(home: home, port: port).running != nil else { return false }
        let runRecord = home.runRecord(for: role)
        try await withStartLock(beside: runRecord, wait: lockWait) {
            ManagedServer.stopRecordedSync(runRecord, grace: grace)
        }
        return true
    }

    /// Starts `home`'s server on `port` as it was last launched, recorded as `launcher`'s.
    /// Returns once the process runs; the caller asks /health for when it answers.
    public static func start(home: AIIHome, port: Int, launcher: StackIdentity,
                             inherited: [String: String] = ProcessInfo.processInfo.environment) async throws -> ProcessStamp {
        let role = role(home: home, port: port) ?? .thread
        return try await ManagedServer.relaunch(launchRecord: home.launchRecord(for: role), launcher: launcher, inherited: inherited)
    }

    /// `body` under the start lock beside `runRecord`, waited for up to `wait` seconds.
    private static func withStartLock(beside runRecord: URL, wait: TimeInterval, _ body: () -> Void) async throws {
        let lockFile = runRecord.deletingLastPathComponent().appendingPathComponent("start.lock")
        try PrivateFile.ensureDirectory(lockFile.deletingLastPathComponent())
        let lock = try FileLock(lockFile)
        let deadline = Date().addingTimeInterval(wait)
        while !lock.tryLock() {
            guard Date() < deadline else { throw RelaunchError.busy }
            try await Task.sleep(for: .milliseconds(200))
        }
        defer { lock.unlock() }
        body()
    }
}
#endif
