//
//  AIIStatus.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What an app shows about the Ambient Intelligence Index: one phase for
//        the badge, and the two servers underneath for a disclosure.
//  IN:   AIISupervisor, which publishes a new one whenever anything changes.
//  OUT:  Ambient's Settings page, Craft's cockpit, Veil's chip and sidebar — the
//        same shape everywhere, each app's own words.
//  PIN:  A Sendable value; the processes stay in the supervisor. `verified` on a
//        server means it proved this app's secret from the pid that holds its
//        port: what an app waits on before a credential moves. The phase is
//        derived from the two servers by one rule (`phase(sewn:thread:…)`), so
//        every app reads the same stack the same way.
//

import Foundation

public struct AIIStatus: Sendable, Equatable {

    public enum Phase: Sendable, Equatable {
        /// No pair in aii/bin (the detail says what is missing).
        case notInstalled(String?)
        /// A pair is being put in place or built; `step` is the current line.
        case installing(step: String)
        /// At least one server is starting and none has failed.
        case starting
        /// Both servers proved themselves and listen.
        case up
        /// One server is up, the other is not (the detail says which and why).
        case degraded(String)
        /// Neither server runs (the detail says why, when something is known).
        case down(String?)

        public var isUp: Bool { self == .up }
    }

    public struct ServerDetail: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable {
            case stopped
            case starting
            case up
            /// Alive, or someone is on its port, but not answering as ours.
            case unhealthy(String)
        }

        public var role: LaunchSpec.Role
        public var state: State
        public var pid: pid_t?
        public var startedAt: Date?
        public var ports: AIIPorts
        /// The executable it runs, when known.
        public var binary: String?
        /// Found running rather than started by this app.
        public var adopted: Bool
        /// The app, or the stack, whose launcher started it, when the run record says.
        public var launchedBy: StackIdentity?
        /// Proved this app's secret from the pid on its port.
        public var verified: Bool
        /// The contract it reported on /health.
        public var contract: Int?
        /// One line of why, for a row: never a secret.
        public var detail: String?
        public var logFile: URL

        public var id: String { role.rawValue }

        public init(role: LaunchSpec.Role, state: State, pid: pid_t? = nil, startedAt: Date? = nil, ports: AIIPorts,
                    binary: String? = nil, adopted: Bool = false, launchedBy: StackIdentity? = nil, verified: Bool = false,
                    contract: Int? = nil, detail: String? = nil, logFile: URL) {
            self.role = role
            self.state = state
            self.pid = pid
            self.startedAt = startedAt
            self.ports = ports
            self.binary = binary
            self.adopted = adopted
            self.launchedBy = launchedBy
            self.verified = verified
            self.contract = contract
            self.detail = detail
            self.logFile = logFile
        }

        public static func stopped(_ role: LaunchSpec.Role, ports: AIIPorts, logFile: URL, detail: String? = nil) -> ServerDetail {
            ServerDetail(role: role, state: .stopped, ports: ports, detail: detail, logFile: logFile)
        }

        public var isUp: Bool { state == .up }
    }

    public var phase: Phase
    public var sewn: ServerDetail
    public var thread: ServerDetail
    /// The index's embedding model, while Thread is up.
    public var embedder: ThreadEmbedderState?
    /// The other apps, and the aii command, holding the stack.
    public var sharedWith: [StackIdentity]
    /// Whether this app holds a lease on it now.
    public var holdsLease: Bool
    /// What aii/bin holds, when a build is installed.
    public var install: AIIInstallRecord?
    /// Why this app can't run what is installed (the person's build is on an older
    /// contract), for its status view; nil when nothing stands in the way.
    public var installProblem: String?
    /// The contract this app speaks.
    public var contract: Int

    public init(phase: Phase, sewn: ServerDetail, thread: ServerDetail, embedder: ThreadEmbedderState? = nil,
                sharedWith: [StackIdentity] = [], holdsLease: Bool = false, install: AIIInstallRecord? = nil,
                installProblem: String? = nil, contract: Int = AIIContract.version) {
        self.phase = phase
        self.sewn = sewn
        self.thread = thread
        self.embedder = embedder
        self.sharedWith = sharedWith
        self.holdsLease = holdsLease
        self.install = install
        self.installProblem = installProblem
        self.contract = contract
    }

    /// One line for any status: whose build is installed.
    public var installSummary: String { install?.summary ?? "Not installed" }

    public var servers: [ServerDetail] { [sewn, thread] }

    public func detail(for role: LaunchSpec.Role) -> ServerDetail {
        switch role {
        case .sewn: return sewn
        case .thread: return thread
        }
    }

    public var isUp: Bool { phase.isUp }

    /// The one rule: two servers → one phase. `problem` is why nothing can run yet
    /// (AIIInstaller.installProblem); it is what a stopped stack shows first.
    public static func phase(sewn: ServerDetail, thread: ServerDetail, installed: Bool, installing: String?,
                             problem: String? = nil) -> Phase {
        if let installing { return .installing(step: installing) }
        switch (sewn.state, thread.state) {
        case (.up, .up):
            return .up
        case (.stopped, .stopped):
            let detail = problem ?? sewn.detail ?? thread.detail
            return installed ? .down(detail) : .notInstalled(detail)
        case (.unhealthy(let reason), .up), (.unhealthy(let reason), .starting):
            return .degraded("\(sewn.role.displayName): \(reason)")
        case (.up, .unhealthy(let reason)), (.starting, .unhealthy(let reason)):
            return .degraded("\(thread.role.displayName): \(reason)")
        case (.unhealthy(let reason), _):
            return .down("\(sewn.role.displayName): \(reason)")
        case (_, .unhealthy(let reason)):
            return .down("\(thread.role.displayName): \(reason)")
        case (.starting, _), (_, .starting):
            return .starting
        case (.up, .stopped):
            return .degraded("\(thread.role.displayName) is stopped" + (thread.detail.map { " — \($0)" } ?? ""))
        case (.stopped, .up):
            return .degraded("\(sewn.role.displayName) is stopped" + (sewn.detail.map { " — \($0)" } ?? ""))
        }
    }
}
