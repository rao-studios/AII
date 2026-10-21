//
//  AIIServerCommand.swift
//  AIIServer
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The one binary of the Ambient Intelligence Index. It starts the server named on its
//        command line — `AIIServer sewn …` or `AIIServer thread …`, each with that server's own
//        options — or runs the probe (`AIIServer probe …`), a terminal client for Sewn's chat wire.
//  IN:   The supervisor (AIISupervisor, through LaunchSpecs) runs it twice, once per role, from
//        ~/.rao/aii/bin/AIIServer; Scripts/build-servers.sh builds it into .build/<config>/.
//  PIN:  Nothing lives here but the dispatch: the servers are the Sewn and Thread libraries, so
//        their tests link them without an entry point. The type is not named AIIServer — that is
//        the module's name, and a type of one name with a module breaks qualified lookup.
//

import ArgumentParser
import Sewn
import Thread

@main
struct AIIServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "AIIServer",
        abstract: "The Ambient Intelligence Index's servers, and a probe for Sewn's chat wire.",
        subcommands: [SewnServer.self, ThreadServer.self, SewnProbe.self])
}
