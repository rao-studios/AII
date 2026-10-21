//
//  Models.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii models`: every pinned model, whether it is on this Mac; fetching one;
//        removing one.
//  PIN:  Through Sewn, which owns the models folder: so Sewn must be up. Sewn refuses to
//        remove what the index runs on, or what is loaded or downloading, and says so.
//

import AII
import ArgumentParser
import Foundation

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "The pinned models: which are on this Mac, fetch one, remove one.",
        subcommands: [List.self, Pull.self, Remove.self],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Every pinned model, its revision, and whether it is on this Mac.")

        func run() async throws {
            await guarded {
                let states = try await ModelsCommand.states()
                for line in ModelsCommand.rows(states) { print(line) }
            }
        }
    }

    static func states() async throws -> [AIIModelState] {
        do {
            return try await Stack.client().models()
        } catch AIIClientError.transport(let reason) {
            throw AIIFailure.unavailable("Sewn doesn't answer: \(AIIFailure.sentence(reason))", hint: "aii start")
        }
    }

    static func rows(_ states: [AIIModelState]) -> [String] {
        AIIModels.all.map { entry in
            let state = states.first { $0.id == entry.id }?.disk ?? .absent
            let head = entry.role.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)
                + entry.id.padding(toLength: 56, withPad: " ", startingAt: 0)
                + "@ \(entry.revision.map { String($0.prefix(8)) } ?? "unpinned")  "
            let kept = AIIModels.kept.contains(entry.id) ? " · kept" : ""
            switch state {
            case .installed: return head + "✓ on this Mac" + kept
            case .downloading(let fraction): return head + "… downloading" + (fraction.map { " \(Int($0 * 100))%" } ?? "")
            case .failed(let reason): return head + "✗ failed" + (reason.map { ": \($0)" } ?? "") + " → aii models pull \(entry.role.rawValue)"
            case .absent: return head + "✗ absent → aii models pull \(entry.role.rawValue)"
            case .unknown(let raw): return head + raw
            }
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Fetch a pinned model at its commit, and wait for it.")

        @Argument(help: "The model's role: embedding, generalSmall, generalStandard, generalLarge, vision or coding.")
        var role: AIIModels.Role

        func run() async throws {
            await guarded { try await ModelsCommand.pull(role) }
        }
    }

    /// Fetch one pinned model through Sewn and wait for it, saying how far it is. What
    /// `aii models pull` runs, and what `aii setup` runs for the two the index needs.
    static func pull(_ role: AIIModels.Role) async throws {
        let entry = AIIModels.entry(role: role)
        let client = Stack.client()
        if try await states().first(where: { $0.id == entry.id })?.disk == .installed {
            print("\(role.rawValue) is already on this Mac")
            return
        }
        try await client.download(model: entry.id)
        var last = -1
        while true {
            try await Task.sleep(for: .seconds(1))
            let state = try await client.models([entry]).first?.disk ?? .absent
            switch state {
            case .installed:
                print("\(role.rawValue) is on this Mac: \(entry.pinnedSpec)")
                return
            case .downloading(let fraction):
                let percent = Int((fraction ?? 0) * 100)
                if percent != last { note("models: \(role.rawValue) \(percent)%"); last = percent }
            case .failed(let reason):
                throw AIIFailure.data("\(role.rawValue) failed to download\(reason.map { ": \($0)" } ?? "")",
                                      hint: "aii logs sewn")
            case .absent, .unknown:
                continue
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Delete a pinned model from this Mac.")

        @Argument(help: "The model's role.")
        var role: AIIModels.Role

        @Flag(name: .long, help: "Remove it: nothing is removed without this.")
        var yes = false

        func run() async throws {
            await guarded {
                guard yes else { throw AIIFailure.usage("pass --yes to delete \(role.rawValue) from this Mac") }
                let entry = AIIModels.entry(role: role)
                try await Stack.client().remove(model: entry.id)
                print("removed \(role.rawValue) (\(entry.id))")
            }
        }
    }
}
