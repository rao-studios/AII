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
//  OUT:  A home; which of its servers a port is; whether it runs, can be started, and
//        where it logs; a stop; a start (ManagedServer.relaunch). Plain values: AII's own
//        types, nothing of this helper's.
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
    // MARK: - Finding

    /// The home whose server listens on `port`, when exactly one process listens there,
    /// it runs in `<home>/aii`, and that home's records name the port.
    public static func locate(port: Int) -> AIIHome? {
        let pids = ProcessProbe.listeningPIDs(port: port)
        guard pids.count == 1, let pid = pids.first else { return nil }
        return locate(port: port, pid: pid, workingDirectory: ProcessProbe.workingDirectory(of: pid))
    }

    /// `locate` once the listening process and where it runs are known.
    static func locate(port: Int, pid: pid_t, workingDirectory: String?) -> AIIHome? {
        guard let workingDirectory else { return nil }
        let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        guard directory.lastPathComponent == "aii" else { return nil }
        let home = AIIHome(root: directory.deletingLastPathComponent())
        let recorded = LaunchSpec.Role.allCases.contains { role in
            guard let record = RunRecord.load(home.runRecord(for: role)) else { return false }
            return record.process.pid == pid && record.ports.http == port
        }
        // Started without a run record left behind (adopted by port, say): its launch says the port.
        return recorded || role(home: home, port: port) != nil ? home : nil
    }

    /// Which of `home`'s servers listens on `port`, by its run record or its launch record.
    public static func role(home: AIIHome, port: Int) -> LaunchSpec.Role? {
        LaunchSpec.Role.allCases.first { role in
            RunRecord.load(home.runRecord(for: role))?.ports.http == port
                || LaunchRecord.load(home.launchRecord(for: role))?.ports.http == port
        }
    }

    /// The process `home`'s run record names for its server on `port`, while that process
    /// runs as the binary recorded.
    public static func running(home: AIIHome, port: Int) -> ProcessStamp? {
        guard let role = role(home: home, port: port), let record = RunRecord.load(home.runRecord(for: role)),
              record.ports.http == port, ProcessProbe.isRunning(record.process),
              ProcessProbe.executablePath(of: record.process.pid) == record.binary else { return nil }
        return record.process
    }

    /// A launch record names `port`: `start` can replay it.
    public static func startable(home: AIIHome, port: Int) -> Bool {
        launch(home: home, port: port) != nil
    }

    /// Where `home`'s server on `port` writes what it says, as its launch record names it.
    public static func log(home: AIIHome, port: Int) -> String? {
        launch(home: home, port: port)?.logFile
    }

    /// The launch record of `home`'s server on `port`.
    private static func launch(home: AIIHome, port: Int) -> LaunchRecord? {
        guard let role = role(home: home, port: port), let record = LaunchRecord.load(home.launchRecord(for: role)),
              record.ports.http == port else { return nil }
        return record
    }

    // MARK: - Stopping and starting

    /// Stops `home`'s server on `port`: SIGTERM to the process its run record names, SIGKILL
    /// after `grace`. Returns whether something was stopped.
    @discardableResult
    public static func stop(home: AIIHome, port: Int, grace: TimeInterval = 15, lockWait: TimeInterval = 10) async throws -> Bool {
        guard let role = role(home: home, port: port), running(home: home, port: port) != nil else { return false }
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
