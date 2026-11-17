//
//  ManagedServer+Relaunch.swift
//  AII
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A stopped server started again the way its launcher last started it, by
//        anyone on this Mac: the launch record replayed, in a session of its own,
//        and a fresh run record left for every other launcher.
//  IN:   A LaunchRecord (written by every spawn), the relauncher's identity and
//        environment.
//  OUT:  The new process's stamp, once its executable has settled (`settle`). The
//        server is NOT waited for: a big index takes minutes to load, and the caller
//        confirms it with the keyless /health.
//  PIN:  NO SECRET, NO CHALLENGE. The server reads its secrets from its own home,
//        as at any launch; the relauncher reads none and proves nothing, so it can
//        start only what a launcher already started there once.
//  PIN:  NEVER OVER A LIVE ONE. Refused while the run record names a live process,
//        or while anything listens on the recorded ports; under the home's start
//        lock, so two launchers never start one server twice.
//

#if os(macOS)
import Darwin
import Foundation

public enum RelaunchError: Error, Equatable, CustomStringConvertible {
    /// No launch record there: no launcher has started this server since launch
    /// records were kept.
    case noLaunchRecord(String)
    /// The run record names a live process.
    case running(pid: pid_t)
    /// Something listens on the recorded port.
    case portInUse(Int)
    /// The recorded executable is gone.
    case notBuilt(String)
    /// Another launcher held the start lock.
    case busy
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .noLaunchRecord(let path): return "nothing says how to start it: no \(path)"
        case .running(let pid): return "it is running (pid \(pid))"
        case .portInUse(let port): return "port \(port) is in use"
        case .notBuilt(let path): return "no executable at \(path)"
        case .busy: return "another launcher is starting or stopping it"
        case .spawnFailed(let reason): return "couldn't start: \(reason)"
        }
    }
}

extension ManagedServer {
    /// Starts the server `launchRecord` describes, as it was last launched, and
    /// records it as `launcher`'s. Returns once the process runs, not once it answers.
    public static func relaunch(
        launchRecord url: URL,
        launcher: StackIdentity,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        lockWait: TimeInterval = 10,
        settle: TimeInterval = 1.5
    ) async throws -> ProcessStamp {
        guard let record = LaunchRecord.load(url) else { throw RelaunchError.noLaunchRecord(PrivateFile.path(url)) }
        let spec = record.spec(inherited: inherited)
        try refuseLive(spec)

        try PrivateFile.ensureDirectory(spec.startLock.deletingLastPathComponent())
        let lock = try FileLock(spec.startLock)
        let deadline = Date().addingTimeInterval(lockWait)
        while !lock.tryLock() {
            guard Date() < deadline else { throw RelaunchError.busy }
            try await Task.sleep(for: .milliseconds(200))
        }
        defer { lock.unlock() }
        // Someone may have started it while this one waited.
        try refuseLive(spec)

        guard FileManager.default.isExecutableFile(atPath: PrivateFile.path(spec.executable)) else {
            throw RelaunchError.notBuilt(PrivateFile.path(spec.executable))
        }
        try PrivateFile.ensureDirectory(spec.logFile.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: PrivateFile.path(spec.workingDirectory)) {
            try PrivateFile.ensureDirectory(spec.workingDirectory)
        }
        let pid: pid_t
        do {
            pid = try posixSpawn(spec, newSession: true)
        } catch let error as ManagedServerError {
            throw RelaunchError.spawnFailed(error.description)
        }
        reap(pid)
        let stamp = ProcessStamp(pid: pid, processStart: ProcessProbe.startTime(of: pid))
        let startedAt = Date()
        let launchedBy = RunRecord.Launcher(identity: launcher, process: ProcessProbe.current)
        func keep(_ binary: String) {
            try? RunRecord(process: stamp, binary: binary, ports: spec.ports, launcher: launchedBy, startedAt: startedAt)
                .write(spec.runRecord)
        }
        // Written now so a stop during startup finds it, and again if the executable the
        // kernel reports changes while it settles (a shim exec'ing the real binary): a stop
        // checks that path.
        var binary = ProcessProbe.executablePath(of: pid) ?? ProcessProbe.resolvedPath(spec.executable)
        keep(binary)
        let settled = Date().addingTimeInterval(settle)
        while Date() < settled, ProcessProbe.isAlive(pid) {
            try await Task.sleep(for: .milliseconds(100))
            if let now = ProcessProbe.executablePath(of: pid), now != binary {
                binary = now
                keep(binary)
            }
        }
        return stamp
    }

    /// Throws when the run record names a live process or the port is taken.
    private static func refuseLive(_ spec: LaunchSpec) throws {
        if let running = RunRecord.load(spec.runRecord), ProcessProbe.isRunning(running.process),
           ProcessProbe.executablePath(of: running.process.pid) == running.binary {
            throw RelaunchError.running(pid: running.process.pid)
        }
        if !ProcessProbe.listeningPIDs(port: spec.ports.http).isEmpty { throw RelaunchError.portInUse(spec.ports.http) }
    }
}
#endif
