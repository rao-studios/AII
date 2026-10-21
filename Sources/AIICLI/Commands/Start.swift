//
//  Start.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii start`: both servers up — adopted when running, started when not — held by
//        the command's pinned lease until `aii stop`.
//

import AII
import ArgumentParser
import Foundation

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start both servers as the stack identity and hold them with a pinned lease until aii stop.")

    func run() async throws {
        await guarded {
            let supervisor = Stack.supervisor(hold: .pinned)
            try await supervisor.prepare()
            try await supervisor.ensureRunning()
            await printServers()
        }
    }
}

/// The two server rows and the holders, as `aii status` prints them.
func printServers() async {
    let report = await StatusReport.gather()
    for server in report.servers { print(Render.server(server)) }
    print(Render.row("held by", Render.holders(report.holders)))
}
