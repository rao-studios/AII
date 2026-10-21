//
//  Stop.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii stop`: let go of the command's lease, and stop both servers when no app still
//        holds them. `--force` stops them anyway, naming who held them.
//

import AII
import ArgumentParser
import Foundation

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Release this command's lease and stop the servers when no app still holds them.")

    @Flag(name: .long, help: "Stop them even while an app holds them.")
    var force = false

    /// The refusal when apps still hold the stack and nobody said --force.
    static func refusal(holders: [StackIdentity], force: Bool, home: AIIHome) -> AIIFailure? {
        guard !holders.isEmpty, !force else { return nil }
        let names = holders.map { $0.displayName(in: home) }
        let who = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return .usage("\(who) hold\(names.count == 1 ? "s" : "") the stack; it stays up", hint: "pass --force to stop it anyway")
    }

    func run() async throws {
        await guarded {
            let home = Stack.home
            let supervisor = Stack.supervisor(hold: .pinned)
            await supervisor.release()
            let holders = Stack.leases.liveHolders()
            if let refusal = Self.refusal(holders: holders, force: force, home: home) { throw refusal }
            if force, !holders.isEmpty {
                note("stop: stopped under \(holders.map { $0.displayName(in: home) }.joined(separator: ", "))")
            }
            await supervisor.stop(force: force)
            print("Thread stopped · Sewn stopped")
        }
    }
}
