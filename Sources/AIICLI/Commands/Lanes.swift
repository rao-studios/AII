//
//  Lanes.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii lanes`: every app's lane on this Mac, from the lanes manifest; adding one,
//        changing its no-account owner, removing one, and walking one down the stack.
//  OUT:  `list` (the default), `add`, `owner`, `remove`, `doctor`.
//  PIN:  A lane is two files: its secret and its entry in aii/lanes.json. Adding keeps the
//        first registration's display name. An owner is aii-local, shared by every app that
//        opts in, or local-<name>, the app's own; documents already filed keep theirs.
//        Removing leaves the documents in Thread. The doctor writes nothing.
//

import AII
import ArgumentParser
import Foundation

struct LanesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lanes",
        abstract: "Every app's lane on this Mac: list, add, change its owner, remove, or check one.",
        subcommands: [List.self, Add.self, Owner.self, Remove.self, Doctor.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Each app's display name, owner, lane id, secret and documents.")

        func run() async throws {
            await guarded {
                let home = Stack.home
                let apps = home.registeredApps()
                guard !apps.isEmpty else {
                    throw AIIFailure.missing("no lanes registered yet", hint: "launch a Rao app, or aii lanes add <name>")
                }
                let lanes = (try? AIILanes.load(home: home)) ?? nil
                let counts = await Self.documentCounts(home: home)
                for line in LanesCommand.rows(apps: apps, home: home, lanes: lanes, counts: counts) { print(line) }
            }
        }

        /// Documents per lane, when Thread answers.
        static func documentCounts(home: AIIHome) async -> [LaneID: Int]? {
            guard let stats = try? await AIIClient(identity: .stack, home: home).stats(), let lanes = stats.lanes else { return nil }
            return Dictionary(lanes.map { ($0.lane, $0.documents) }, uniquingKeysWith: +)
        }
    }

    static func rows(apps: [AIIApp], home: AIIHome, lanes: AIILanes?, counts: [LaneID: Int]?) -> [String] {
        apps.map { app in
            let lane = lanes?.lane(for: app)
            let secret = (try? home.readSecret(for: app)) != nil
            var parts = [
                app.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                    + (lane?.displayName ?? app.displayName).padding(toLength: 16, withPad: " ", startingAt: 0)
                    + (lane?.owner.rawValue ?? "–").padding(toLength: 14, withPad: " ", startingAt: 0)
                    + (lane?.id.rawValue ?? "no lane").padding(toLength: 38, withPad: " ", startingAt: 0)
                    + "secret \(secret ? "✓" : "✗")",
            ]
            if let counts, let id = lane?.id { parts.append("\(counts[id] ?? 0) documents") }
            if lane == nil { parts.append("→ aii lanes add \(app.rawValue)") }
            return parts.joined(separator: " · ")
        }
    }

    /// `aii-local` or `local-<name>`, as typed.
    static func owner(_ text: String, for app: AIIApp) throws -> AIIOwner {
        let owner = AIIOwner(rawValue: text.lowercased())
        guard owner.isLaneOwner(for: app) else {
            throw AIIFailure.usage("\"\(text)\" can't own \(app.rawValue)'s lane", hint: "aii-local or local-\(app.rawValue)")
        }
        return owner
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Register a lane from the terminal: a secret and a manifest entry, the first time only.")

        @Argument(help: "The app's name: 2 to 32 of a-z and 0-9, starting with a letter.")
        var name: String

        @Option(name: .customLong("display"), help: "How people read it. Default: the name, capitalized.")
        var displayName: String?

        @Option(name: .long, help: "Whom its records are filed under with no account: aii-local (shared) or local-<name> (its own, the default).")
        var owner: String?

        func run() async throws {
            await guarded {
                let app = try AIIApp.named(name)
                let home = Stack.home
                let owner = try owner.map { try LanesCommand.owner($0, for: app) }
                let existed = home.lane(app) != nil
                let lane = try home.register(app, displayName: displayName, owner: owner, by: .stack)
                print("\(existed ? "already registered" : "registered") \(app.rawValue) (\(lane.displayName)) · owner \(lane.owner) · lane \(lane.id)")
                if existed, let displayName, displayName != lane.displayName {
                    note("lanes: the first registration's display name stays: \(lane.displayName)")
                }
            }
        }
    }

    struct Owner: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "owner",
            abstract: "Set whom a lane's records are filed under with no account: aii-local or local-<name>.")

        @Argument(help: "The app's name.")
        var name: String

        @Argument(help: "aii-local, shared by every app that opts in, or local-<name>, the app's own.")
        var owner: String

        func run() async throws {
            await guarded {
                let app = try AIIApp.named(name)
                let home = Stack.home
                guard let lane = home.lane(app) else { throw AIIFailure.missing("\(app.rawValue) has no lane here", hint: "aii lanes add \(app.rawValue)") }
                let owner = try LanesCommand.owner(owner, for: app)
                guard owner != lane.owner else {
                    print("\(app.rawValue) already files under \(owner)")
                    return
                }
                try home.setOwner(owner, for: app)
                print("\(app.rawValue) now files under \(owner) with no account (was \(lane.owner))")
                note("lanes: documents already filed keep the owner they were filed under; Sewn answers as \(owner) from now on")
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a lane's secret and manifest entry; its documents stay in Thread.")

        @Argument(help: "The app's name.")
        var name: String

        @Flag(name: .long, help: "Remove it: nothing is removed without this.")
        var yes = false

        func run() async throws {
            await guarded {
                let app = try AIIApp.named(name)
                let home = Stack.home
                guard home.registeredApps().contains(app) else { throw AIIFailure.missing("\(app.rawValue) has no lane here") }
                if Stack.leases.live().contains(where: { $0.identity == .app(app) && !$0.pinned }) {
                    throw AIIFailure.temporary("\(app.displayName(in: home)) is running and holds the stack", hint: "quit it first")
                }
                guard yes else { throw AIIFailure.usage("pass --yes to remove \(app.rawValue)'s secret and manifest entry") }
                try home.unregister(app)
                print("removed \(app.rawValue)'s secret and manifest entry")
                print("  its documents stay in Thread; aii lanes add \(app.rawValue) finds them again")
            }
        }
    }

    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "doctor",
            abstract: "Walk a lane down the stack, layer by layer, and say which layer to fix; writes nothing.")

        @Argument(help: "The app's name. Default: every lane.")
        var name: String?

        func run() async throws {
            await guarded {
                let home = Stack.home
                let apps = try name.map { [try AIIApp.named($0)] } ?? home.registeredApps()
                guard !apps.isEmpty else { throw AIIFailure.missing("no lanes registered yet", hint: "aii lanes add <name>") }
                var failed = 0
                for app in apps {
                    print("\(app.rawValue)")
                    let checks = await LaneDoctor.run(app, home: home)
                    for check in checks { print(check.line) }
                    if checks.contains(where: { !$0.ok }) { failed += 1 }
                }
                print(failed == 0 ? "every lane passed" : "\(failed) lane\(failed == 1 ? "" : "s") need\(failed == 1 ? "s" : "") a fix")
                if failed > 0 { throw ExitCode(Exit.doctor.rawValue) }
            }
        }
    }
}
