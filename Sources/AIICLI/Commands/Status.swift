//
//  Status.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii status`: whose build is installed, the contract, both servers, who holds
//        them, the lanes and the models on this Mac.
//  PIN:  Looks only: holds no lease, starts nothing. Exits 0 whatever it finds; `aii doctor`
//        is what judges.
//

import AII
import ArgumentParser
import Foundation

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Whose build is installed, the contract, both servers, who holds them, the lanes and the models on this Mac.")

    @Flag(name: .long, help: "Print the report as JSON.")
    var json = false

    func run() async throws {
        await guarded {
            let report = await StatusReport.gather()
            if json {
                print(try report.json())
            } else {
                for line in Render.status(report) { print(line) }
            }
        }
    }
}
