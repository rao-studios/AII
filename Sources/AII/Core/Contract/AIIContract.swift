//
//  AIIContract.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The version of the stack contract this build speaks. Sewn and Thread
//        report it on /health; the installer compares it before replacing AIIServer
//        in ~/.rao/aii/bin; a supervisor restarts a server that is older.
//  PIN:  Bump `version` when a change to Sewn, Thread or this package means an
//        app built against the old contract can't use the new stack as-is (a
//        new required header, a new file the servers depend on, a new port).
//        Adding a field every reader ignores is not a bump.
//        1: the Ambient Intelligence Index — one AIIServer binary in two roles, one
//        Thread for every app, lanes, the stack identity `aii`, the ~/.rao/aii
//        layout, the device key, AII_HOME and X-AII-App on the wire.
//

public enum AIIContract {
    /// The stack contract: /health, the wire, the launch arguments.
    public static let version = 1
    /// The ~/.rao layout (layout.json's `version`).
    public static let layoutVersion = 1
    /// The envelope every document in a lane is filed in (AIIRecord).
    public static let recordFormat = "aii-record/1"
}
