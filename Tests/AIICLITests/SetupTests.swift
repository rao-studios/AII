//
//  SetupTests.swift
//  AIICLITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  What `aii setup` decides to do from what it finds: a Rao app's build is kept, a checkout
//  is built, nothing is asked without a terminal, and the models follow a running Sewn.
//

import AII
import Foundation
import XCTest
@testable import AIICLI

final class SetupTests: XCTestCase {
    private let checkout = URL(fileURLWithPath: "/src/AII", isDirectory: true)
    private let bundled = AIIInstallRecord(contract: 1, sha256: "ab", installedBy: .app(.ambient), source: .bundled,
                                           appVersion: "Ambient 1.0.0 (1)", installedAt: Date())
    private let mine = AIIInstallRecord(contract: 1, sha256: "ab", installedBy: .stack, source: .local,
                                        checkout: AIICheckoutRecord(path: "/src/AII", commit: "3f58458a1b2c", configuration: "release"),
                                        appVersion: "AII 3f58458a1b2c", installedAt: Date())

    func testARaoAppsUserKeepsTheAppsBuildAndIsAskedForOneKey() {
        let steps = SetupPlan.decide(installed: bundled, checkout: nil, missingKey: true, missingSupabase: true,
                                     interactive: true, sewnUp: false, options: .init())
        XCTAssertEqual(steps, [.promptKey, .hintSupabase, .keepInstall("Installed by Ambient 1.0.0 (1) · kept: a Rao app's build"), .start, .pullModels])
    }

    func testADeveloperWithACheckoutGetsABuild() {
        let steps = SetupPlan.decide(installed: nil, checkout: checkout, missingKey: true, missingSupabase: true,
                                     interactive: true, sewnUp: false, options: .init())
        XCTAssertEqual(steps, [.promptKey, .hintSupabase, .install(checkout, configuration: "release", build: true), .start, .pullModels])

        let debug = SetupPlan.decide(installed: nil, checkout: checkout, missingKey: false, missingSupabase: false,
                                     interactive: true, sewnUp: false, options: .init(noBuild: true, debug: true))
        XCTAssertEqual(debug, [.install(checkout, configuration: "debug", build: false), .start, .pullModels], "keys present: nothing asked, nothing hinted")
    }

    func testNothingIsAskedWithoutATerminalAndNothingBuiltWithoutACheckout() {
        let steps = SetupPlan.decide(installed: nil, checkout: nil, missingKey: true, missingSupabase: true,
                                     interactive: false, sewnUp: false, options: .init())
        XCTAssertEqual(steps, [.noteNoKey, .hintSupabase, .noInstall])

        let quiet = SetupPlan.decide(installed: nil, checkout: checkout, missingKey: true, missingSupabase: true,
                                     interactive: true, sewnUp: false, options: .init(noInstall: true, noPrompt: true))
        XCTAssertEqual(quiet, [.noteNoKey, .hintSupabase, .skippedInstall], "--no-prompt in a terminal still asks nothing; --no-install builds nothing")
    }

    func testAKeyByFlagIsNotAskedForAgain() {
        let steps = SetupPlan.decide(installed: mine, checkout: checkout, missingKey: true, missingSupabase: true,
                                     interactive: true, sewnUp: true, options: .init(mistralGiven: true, supabaseGiven: true))
        XCTAssertEqual(steps, [.keepInstall("Your build @ 3f58458a1b2c from /src/AII · already installed (aii update rebuilds it)"), .start, .pullModels])
    }

    func testTheModelsFollowARunningSewn() {
        let down = SetupPlan.decide(installed: mine, checkout: nil, missingKey: false, missingSupabase: false,
                                    interactive: true, sewnUp: false, options: .init(noStart: true))
        XCTAssertEqual(down, [.keepInstall("Your build @ 3f58458a1b2c from /src/AII · already installed (aii update rebuilds it)")], "nothing to pull from")
        let up = SetupPlan.decide(installed: mine, checkout: nil, missingKey: false, missingSupabase: false,
                                  interactive: true, sewnUp: true, options: .init(noStart: true))
        XCTAssertEqual(up.last, .pullModels)
        let none = SetupPlan.decide(installed: mine, checkout: nil, missingKey: false, missingSupabase: false,
                                    interactive: true, sewnUp: true, options: .init(noModels: true))
        XCTAssertEqual(none.last, .start)
    }
}
