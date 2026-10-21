//
//  StudioBackend.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What the studio's keys do, off the UI loop: read the stack, the lanes, the models,
//        the logs and the checks; walk a lane down the stack; install, update, start, stop,
//        restart; add lanes, switch their owners, remove them; pull and remove models. Each
//        answer goes back through the mailbox.
//  PIN:  Each job calls what its CLI verb calls — StatusReport.gather, Checks.all,
//        LaneDoctor.run, AIIInstaller, the stack's supervisor, AIIHome.register and setOwner —
//        so the studio adds no logic of its own. A job already running isn't started twice.
//

import AII
import Foundation

final class StudioBackend: @unchecked Sendable {
    private let mailbox: Mailbox<StudioEvent>
    private let home: AIIHome
    private let lock = NSLock()
    private var running: Set<String> = []

    init(mailbox: Mailbox<StudioEvent>, home: AIIHome) {
        self.mailbox = mailbox
        self.home = home
    }

    func submit(_ job: StudioJob) {
        let key = "\(job)"
        guard lock.withLock({ running.insert(key).inserted }) else { return }
        Task.detached { [self] in
            await run(job)
            lock.withLock { _ = running.remove(key) }
        }
    }

    private func run(_ job: StudioJob) async {
        let home = self.home
        switch job {
        case .refresh:
            mailbox.post(.report(await StatusReport.gather(home: home)))
        case .lanes:
            mailbox.post(.lanes(await Self.laneRows(home: home)))
        case .models:
            let report = await StatusReport.gather(home: home)
            mailbox.post(.models(report.models, problem: report.modelsProblem))
        case .doctor:
            mailbox.post(.checks(await Checks.all(home: home)))
        case .laneDoctor(let name):
            guard let app = try? AIIApp.named(name) else {
                mailbox.post(.laneDoctor(name, [.fail("manifest", "\(name) isn't a lane name")]))
                return
            }
            mailbox.post(.laneDoctor(name, await LaneDoctor.run(app, home: home)))
        case .logs(let role):
            mailbox.post(.log(role, Self.tail(role == .sewn ? home.sewnLogFile : home.threadLogFile)))
        case .install:
            await act("installing your build") {
                let root = try CheckoutResolver.resolve(argument: nil, home: home)
                return try await self.install(from: root, configuration: "release")
            }
        case .update:
            await act("updating your build") {
                guard let checkout = AIIInstaller(home: home).installedRecord()?.checkout else {
                    throw AIIFailure.missing("no build of yours is installed", hint: "press i")
                }
                return try await self.install(from: URL(fileURLWithPath: checkout.path), configuration: checkout.configuration)
            }
        case .start:
            await act("starting the stack") {
                let supervisor = AIISupervisor(identity: .stack, home: home, policy: .standard, hold: .pinned)
                try await supervisor.prepare()
                try await supervisor.ensureRunning()
                return "Sewn and Thread are up, held by aii"
            }
        case .stop:
            await act("stopping the stack") {
                let supervisor = AIISupervisor(identity: .stack, home: home, policy: .standard, hold: .pinned)
                await supervisor.release()
                if let refusal = StopCommand.refusal(holders: AIILeases(home: home).liveHolders(), force: false, home: home) {
                    throw refusal
                }
                await supervisor.stop()
                return "Thread stopped · Sewn stopped"
            }
        case .restart:
            await act("restarting the stack") {
                let pinned = PrivateFile.exists(home.aiiPinnedLease(for: .stack))
                let supervisor = AIISupervisor(identity: .stack, home: home, policy: .standard, hold: pinned ? .pinned : .none)
                try await supervisor.prepare()
                try await supervisor.restart(.all)
                return "restarted onto the installed build"
            }
        case .addLane(let name, let displayName):
            await act("adding \(name)") {
                let app = try AIIApp.named(name)
                let lane = try home.register(app, displayName: displayName, by: .stack)
                return "registered \(app.rawValue) (\(lane.displayName)) · owner \(lane.owner)"
            }
        case .setLaneOwner(let name, let owner):
            await act("switching \(name)'s owner") {
                let app = try AIIApp.named(name)
                let owner = try LanesCommand.owner(owner, for: app)
                try home.setOwner(owner, for: app)
                return "\(app.rawValue) files under \(owner) with no account from now on; documents already filed keep theirs"
            }
        case .removeLane(let name):
            await act("removing \(name)") {
                let app = try AIIApp.named(name)
                if AIILeases(home: home).live().contains(where: { $0.identity == .app(app) && !$0.pinned }) {
                    throw AIIFailure.temporary("\(app.displayName(in: home)) is running and holds the stack", hint: "quit it first")
                }
                try home.unregister(app)
                return "removed \(app.rawValue)'s secret and manifest entry; its documents stay"
            }
        case .pull(let role):
            await act("pulling \(role.rawValue)") {
                let entry = AIIModels.entry(role: role)
                let client = AIIClient(identity: .stack, home: home)
                try await client.download(model: entry.id)
                while true {
                    try await Task.sleep(for: .seconds(1))
                    switch try await client.models([entry]).first?.disk ?? .absent {
                    case .installed: return "\(role.rawValue) is on this Mac"
                    case .downloading(let fraction): self.mailbox.post(.progress("\(role.rawValue) \(Int((fraction ?? 0) * 100))%"))
                    case .failed(let reason): throw AIIFailure.data("\(role.rawValue) failed to download\(reason.map { ": \($0)" } ?? "")")
                    case .absent, .unknown: continue
                    }
                }
            }
        case .removeModel(let role):
            await act("removing \(role.rawValue)") {
                try await AIIClient(identity: .stack, home: home).remove(model: AIIModels.entry(role: role).id)
                return "removed \(role.rawValue)"
            }
        }
    }

    /// An action: `busy` first, then what it did or why it couldn't.
    private func act(_ label: String, _ body: () async throws -> String) async {
        mailbox.post(.busy(label))
        do {
            mailbox.post(.done(try await body()))
        } catch {
            let failure = AIIFailure.from(error)
            mailbox.post(.failed(failure.message, hint: failure.hint))
        }
    }

    private func install(from root: URL, configuration: String) async throws -> String {
        let mailbox = self.mailbox
        let built = await AIIInstaller.build(checkout: root, configuration: configuration) { mailbox.post(.progress($0)) }
        guard built else { throw AIIFailure.internalError("Scripts/build-servers.sh failed", hint: "aii install shows its output") }
        let outcome = try AIIInstaller(home: home).installLocal(from: root, configuration: configuration)
        var message = "installed \(tildeInText(outcome.record.summary))"
        if case .alreadyCurrent = outcome { message = "already installed: \(tildeInText(outcome.record.summary))" }
        if InstallCommand.runningPreviousBuild(home: home) != nil { message += " · press r to restart onto it" }
        return message
    }

    static func laneRows(home: AIIHome) async -> [LaneRow] {
        let counts = await LanesCommand.List.documentCounts(home: home)
        return home.registeredApps().map { app in
            let lane = home.lane(app)
            return LaneRow(name: app.rawValue, displayName: lane?.displayName ?? app.displayName, lane: lane?.id.rawValue,
                           owner: lane?.owner.rawValue, secret: (try? home.readSecret(for: app)) != nil,
                           registeredBy: lane?.registeredBy.displayName(in: home), registeredAt: lane?.registeredAt,
                           bundleIdentifier: lane?.bundleIdentifier, documents: lane.flatMap { counts?[$0.id] })
        }
    }

    /// The last lines of a log: its final 64 KB.
    static func tail(_ file: URL, lines: Int = 400) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).map(String.init)
    }
}
