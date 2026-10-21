//
//  AIISupervisor.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One process's hold on the Ambient Intelligence Index: install the AIIServer it
//        ships, bring the two servers up (adopting what another app started or
//        starting them), watch them, restart them, let go. The one implementation
//        every app and the aii command run.
//  IN:   An app at launch (`prepare`, `install`, `ensureRunning`), its Settings
//        (`restart`, `build`), its quit (`stop`/`shutdownSync`), its status view
//        (`status`); the aii command as the stack identity (`inspect`, `stop(force:)`).
//  OUT:  AIIStatus, published whenever anything changes; handles to proved servers.
//  PIN:  The caller's identity is the one it was made with, never a task-local: an app,
//        or the stack (`aii`) for the aii command.
//        A lease ("I need the stack") is taken before anything starts and covers
//        both servers; the servers stop only when the last lease is gone, under the
//        start lock so no launcher starts one in between. Every app has authority
//        over the build: a stale server (`ManagedServer.isStale`) is replaced
//        by whichever app finds it, and the others follow — a proved server that
//        goes away while this app still wants it is found again or restarted, at
//        most three times in five minutes. Only the installed binary is run, verified
//        at every spawn against install.json and its source's rule
//        (AIIInstaller.verifyInstalled), unless a development launch names a checkout
//        build. A binary that fails verification is reported, never swapped for a
//        checkout build behind the person's back.
//

#if os(macOS)
import Foundation

public actor AIISupervisor {

    /// How this process holds the stack.
    public enum Hold: Sendable, Equatable {
        /// An app: a lease that lives while this process does.
        case lease
        /// The aii command's start: a lease that outlives the process until released.
        case pinned
        /// A one-shot command: no lease, and nothing is stopped at exit.
        case none
    }

    public enum Target: Sendable, Equatable {
        case sewn, thread, all
    }

    /// A development launch: run this checkout build of AIIServer instead of the installed one.
    public struct Executables: Sendable, Equatable {
        public var server: URL?
        /// Where a checkout build runs (it finds that checkout's `.env` there).
        public var workingDirectory: URL?

        public init(server: URL? = nil, workingDirectory: URL? = nil) {
            self.server = server
            self.workingDirectory = workingDirectory
        }
    }

    /// Who this supervisor acts as: an app, or the stack (the aii command).
    public nonisolated let identity: StackIdentity
    public nonisolated let home: AIIHome
    public nonisolated let policy: SignaturePolicy
    public nonisolated let hold: Hold
    private let executables: Executables?
    private let threadOptions: ThreadLaunchOptions
    private let environment: [String: String]
    private let pollInterval: Duration

    private var servers: [LaunchSpec.Role: ManagedServer] = [:]
    private var details: [LaunchSpec.Role: AIIStatus.ServerDetail] = [:]
    private var embedder: ThreadEmbedderState?
    private var installing: String?
    private var observers: [UUID: AsyncStream<AIIStatus>.Continuation] = [:]
    private var pollTask: Task<Void, Never>?
    private var followTasks: [LaunchSpec.Role: Task<Void, Never>] = [:]
    private var follows: [LaunchSpec.Role: [Date]] = [:]
    /// `ensureRunning` was called and `stop`/`release` has not: a server that
    /// goes away is followed to its replacement.
    private var wanted = false
    private let holdHeld = LeaseFlag()

    public init(
        identity: StackIdentity,
        home: AIIHome = .resolved(),
        policy: SignaturePolicy = .standard,
        hold: Hold = .lease,
        executables: Executables? = nil,
        threadOptions: ThreadLaunchOptions = ThreadLaunchOptions(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pollInterval: Duration = .seconds(3)
    ) {
        self.identity = identity
        self.home = home
        self.policy = policy
        self.hold = hold
        self.executables = executables
        self.threadOptions = threadOptions
        self.environment = environment
        self.pollInterval = pollInterval
    }

    /// An app's supervisor.
    public init(
        app: AIIApp,
        home: AIIHome = .resolved(),
        policy: SignaturePolicy = .standard,
        hold: Hold = .lease,
        executables: Executables? = nil,
        threadOptions: ThreadLaunchOptions = ThreadLaunchOptions(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pollInterval: Duration = .seconds(3)
    ) {
        self.init(identity: .app(app), home: home, policy: policy, hold: hold, executables: executables,
                  threadOptions: threadOptions, environment: environment, pollInterval: pollInterval)
    }

    // MARK: - Facts

    /// The app this supervisor acts for; nil for the stack.
    public nonisolated var app: AIIApp? { identity.app }
    public nonisolated var installer: AIIInstaller { AIIInstaller(home: home, policy: policy) }
    public nonisolated var leases: AIILeases { AIILeases(home: home) }
    public nonisolated var isInstalled: Bool { installer.isInstalled }
    public nonisolated var config: AIIConfig { AIIConfig.load(home: home) }
    public nonisolated var sewnPorts: AIIPorts { config.sewnPorts }
    public nonisolated var threadPorts: AIIPorts { config.threadPorts }

    /// Creates whatever of ~/.rao is missing — directories, the stack's secret, the apps
    /// every home starts with — registers this app (its secret, its lane, and
    /// `displayName` when it is new here; `owner`, when given, as its lane's no-account
    /// owner: `.local` for aii-local) and returns this identity's secret.
    @discardableResult
    public func prepare(displayName: String? = nil, bundleIdentifier: String? = nil, owner: AIIOwner? = nil) throws -> String {
        let secrets: [StackIdentity: String]
        if let app = identity.app {
            secrets = try home.provision(by: app, displayName: displayName, bundleIdentifier: bundleIdentifier, owner: owner)
        } else {
            secrets = try home.provision()
        }
        _ = try AIILanes.ensure(home: home)
        guard let secret = secrets[identity] else { throw AIIHomeError.missingSecret(identity) }
        return secret
    }

    // MARK: - Status

    public func snapshot() -> AIIStatus {
        let config = self.config
        let sewn = details[.sewn] ?? .stopped(.sewn, ports: config.sewnPorts, logFile: home.sewnLogFile)
        let thread = details[.thread] ?? .stopped(.thread, ports: config.threadPorts, logFile: home.threadLogFile)
        let install = installer.installedRecord()
        let problem = executables?.server == nil ? installer.installProblem(as: identity) : nil
        let installed = executables != nil || (install != nil && problem == nil)
        return AIIStatus(
            phase: AIIStatus.phase(sewn: sewn, thread: thread, installed: installed, installing: installing, problem: problem),
            sewn: sewn,
            thread: thread,
            embedder: thread.state == .up ? embedder : nil,
            sharedWith: leases.others(excluding: identity),
            holdsLease: holdHeld.value,
            install: install,
            installProblem: problem)
    }

    /// Every change, starting with the state now.
    public func statusStream() -> AsyncStream<AIIStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    /// What runs now, read without starting, adopting or holding anything: each server's
    /// run record (or whatever answers on its port) challenged with this identity's
    /// secret. For a command that only looks.
    public func inspect(timeout: TimeInterval = 2) async -> AIIStatus {
        let secret = (try? home.readSecret(for: identity)) ?? ""
        for role in LaunchSpec.Role.allCases {
            let spec = spec(for: role)
            let runRecord = role == .sewn ? home.sewnRunRecord : home.threadRunRecord
            var detail = AIIStatus.ServerDetail.stopped(role, ports: spec.ports, logFile: spec.logFile)
            let record = RunRecord.load(runRecord)
            let recorded = record.flatMap { record -> pid_t? in
                guard ProcessProbe.isRunning(record.process),
                      ProcessProbe.executablePath(of: record.process.pid) == record.binary else { return nil }
                return record.process.pid
            }
            let (verdict, body) = await StackProbe.challengeWithBody(spec, secret: secret, timeout: timeout)
            switch verdict {
            case .ours(let contract):
                let listening = ProcessProbe.listeningPIDs(port: spec.ports.http)
                let pid = recorded.flatMap { listening.contains($0) ? $0 : nil } ?? (listening.count == 1 ? listening.first : nil)
                detail.state = .up
                detail.pid = pid
                detail.verified = pid != nil
                detail.contract = contract
                detail.adopted = true
                if let pid, pid == recorded, let record {
                    detail.startedAt = record.startedAt
                    detail.binary = record.binary
                    detail.launchedBy = record.launcher?.identity
                } else if let pid {
                    detail.binary = ProcessProbe.executablePath(of: pid)
                }
                if role == .thread { embedder = body.flatMap(ThreadEmbedderState.parse(healthBody:)) }
            case .down:
                if let recorded {
                    detail.state = .unhealthy("pid \(recorded) runs but doesn't answer on \(spec.ports.http)")
                    detail.pid = recorded
                }
            case .stale, .open:
                detail.state = .unhealthy("port \(spec.ports.http) is answered by another program")
            }
            details[role] = detail
        }
        if details[.thread]?.state != .up { embedder = nil }
        publish()
        return snapshot()
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func publish() {
        let current = snapshot()
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    private func update(_ role: LaunchSpec.Role, _ body: (inout AIIStatus.ServerDetail) -> Void) {
        var detail = details[role] ?? .stopped(role, ports: config.ports(for: role), logFile: logFile(for: role))
        body(&detail)
        details[role] = detail
        publish()
    }

    private func logFile(for role: LaunchSpec.Role) -> URL {
        role == .sewn ? home.sewnLogFile : home.threadLogFile
    }

    // MARK: - Install

    /// Puts `payload` in aii/bin when the rules say so (AIIInstaller).
    /// `policy` overrides this supervisor's for the call (`.unchecked` for checkout builds).
    @discardableResult
    public func install(_ payload: AIIInstallPayload, policy override: SignaturePolicy? = nil) throws -> AIIInstallOutcome {
        installing = "installing the Ambient Intelligence Index"
        publish()
        defer {
            installing = nil
            publish()
        }
        return try installer.installIfNeeded(payload, by: identity, policy: override)
    }

    /// The build `bundle` ships in Contents/Helpers, installed when the rules say
    /// so; nil when the bundle ships none (a development build).
    @discardableResult
    public func install(from bundle: Bundle, appVersion: String, publicEnvironment: [String: String] = [:]) throws -> AIIInstallOutcome? {
        guard let payload = AIIInstallPayload.bundled(in: bundle, appVersion: appVersion, publicEnvironment: publicEnvironment) else {
            return nil
        }
        return try install(payload)
    }

    // MARK: - Up

    /// Both servers, adopted or started, with this process's hold on them.
    public func ensureRunning(timeout: TimeInterval = 60) async throws {
        try takeHold()
        wanted = true
        _ = try await ensure(.sewn, timeout: timeout)
        _ = try await ensure(.thread, timeout: timeout)
        startPollingIfNeeded()
    }

    /// One server, adopted or started. `ensureRunning` is the usual entry; this is
    /// for a follow, a restart of one, and tests.
    @discardableResult
    public func ensure(_ role: LaunchSpec.Role, timeout: TimeInterval = 60) async throws -> ServerHandle {
        let secret = try home.ensureSecret(for: identity)
        if executables?.server == nil {
            do {
                try installer.verifyInstalled(as: identity)
            } catch {
                update(role) {
                    $0.state = .stopped
                    $0.detail = "\(error)"
                }
                throw error
            }
        }
        update(role) {
            $0.state = .starting
            $0.detail = nil
            $0.verified = false
        }
        let server = server(for: role, secret: secret)
        do {
            let handle = try await server.ensureRunning(timeout: timeout)
            let record = RunRecord.load(role == .sewn ? home.sewnRunRecord : home.threadRunRecord)
            update(role) {
                $0.state = .up
                $0.pid = handle.pid
                $0.startedAt = record?.startedAt ?? Date()
                $0.ports = handle.ports
                $0.binary = record?.binary ?? ProcessProbe.executablePath(of: handle.pid)
                $0.adopted = handle.adopted
                $0.launchedBy = handle.launchedBy
                $0.verified = true
                $0.contract = handle.contract
                $0.detail = nil
            }
            if role == .thread {
                let (_, body) = await server.verdictWithBody()
                embedder = body.flatMap(ThreadEmbedderState.parse(healthBody:))
                publish()
            }
            startPollingIfNeeded()
            return handle
        } catch {
            update(role) {
                $0.state = .stopped
                $0.pid = nil
                $0.verified = false
                $0.detail = "\(error)"
            }
            throw error
        }
    }

    /// Stops the target, whoever holds it, and starts the installed build in its place:
    /// a restart the person asked for. The other apps follow to the new one.
    public func restart(_ target: Target, timeout: TimeInterval = 60) async throws {
        try takeHold()
        wanted = true
        switch target {
        case .sewn:
            try await restartOne(.sewn, timeout: timeout)
        case .thread:
            try await restartOne(.thread, timeout: timeout)
        case .all:
            // Thread dials Sewn: it goes down first and comes up last.
            if let thread = servers[.thread] {
                await thread.stop()
            } else {
                ManagedServer.stopRecordedSync(home.threadRunRecord)
            }
            update(.thread) { $0.state = .stopped; $0.pid = nil; $0.verified = false; $0.detail = nil }
            try await restartOne(.sewn, timeout: timeout)
            _ = try await ensure(.thread, timeout: timeout)
        }
        startPollingIfNeeded()
    }

    private func restartOne(_ role: LaunchSpec.Role, timeout: TimeInterval) async throws {
        let secret = try home.ensureSecret(for: identity)
        if executables?.server == nil { try installer.verifyInstalled(as: identity) }
        update(role) { $0.state = .starting; $0.detail = nil; $0.verified = false }
        let server = server(for: role, secret: secret)
        do {
            let handle = try await server.restart(timeout: timeout)
            let record = RunRecord.load(role == .sewn ? home.sewnRunRecord : home.threadRunRecord)
            update(role) {
                $0.state = .up
                $0.pid = handle.pid
                $0.startedAt = record?.startedAt ?? Date()
                $0.ports = handle.ports
                $0.binary = record?.binary ?? ProcessProbe.executablePath(of: handle.pid)
                $0.adopted = handle.adopted
                $0.launchedBy = handle.launchedBy
                $0.verified = true
                $0.contract = handle.contract
                $0.detail = nil
            }
        } catch {
            update(role) { $0.state = .stopped; $0.pid = nil; $0.verified = false; $0.detail = "\(error)" }
            throw error
        }
    }

    private func server(for role: LaunchSpec.Role, secret: String) -> ManagedServer {
        let spec = spec(for: role)
        if let existing = servers[role], existing.spec == spec { return existing }
        let verify: ManagedServer.Verifier?
        if executables?.server == nil {
            verify = { [installer, identity] _ in try installer.verifyInstalled(as: identity) }
        } else {
            verify = nil
        }
        let server = ManagedServer(
            spec: spec, secret: secret, launcher: identity, verify: verify,
            othersNeedIt: { [leases, identity] in leases.others(excluding: identity) })
        servers[role] = server
        return server
    }

    private func spec(for role: LaunchSpec.Role) -> LaunchSpec {
        let config = self.config
        switch role {
        case .sewn:
            return LaunchSpecs.sewn(home: home, config: config, executable: executables?.server,
                                    workingDirectory: executables?.workingDirectory,
                                    challenge: identity, inherited: environment)
        case .thread:
            return LaunchSpecs.thread(home: home, config: config, executable: executables?.server,
                                      sewnPorts: config.sewnPorts, options: threadOptions,
                                      workingDirectory: executables?.workingDirectory,
                                      challenge: identity, inherited: environment)
        }
    }

    // MARK: - Holding

    private func takeHold() throws {
        switch hold {
        case .lease:
            try leases.acquire(for: identity)
            holdHeld.set(true)
        case .pinned:
            try leases.acquire(for: identity, pinned: true)
            holdHeld.set(true)
        case .none:
            break
        }
    }

    /// Lets go of this process's hold without stopping anything. The servers keep
    /// running for whoever else holds them — or for nobody, until `stop`.
    public func release() {
        wanted = false
        cancelFollows()
        switch hold {
        case .lease: leases.release(for: identity)
        case .pinned: leases.release(for: identity, pinned: true)
        case .none: break
        }
        holdHeld.set(false)
        publish()
    }

    /// Lets go of this process's hold and, when nobody else holds the stack — or when
    /// `force` says to stop it anyway — stops Thread then Sewn, under the start lock so no
    /// launcher starts one in between.
    public func stop(force: Bool = false) async {
        release()
        guard force || leases.live().isEmpty else { return }
        let lock = try? FileLock(home.startLockFile)
        let deadline = Date().addingTimeInterval(2)
        var locked = false
        while let lock, !locked, Date() < deadline {
            locked = lock.tryLock()
            if !locked { try? await Task.sleep(for: .milliseconds(100)) }
        }
        defer { if locked { lock?.unlock() } }
        for role in [LaunchSpec.Role.thread, .sewn] {
            if let server = servers[role] {
                await server.stop()
            } else {
                ManagedServer.stopRecordedSync(role == .sewn ? home.sewnRunRecord : home.threadRunRecord)
            }
            update(role) { $0.state = .stopped; $0.pid = nil; $0.verified = false; $0.adopted = false; $0.detail = nil }
        }
        embedder = nil
        publish()
    }

    /// For a terminate handler that can't await: drops this process's lease and,
    /// when nobody else holds the stack, stops whatever the run records name.
    /// A pinned hold and a one-shot command stop nothing: the servers outlive them.
    public nonisolated func shutdownSync() {
        guard hold == .lease, holdHeld.value else { return }
        leases.release(for: identity)
        holdHeld.set(false)
        guard leases.live().isEmpty else { return }
        ManagedServer.stopRecordedSync(home.threadRunRecord)
        ManagedServer.stopRecordedSync(home.sewnRunRecord)
    }

    // MARK: - Watching

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        for role in LaunchSpec.Role.allCases {
            guard let server = servers[role], let before = details[role] else { continue }
            switch before.state {
            case .starting:
                // ensure/restart own the first proof.
                continue
            case .stopped:
                continue
            case .up, .unhealthy:
                let (verdict, body) = await server.verdictWithBody()
                // A start or a stop may have run while the check was out: theirs is the word.
                guard let detail = details[role], detail.state != .starting, detail.state != .stopped else { continue }
                let port = server.spec.ports.http
                switch verdict {
                case .ours(let contract):
                    let listening = ProcessProbe.listeningPIDs(port: port)
                    if let pid = detail.pid, ProcessProbe.isAlive(pid), listening.contains(pid) {
                        if role == .thread {
                            let parsed = body.flatMap(ThreadEmbedderState.parse(healthBody:))
                            if parsed != embedder { embedder = parsed }
                        }
                        update(role) { $0.state = .up; $0.verified = true; $0.contract = contract; $0.detail = nil }
                    } else if listening.count == 1, let pid = listening.first {
                        // Ours, from a pid this process didn't start: another launcher replaced it.
                        await server.forget()
                        let record = RunRecord.load(role == .sewn ? home.sewnRunRecord : home.threadRunRecord)
                        update(role) {
                            $0.state = .up
                            $0.pid = pid
                            $0.startedAt = record?.startedAt ?? Date()
                            $0.binary = record?.binary ?? ProcessProbe.executablePath(of: pid)
                            $0.adopted = true
                            $0.launchedBy = record?.launcher?.identity
                            $0.verified = true
                            $0.contract = contract
                            $0.detail = nil
                        }
                    } else {
                        update(role) { $0.verified = false; $0.state = .unhealthy("port \(port) answers as ours from a process that can't be seen") }
                    }
                case .down:
                    if let pid = detail.pid, ProcessProbe.isAlive(pid) {
                        // Transient: nobody else can bind a port a live server holds.
                        update(role) { $0.state = .unhealthy("health check failing") }
                    } else {
                        await markExited(role, detail: "exited")
                    }
                case .stale, .open:
                    update(role) {
                        $0.verified = false
                        $0.state = .unhealthy("port \(port) is answered by another program")
                    }
                }
            }
        }
    }

    /// The server is gone: its pid and record go; if this process still wants it,
    /// it is followed to its replacement.
    private func markExited(_ role: LaunchSpec.Role, detail reason: String) async {
        let wasVerified = details[role]?.verified ?? false
        if let server = servers[role] { await server.forget() }
        RunRecord.remove(role == .sewn ? home.sewnRunRecord : home.threadRunRecord)
        if role == .thread { embedder = nil }
        update(role) {
            $0.state = .stopped
            $0.pid = nil
            $0.startedAt = nil
            $0.adopted = false
            $0.verified = false
            $0.detail = reason
        }
        if wanted, wasVerified { follow(role) }
    }

    /// Finds the server that took the place of the one this process held, or starts
    /// one — a few times in a row at most, so a server that dies on its own isn't
    /// restarted forever.
    private func follow(_ role: LaunchSpec.Role) {
        guard followTasks[role] == nil else { return }
        let now = Date()
        let recent = (follows[role] ?? []).filter { now.timeIntervalSince($0) < 300 } + [now]
        follows[role] = recent
        guard recent.count <= 3 else {
            update(role) { $0.detail = "went away \(recent.count) times in five minutes; left stopped" }
            return
        }
        followTasks[role] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.finishFollowing(role)
        }
    }

    private func finishFollowing(_ role: LaunchSpec.Role) async {
        defer { followTasks[role] = nil }
        guard wanted, details[role]?.state == .stopped else { return }
        _ = try? await ensure(role)
    }

    private func cancelFollows() {
        for task in followTasks.values { task.cancel() }
        followTasks = [:]
    }

    // MARK: - Development

    /// Builds AIIServer from an AII checkout (`Scripts/build-servers.sh <configuration>`)
    /// and installs it as the person's own build (AIIInstaller.installLocal), one line of
    /// output at a time. The servers keep running the build they started with until a
    /// restart.
    public func build(fromCheckout root: URL, configuration: String = "release") -> AsyncStream<String> {
        installing = "building the Ambient Intelligence Index"
        publish()
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let installer = self.installer
        let task = Task.detached { [weak self] in
            let built = await AIIInstaller.build(checkout: root, configuration: configuration) { continuation.yield($0) }
            if built {
                do {
                    let outcome = try installer.installLocal(from: root, configuration: configuration)
                    continuation.yield("installed \(outcome.record.summary) (contract \(outcome.record.contract)) into \(PrivateFile.path(installer.home.aiiBinDirectory))")
                } catch {
                    continuation.yield("error: \(error)")
                }
            }
            continuation.finish()
            await self?.finishBuilding()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func finishBuilding() {
        installing = nil
        publish()
    }
}

/// Whether this process holds its lease, readable from a terminate handler.
final class LeaseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false

    var value: Bool { lock.withLock { held } }
    func set(_ value: Bool) { lock.withLock { held = value } }
}
#endif
