//
//  Restart.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii restart [sewn|thread]`: stop the target, whoever holds it, and start the
//        installed build in its place. The apps holding it follow to the new one.
//  PIN:  Neither adds nor drops a hold: pinned if the command already held the stack.
//

import AII
import ArgumentParser
import Foundation

struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Stop the target, whoever holds it, and start the installed build in its place.")

    @Argument(help: "sewn or thread. Default: both.")
    var role: LaunchSpec.Role?

    func run() async throws {
        await guarded {
            let pinned = PrivateFile.exists(Stack.home.aiiPinnedLease(for: .stack))
            let supervisor = Stack.supervisor(hold: pinned ? .pinned : .none)
            try await supervisor.prepare()
            switch role {
            case .sewn: try await supervisor.restart(.sewn)
            case .thread: try await supervisor.restart(.thread)
            case nil: try await supervisor.restart(.all)
            }
            await printServers()
        }
    }
}
