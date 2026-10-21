//
//  Update.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii update`: rebuild your build from the checkout it came from, and install it again.
//

import AII
import ArgumentParser
import Foundation

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Rebuild your build from the checkout it came from and install it again.")

    func run() async throws {
        await guarded {
            guard let record = Stack.installer.installedRecord(), record.source == .local, let checkout = record.checkout else {
                throw AIIFailure.missing("no build of yours is installed", hint: "aii install <checkout>")
            }
            let root = URL(fileURLWithPath: checkout.path)
            guard AIICheckout.isCheckout(root) else {
                throw AIIFailure.missing("\(tilde(checkout.path)) is no longer an AII checkout", hint: "aii install <checkout>")
            }
            try await InstallCommand.install(from: root, configuration: checkout.configuration, build: true, verb: "update")
        }
    }
}
