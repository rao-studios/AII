//
//  AIIInstance.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: An app's instance of the Ambient Intelligence Index, made from its
//        AIIAppDescriptor: the one type the app holds to join the index, push its records
//        into its lane, recall them, forget them, and ask a question grounded in them —
//        on device, or through the provider whose key the stack holds; no account.
//  IN:   An AIIAppDescriptor (`AIIInstance(Notes.self)`) or a name; the app's AIIRecordable
//        types.
//  OUT:  `join()`, `status()`, `leave()`, `remember`, `recall`, `forget`, `ask`, and the
//        supervisor and client underneath for anything lower.
//  PIN:  `join()` registers the lane (its secret and its manifest entry) first, so the
//        running servers admit the app on their next miss; installs the build the app's
//        bundle ships, when it ships one; adopts or starts the servers; and waits until
//        both have proved the app's secret. A server reads secrets/ again at most once
//        every two seconds, so a first refusal right after registering is retried once
//        that window has passed. No account: records are filed under the lane's owner in
//        the manifest, `local-<app>` or `aii-local` (AIIOwner), which Sewn reads too and
//        answers as with no account, so `recall` and `ask` see the same documents. An owner
//        passed to `init` is written to the lane on `join()`: how an app opts into aii-local.
//        Every Thread call is direct (ThreadWire) and never sends an empty Remove, which
//        Thread reads as every document the owner holds.
//

#if os(macOS)
import Foundation
import GRPCCore
import Seam

public enum AIIInstanceError: Error, Equatable, CustomStringConvertible {
    /// A call before `join()`.
    case notJoined
    /// The stack isn't ready yet (the embedder loading, a server starting): try again.
    case notReady(String)
    /// Thread refused the call.
    case refused(code: String, message: String)

    public var description: String {
        switch self {
        case .notJoined: return "join the index first: try await aii.join()"
        case .notReady(let why): return "the index isn't ready yet: \(why)"
        case .refused(let code, let message): return "the index refused the call (\(code)): \(message)"
        }
    }
}

public actor AIIInstance {
    /// What `forget(groups:)` and `forgetMemory()` removed.
    public struct Forgotten: Sendable, Equatable {
        /// The groups that are gone, by the app's ids for them.
        public let groups: [String]
        /// The documents unlinked from the app.
        public let documentCount: Int
    }

    public nonisolated let app: AIIApp
    public nonisolated let displayName: String
    public nonisolated let bundleIdentifier: String?
    public nonisolated let home: AIIHome
    /// The owner this instance was made with, written to the lane on `join()`; nil to use the lane's.
    public nonisolated let requestedOwner: AIIOwner?
    public nonisolated let supervisor: AIISupervisor
    public nonisolated let client: AIIClient
    private let bundle: Bundle?
    private let appVersion: String?
    let wire: any ThreadWire
    private let session: URLSession
    private var joined: Bool
    /// How long `remember` waits for Thread to file what it accepted.
    let filingTimeout: Duration
    /// The last `remember`, which the next one waits for.
    var rememberChain: Task<Void, Never>?

    /// Whom the app's records are filed under, and whom Sewn answers as with no account:
    /// the owner this instance was made with, else the lane's in the manifest.
    public nonisolated var owner: AIIOwner {
        requestedOwner ?? home.lane(app)?.owner ?? AIILanes.defaultOwner(for: app)
    }

    /// An instance for the app `descriptor` names. `owner: .local` files under aii-local, the
    /// owner every app that opts in shares; nil keeps the lane's (local-<app> for a new one).
    public init(_ descriptor: any AIIAppDescriptor.Type, owner: AIIOwner? = nil, home: AIIHome = .resolved(),
                bundle: Bundle? = .main, appVersion: String? = nil, policy: SignaturePolicy = .standard,
                hold: AIISupervisor.Hold = .lease) {
        self.init(app: descriptor.app, displayName: descriptor.displayName, bundleIdentifier: descriptor.bundleIdentifier,
                  owner: owner, home: home, bundle: bundle, appVersion: appVersion, policy: policy, hold: hold)
    }

    /// An instance for the app named `app`.
    public init(app: AIIApp, displayName: String? = nil, bundleIdentifier: String? = nil, owner: AIIOwner? = nil,
                home: AIIHome = .resolved(), bundle: Bundle? = .main, appVersion: String? = nil,
                policy: SignaturePolicy = .standard, hold: AIISupervisor.Hold = .lease) {
        self.init(app: app, displayName: displayName, bundleIdentifier: bundleIdentifier, owner: owner, home: home,
                  bundle: bundle, appVersion: appVersion,
                  supervisor: AIISupervisor(app: app, home: home, policy: policy, hold: hold),
                  wire: PosixThreadWire(home: home, identity: .app(app)),
                  session: AIIAnswer.makeSession(), joined: false)
    }

    /// Tests: a wire and a session of their own, joined or not.
    init(app: AIIApp, displayName: String?, bundleIdentifier: String?, owner: AIIOwner? = nil, home: AIIHome,
         bundle: Bundle?, appVersion: String?, supervisor: AIISupervisor, wire: any ThreadWire, session: URLSession,
         joined: Bool, filingTimeout: Duration = .seconds(15)) {
        self.filingTimeout = filingTimeout
        self.app = app
        self.displayName = displayName ?? app.displayName
        self.bundleIdentifier = bundleIdentifier
        self.home = home
        self.requestedOwner = owner
        self.supervisor = supervisor
        self.client = AIIClient(app: app, home: home)
        self.bundle = bundle
        self.appVersion = appVersion
        self.wire = wire
        self.session = session
        self.joined = joined
    }

    // MARK: - Joining

    /// Registers the lane, installs the bundled build when the app ships one, adopts or
    /// starts the servers, and returns once both have proved the app's secret.
    public func join(timeout: TimeInterval = 60) async throws {
        try await supervisor.prepare(displayName: displayName, bundleIdentifier: bundleIdentifier, owner: requestedOwner)
        if let bundle {
            let version = appVersion
                ?? "\(displayName) \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"
            try await supervisor.install(from: bundle, appVersion: version)
        }
        var attempts = 0
        while true {
            do {
                try await supervisor.ensureRunning(timeout: timeout)
                break
            } catch ManagedServerError.sharedServerUnproven(_, _) where attempts < 2 {
                // Registered within the servers' two-second reload window: wait it out.
                attempts += 1
                try await Task.sleep(for: .milliseconds(2_500))
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = await supervisor.snapshot()
            if status.sewn.verified && status.thread.verified { break }
            guard Date() < deadline else { throw AIIInstanceError.notReady("\(status.phase)") }
            try await Task.sleep(for: .milliseconds(250))
        }
        joined = true
    }

    /// Every change to the stack's status, starting with the state now.
    public func status() async -> AsyncStream<AIIStatus> { await supervisor.statusStream() }

    /// Lets go of the app's hold; the servers stop when no other app holds them.
    public func leave() async {
        await supervisor.stop()
        joined = false
    }

    /// For a terminate handler that can't await.
    public nonisolated func shutdownSync() { supervisor.shutdownSync() }

    // MARK: - Asking

    /// One question, grounded in this app's lane and cited. With no `options.provider`, Sewn
    /// answers on device when the stack holds no key and through the provider whose key it
    /// holds otherwise; `.local` pins this Mac. No account either way.
    public nonisolated func ask(_ question: String, options: AIIAnswer.Options = .init()) -> AsyncThrowingStream<AIIAnswer.Event, Error> {
        AIIAnswer.stream(question: question, options: options, app: app, owner: owner.rawValue, home: home, session: session)
    }

    func requireJoined() throws {
        guard joined else { throw AIIInstanceError.notJoined }
    }
}
#endif
