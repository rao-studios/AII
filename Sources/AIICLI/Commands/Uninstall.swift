//
//  Uninstall.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii uninstall`: hand the install back to the apps. Your build and its record go;
//        the next Rao app to launch installs its own copy.
//  PIN:  Only your own build, only with the servers stopped, only with --yes. Data, models,
//        secrets, lanes and aii.env stay.
//

import AII
import ArgumentParser
import Foundation

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove your build and its record so the next app launch installs its bundled copy.")

    @Flag(name: .long, help: "Remove it: nothing is removed without this.")
    var yes = false

    /// Why it can't be done now, or nil.
    static func refusal(record: AIIInstallRecord?, serversUp: Bool, yes: Bool, home: AIIHome) -> AIIFailure? {
        guard let record else { return .missing("nothing is installed in \(tilde(home.aiiBinDirectory))") }
        guard record.source == .local else {
            return .missing("the installed build is \(record.installedBy.displayName(in: home))'s, not yours",
                            hint: "its app manages it; aii install makes one yours")
        }
        if serversUp { return .temporary("Sewn and Thread are running", hint: "aii stop first") }
        if !yes { return .usage("pass --yes to remove your build from \(tilde(home.aiiBinDirectory))") }
        return nil
    }

    func run() async throws {
        await guarded {
            let home = Stack.home
            let record = Stack.installer.installedRecord()
            let status = await Stack.supervisor(hold: .none).inspect()
            let up = status.sewn.state != .stopped || status.thread.state != .stopped
            if let refusal = Self.refusal(record: record, serversUp: up, yes: yes, home: home) { throw refusal }
            try Stack.installer.uninstall()
            print("removed \(tildeInText(record!.summary))")
            print("→ the next Rao app to launch installs its own copy")
        }
    }
}
