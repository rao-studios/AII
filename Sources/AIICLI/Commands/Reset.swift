//
//  Reset.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii reset`: bring the home back to a fresh layout-1 state — the servers stopped,
//        the installed build, its record, the run records, the leases and layout.json gone.
//  PIN:  A dry run unless --yes. Refuses while an app holds the stack (quit it first).
//        Keeps secrets, keys, the index, Sewn's data, the lanes, aii.env, models and this
//        command (AIIReset).
//

import AII
import ArgumentParser
import Foundation

struct ResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Bring the home back to a fresh layout-1 state, keeping secrets, keys, data and models; a dry run without --yes.")

    @Flag(name: .long, help: "Do it: without this, only say what would go.")
    var yes = false

    func run() async throws {
        await guarded {
            let home = Stack.home
            if let app = Stack.leases.live().first(where: { !$0.pinned }) {
                throw AIIFailure.temporary("\(app.identity.displayName(in: home)) is running", hint: "quit it first")
            }
            let status = await Stack.supervisor(hold: .none).inspect()
            let running = status.servers.compactMap { detail in detail.pid.map { "\(detail.role.displayName) (pid \($0))" } }
            let plan = AIIReset.plan(home: home)
            if !yes {
                if !running.isEmpty { print("would stop    \(running.joined(separator: ", "))") }
                for path in plan { print("would remove  \(tilde(path))") }
                print("dry run — nothing removed; run again with --yes")
                return
            }
            if !running.isEmpty {
                print("stopping      \(running.joined(separator: ", "))")
                await Stack.supervisor(hold: .none).stop(force: true)
            }
            for path in plan { print("removing      \(tilde(path))") }
            try AIIReset.apply(plan)
        }
    }
}
