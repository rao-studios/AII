//
//  ManagedServer.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One server of the stack — the Sewn or the Thread every app uses —
//        brought up by adopting the one already running or spawning a new one,
//        and stopped again.
//  IN:   A LaunchSpec (LaunchSpecs.sewn / .thread) and the launching identity's
//        secret: an app's, or the stack's when the aii command launches.
//  OUT:  A handle to a process that has proved, on /health, that it holds the
//        app's secret and that lsof shows listening on its port.
//  PIN:  Adopted only when every check agrees: the run record's pid is alive
//        and started when recorded, it runs the recorded binary, it listens
//        on the port, and it proves the secret. Both servers are one per Mac
//        and every app has authority over their build: a stale one (`isStale`)
//        is replaced by whichever app finds it, whoever holds a lease — they
//        reconnect to the new one. A current server that can't prove the
//        secret is replaced only when no other app holds a lease; otherwise the
//        launch fails loudly rather than pulling it out from under them.
//        Starting is serialized across processes by the spec's start lock. What may
//        be exec'd is decided at spawn by the launcher's verifier, not by a policy
//        fixed when the server was made: the install can change from an app's signed
//        build to the person's own while an app runs.
//        Both are spawned in their own session so they outlive the app that
//        started them while others still need them.
//

#if os(macOS)
import Darwin
import Foundation

public struct ServerHandle: Sendable, Equatable {
    public let pid: pid_t
    public let ports: AIIPorts
    /// True when this launcher found it running rather than starting it.
    public let adopted: Bool
    /// The contract it reported on /health, when it did.
    public let contract: Int
    /// The identity whose launcher started it, when the run record says.
    public let launchedBy: StackIdentity?

    public init(pid: pid_t, ports: AIIPorts, adopted: Bool, contract: Int, launchedBy: StackIdentity?) {
        self.pid = pid
        self.ports = ports
        self.adopted = adopted
        self.contract = contract
        self.launchedBy = launchedBy
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(ports.http)")! }
}

public enum ManagedServerError: Error, Equatable, CustomStringConvertible {
    case notBuilt(String)
    case portInUse(port: Int, verdict: StackVerdict)
    case sharedServerUnproven(LaunchSpec.Role, holders: [StackIdentity])
    case spawnFailed(String)
    case exited(logTail: String)
    case timedOut(logTail: String)
    case signature(String)

    public var description: String {
        switch self {
        case .notBuilt(let path): return "no executable at \(path)"
        case .portInUse(let port, let verdict): return "port \(port) is held by something that isn't this app's stack (\(verdict))"
        case .sharedServerUnproven(let role, let holders):
            return "the shared \(role.displayName) can't prove this app's secret and \(holders.map(\.displayName).joined(separator: ", ")) still use it"
        case .spawnFailed(let reason): return "couldn't start: \(reason)"
        case .exited(let tail): return "exited during startup\(tail.isEmpty ? "" : ":\n\(tail)")"
        case .timedOut(let tail): return "didn't become healthy in time\(tail.isEmpty ? "" : ":\n\(tail)")"
        case .signature(let reason): return reason
        }
    }
}

public actor ManagedServer {
    public typealias Verifier = @Sendable (URL) throws -> Void

    public nonisolated let spec: LaunchSpec
    private let secret: String
    private let launcher: StackIdentity
    private let verify: Verifier?
    private let othersNeedIt: @Sendable () -> [StackIdentity]
    private var handle: ServerHandle?

    /// - Parameters:
    ///   - launcher: The app, or the stack, starting it; recorded in the run record.
    ///   - verify: Run against the executable before every spawn; nil skips the check
    ///     (a development checkout build). AIISupervisor passes the installer's
    ///     `verifyInstalled(as:)`.
    ///   - othersNeedIt: The other identities holding a lease — who a replacement
    ///     would disrupt.
    public init(
        spec: LaunchSpec,
        secret: String,
        launcher: StackIdentity,
        verify: Verifier? = nil,
        othersNeedIt: @escaping @Sendable () -> [StackIdentity] = { [] }
    ) {
        self.spec = spec
        self.secret = secret
        self.launcher = launcher
        self.verify = verify
        self.othersNeedIt = othersNeedIt
    }

    /// An app's launch, checking the executable against `policy` before every spawn.
    public init(
        spec: LaunchSpec,
        secret: String,
        launcherApp: AIIApp,
        policy: SignaturePolicy? = nil,
        othersNeedIt: @escaping @Sendable () -> [AIIApp] = { [] }
    ) {
        self.init(spec: spec, secret: secret, launcher: .app(launcherApp),
                  verify: policy.map { policy -> Verifier in { url in try policy.check(url) } },
                  othersNeedIt: { othersNeedIt().map(StackIdentity.app) })
    }

    public var current: ServerHandle? { handle }

    public func verdict() async -> StackVerdict {
        await StackProbe.challenge(spec, secret: secret)
    }

    /// The verdict and the /health body it came from.
    public func verdictWithBody() async -> (verdict: StackVerdict, body: Data?) {
        await StackProbe.challengeWithBody(spec, secret: secret)
    }

    // MARK: - Up

    public func ensureRunning(timeout: TimeInterval = 60) async throws -> ServerHandle {
        if let handle, ProcessProbe.isAlive(handle.pid), await verdict().isOurs {
            return handle
        }
        handle = nil
        if let adopted = try await adoptRecorded() { return remember(adopted) }
        if let adopted = try await adoptByPort() { return remember(adopted) }
        return remember(try await spawnSerialized(timeout: timeout))
    }

    /// Whether a running server runs an older build than this launch would: another
    /// binary, or the same file rebuilt or reinstalled since the process started. The
    /// file's change time decides, not its modification time: an installer's copy keeps
    /// the build's mtime, so a server installed after its predecessor started looked older.
    static func isOutdated(recordedBinary: String, processStart: UInt64?, wanted: URL) -> Bool {
        guard ProcessProbe.resolvedPath(wanted) == recordedBinary else { return true }
        guard let processStart, let changed = ProcessProbe.changeTime(ofFile: recordedBinary) else { return true }
        return changed > processStart
    }

    /// Whether a running server should give way to the build this launch runs, whoever
    /// holds it. The same binary: when that file was replaced or rebuilt after the process
    /// started (an update installed while it ran). Another binary — a checkout build someone
    /// chose — only when its contract is older than this app's. `contract` is nil for a
    /// server that has not proved itself yet: only its build is judged then.
    public static func isStale(recordedBinary: String, processStart: UInt64?, contract: Int?, wanted: URL) -> Bool {
        if ProcessProbe.resolvedPath(wanted) == recordedBinary {
            return isOutdated(recordedBinary: recordedBinary, processStart: processStart, wanted: wanted)
        }
        guard let contract else { return false }
        return contract < AIIContract.version
    }

    private func remember(_ handle: ServerHandle) -> ServerHandle {
        self.handle = handle
        return handle
    }

    /// The process the run record names, if it is still that process and
    /// still ours; otherwise the record is cleared (and a leftover replaced).
    private func adoptRecorded() async throws -> ServerHandle? {
        guard let record = RunRecord.load(spec.runRecord) else { return nil }
        let pid = record.process.pid
        guard ProcessProbe.isRunning(record.process), ProcessProbe.executablePath(of: pid) == record.binary else {
            RunRecord.remove(spec.runRecord)
            return nil
        }
        let found = await verdict()
        let listening = ProcessProbe.listeningPIDs(port: spec.ports.http).contains(pid)
        if case .ours(let contract) = found, listening {
            if Self.isStale(recordedBinary: record.binary, processStart: record.process.processStart,
                            contract: contract, wanted: spec.executable) {
                // An older build than this app runs. Any app may bring the server up to
                // date; the apps holding it find the new one on their next check.
                await Self.terminate(pid)
                RunRecord.remove(spec.runRecord)
                return nil
            }
            return ServerHandle(pid: pid, ports: spec.ports, adopted: true, contract: contract,
                                launchedBy: record.launcher?.identity)
        }
        if !Self.isStale(recordedBinary: record.binary, processStart: record.process.processStart,
                         contract: nil, wanted: spec.executable) {
            let holders = othersNeedIt()
            if !holders.isEmpty { throw ManagedServerError.sharedServerUnproven(spec.role, holders: holders) }
        }
        await Self.terminate(pid)
        RunRecord.remove(spec.runRecord)
        return nil
    }

    /// Something answers on the port with no usable record.
    private func adoptByPort() async throws -> ServerHandle? {
        let found = await verdict()
        switch found {
        case .down:
            return nil
        case .ours(let contract):
            let pids = ProcessProbe.listeningPIDs(port: spec.ports.http)
            guard pids.count == 1, let pid = pids.first,
                  let path = ProcessProbe.executablePath(of: pid),
                  URL(fileURLWithPath: path).lastPathComponent == spec.executable.lastPathComponent else {
                throw ManagedServerError.portInUse(port: spec.ports.http, verdict: found)
            }
            // A server another launcher started without leaving a record.
            if Self.isStale(recordedBinary: path, processStart: ProcessProbe.startTime(of: pid),
                            contract: contract, wanted: spec.executable) {
                await Self.terminate(pid)
                return nil
            }
            if let stamp = ProcessProbe.stamp(of: pid) {
                try? RunRecord(process: stamp, binary: path, ports: spec.ports, launcher: nil, startedAt: Date())
                    .write(spec.runRecord)
            }
            return ServerHandle(pid: pid, ports: spec.ports, adopted: true, contract: contract, launchedBy: nil)
        case .open, .stale:
            throw ManagedServerError.portInUse(port: spec.ports.http, verdict: found)
        }
    }

    /// Stops what the run record names, whoever else holds it, and starts this launch's
    /// build: an explicit restart. The apps holding it reconnect to the new one.
    public func restart(timeout: TimeInterval = 60) async throws -> ServerHandle {
        let deadline = Date().addingTimeInterval(timeout)
        let lock = try await takeStartLock(until: deadline)
        defer { lock.unlock() }
        // The run record, checked, names what runs now; a handle may name one another
        // app has since replaced.
        handle = nil
        await stop()
        if let adopted = try await adoptByPort() { return remember(adopted) }
        return remember(try await spawn(deadline: deadline))
    }

    private func spawnSerialized(timeout: TimeInterval) async throws -> ServerHandle {
        let deadline = Date().addingTimeInterval(timeout)
        let lock = try await takeStartLock(until: deadline)
        defer { lock.unlock() }
        // Someone may have started it while this launcher waited.
        if let adopted = try await adoptRecorded() { return adopted }
        if let adopted = try await adoptByPort() { return adopted }
        return try await spawn(deadline: deadline)
    }

    private func takeStartLock(until deadline: Date) async throws -> FileLock {
        try PrivateFile.ensureDirectory(spec.startLock.deletingLastPathComponent())
        let lock = try FileLock(spec.startLock)
        while !lock.tryLock() {
            guard Date() < deadline else { throw ManagedServerError.timedOut(logTail: "another launcher held \(spec.startLock.lastPathComponent)") }
            try await Task.sleep(for: .milliseconds(200))
        }
        return lock
    }

    private func spawn(deadline: Date) async throws -> ServerHandle {
        let executable = spec.executable
        guard FileManager.default.isExecutableFile(atPath: PrivateFile.path(executable)) else {
            throw ManagedServerError.notBuilt(PrivateFile.path(executable))
        }
        if let verify {
            do { try verify(executable) } catch { throw ManagedServerError.signature("\(error)") }
        }
        try PrivateFile.ensureDirectory(spec.logFile.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: PrivateFile.path(spec.workingDirectory)) {
            try PrivateFile.ensureDirectory(spec.workingDirectory)
        }

        let pid = try Self.posixSpawn(spec, newSession: true)
        Self.reap(pid)
        let launcher = RunRecord.Launcher(identity: self.launcher, process: ProcessProbe.current)
        func record() -> RunRecord {
            RunRecord(
                process: ProcessStamp(pid: pid, processStart: ProcessProbe.startTime(of: pid)),
                binary: ProcessProbe.executablePath(of: pid) ?? ProcessProbe.resolvedPath(executable),
                ports: spec.ports, launcher: launcher, startedAt: Date())
        }
        // Written now so a stop during startup finds it, and again once the
        // server is up: the executable the kernel reports is final by then
        // (a launcher shim may have exec'd the real binary).
        try? record().write(spec.runRecord)

        while Date() < deadline {
            guard ProcessProbe.isAlive(pid) else {
                RunRecord.remove(spec.runRecord)
                throw ManagedServerError.exited(logTail: Self.tail(of: spec.logFile))
            }
            if case .ours(let contract) = await verdict(),
               ProcessProbe.listeningPIDs(port: spec.ports.http).contains(pid) {
                try? record().write(spec.runRecord)
                return ServerHandle(pid: pid, ports: spec.ports, adopted: false, contract: contract, launchedBy: self.launcher)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        await Self.terminate(pid)
        RunRecord.remove(spec.runRecord)
        throw ManagedServerError.timedOut(logTail: Self.tail(of: spec.logFile))
    }

    // MARK: - Down

    /// Stops the server this launcher holds, or the one its run record names.
    public func stop(grace: TimeInterval = 3) async {
        var pid = handle?.pid
        if pid == nil, let record = RunRecord.load(spec.runRecord),
           ProcessProbe.isRunning(record.process),
           ProcessProbe.executablePath(of: record.process.pid) == record.binary {
            pid = record.process.pid
        }
        if let pid { await Self.terminate(pid, grace: grace) }
        RunRecord.remove(spec.runRecord)
        handle = nil
    }

    /// Forgets the handle without stopping anything: the server went away, or
    /// another app replaced it.
    public func forget() {
        handle = nil
    }

    /// For a terminate handler that can't await: stops whatever `runRecord`
    /// names, if it is still that process — and, with `launchedBy`, only if
    /// that process launched it.
    public static func stopRecordedSync(_ runRecord: URL, launchedBy: ProcessStamp? = nil, grace: TimeInterval = 1.5) {
        guard let record = RunRecord.load(runRecord) else { return }
        if let launchedBy, record.launcher?.process != launchedBy { return }
        let pid = record.process.pid
        guard ProcessProbe.isRunning(record.process), ProcessProbe.executablePath(of: pid) == record.binary else {
            RunRecord.remove(runRecord)
            return
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while ProcessProbe.isAlive(pid), Date() < deadline { usleep(50_000) }
        if ProcessProbe.isAlive(pid) { kill(pid, SIGKILL) }
        RunRecord.remove(runRecord)
    }

    static func terminate(_ pid: pid_t, grace: TimeInterval = 3) async {
        guard ProcessProbe.isAlive(pid) else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while ProcessProbe.isAlive(pid), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ProcessProbe.isAlive(pid) else { return }
        kill(pid, SIGKILL)
        let hardDeadline = Date().addingTimeInterval(1)
        while ProcessProbe.isAlive(pid), Date() < hardDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Spawning

    /// posix_spawn with stdin from /dev/null, stdout and stderr appended to
    /// the log, the spec's working directory, no inherited descriptors, the
    /// default signal dispositions, and a session of its own.
    static func posixSpawn(_ spec: LaunchSpec, newSession: Bool) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, PrivateFile.path(spec.logFile), O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, PrivateFile.path(spec.workingDirectory))

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
        if newSession { flags |= Int32(POSIX_SPAWN_SETSID) }
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)

        let path = PrivateFile.path(spec.executable)
        let argv = ([path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard status == 0 else { throw ManagedServerError.spawnFailed(String(cString: strerror(status))) }
        return pid
    }

    /// Collects the child when it exits, so it never lingers as a zombie.
    static func reap(_ pid: pid_t) {
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    static func tail(of log: URL, lines: Int = 20) -> String {
        guard let data = FileManager.default.contents(atPath: PrivateFile.path(log)) else { return "" }
        let text = String(decoding: data.suffix(16_384), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
#endif
