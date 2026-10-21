//
//  Doctor.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii doctor`: every check, each with its fix.
//  PIN:  Writes nothing. Exits 1 when a check fails.
//

import AII
import ArgumentParser
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the home, the keys, the lanes, the installed build, both servers, the models and this command; writes nothing.")

    func run() async throws {
        await guarded {
            let checks = await Checks.all(home: Stack.home)
            for line in Self.lines(checks) { print(line) }
            if checks.contains(where: { !$0.ok }) { throw ExitCode(Exit.doctor.rawValue) }
        }
    }

    /// The header, one line per check, and the count: what `aii doctor` prints, and what
    /// `aii setup` ends with.
    static func lines(_ checks: [DoctorCheck]) -> [String] {
        let failed = checks.filter { !$0.ok }.count
        return ["aii doctor"] + checks.map(\.line)
            + [failed == 0 ? "all checks passed" : "\(failed) check\(failed == 1 ? "" : "s") failed"]
    }
}
