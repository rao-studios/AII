//
//  Label.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `aii label [<text>] [--clear]`: the AII's own name — printed, set or taken
//        away. Both servers say it on /health, so whoever finds this AII on a port
//        sees it by name.
//  PIN:  The file only (AIILabel): no secret, no server asked. A running server says
//        the new label at its next /health; a stopped one, when it starts. The home is
//        AII_HOME's, as for every command, so `AII_HOME=<home> aii label …` names any
//        AII home on this Mac.
//

import AII
import ArgumentParser
import Foundation

struct LabelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label",
        abstract: "The AII's own name, said on /health: print it, set it, or clear it.",
        discussion: "One line of 1 to \(AIILabel.maximumLength) characters. Public: whoever finds this AII by its port reads it.")

    @Argument(help: "The new label. Without it, the label is printed.")
    var text: String?

    @Flag(help: "Take the label away.")
    var clear = false

    func validate() throws {
        if clear, text != nil { throw ValidationError("give a label or --clear, not both") }
    }

    func run() async throws {
        await guarded {
            let home = Stack.home
            if clear {
                AIILabel.clear(home: home)
                note("label cleared in \(tilde(home.aiiDirectory))")
                return
            }
            guard let text else {
                guard let label = AIILabel.read(home: home) else {
                    throw AIIFailure.missing("no label in \(tilde(home.aiiDirectory))", hint: "aii label <text>")
                }
                print(label)
                return
            }
            guard AIILabel.normalized(text) != nil else { throw AIIFailure.usage(AIILabelError.invalid(text).description) }
            print(try AIILabel.write(text, home: home))
        }
    }
}
