//
//  AIICommand.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii`: the Ambient Intelligence Index on this Mac — whose build is installed, the
//        two servers, the lanes, the models — from a terminal.
//  OUT:  Bare `aii` in an interactive terminal opens the studio; anywhere else it prints
//        `aii status`. Every other command is a subcommand.
//  PIN:  The type is AIICommand, never a module's name. AII_NO_UI keeps bare `aii` plain in
//        a terminal (as BRAID_NO_UI does for braid).
//

import AII
import ArgumentParser
import Foundation

@main
struct AIICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aii",
        abstract: "The Ambient Intelligence Index on this Mac: whose build is installed, the two servers, the lanes and the models.",
        discussion: "Bare `aii` in a terminal opens the studio; anywhere else it prints `aii status`.",
        version: "aii, contract \(AIIContract.version)",
        subcommands: [
            StatusCommand.self, DoctorCommand.self, SetupCommand.self,
            InstallCommand.self, UpdateCommand.self, UninstallCommand.self,
            StartCommand.self, StopCommand.self, RestartCommand.self, LogsCommand.self,
            LanesCommand.self, KeysCommand.self, ModelsCommand.self, ResetCommand.self,
        ])

    /// Whether bare `aii` opens the studio: a terminal on both ends, and nobody said not to.
    static func opensStudio(environment: [String: String], interactive: Bool) -> Bool {
        interactive && environment["AII_NO_UI"] == nil && environment["TERM"] != "dumb"
    }

    func run() async throws {
        let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        if Self.opensStudio(environment: ProcessInfo.processInfo.environment, interactive: interactive) {
            await guarded { try await Studio.launch() }
        } else {
            try await StatusCommand.parse([]).run()
        }
    }
}
