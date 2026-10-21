//
//  InstallTests.swift
//  AIICLITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  `aii install` hands a checkout's .env keys to keys/providers.json and says what landed;
//  where a checkout is looked for, and that none found is an answer, not an error.
//

import AII
import Foundation
import XCTest
@testable import AIICLI

final class InstallTests: XCTestCase {

    func testTheCheckoutsKeysLandInProvidersJSONAndAnAccountsKeyIsKept() throws {
        let scratch = ScratchHome()
        try scratch.home.provision(by: .ambient)
        let checkout = scratch.url.appendingPathComponent("checkout", isDirectory: true)
        _ = try scratch.file("checkout/.env", contents: "MISTRAL_API_KEY=mistral-key-0000\nTINKER_API_KEY=tinker-key-1111\nSUPABASE_URL=u\n", mode: 0o600)
        try ProviderKeyStore(home: scratch.home).write(ProviderKeyStore.tinkerAPIKey, value: "from-account", source: .account, writtenBy: .ambient)

        let outcome = InstallCommand.adoptProviderKeys(from: checkout, home: scratch.home)
        XCTAssertEqual(outcome, [ProviderKeyStore.mistralAPIKey: .set, ProviderKeyStore.tinkerAPIKey: .keptAccount])
        let records = ProviderKeyStore(home: scratch.home).records()
        XCTAssertEqual(records[ProviderKeyStore.mistralAPIKey]?.value, "mistral-key-0000")
        XCTAssertEqual(records[ProviderKeyStore.mistralAPIKey]?.writtenBy, .stack)
        XCTAssertEqual(records[ProviderKeyStore.tinkerAPIKey]?.value, "from-account")
        XCTAssertEqual(PrivateFile.ownerAndMode(scratch.home.providersFile)?.mode, 0o600)

        let lines = InstallCommand.adoptionLines(outcome, records: records, home: scratch.home)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("MISTRAL_API_KEY set (…0000)"), lines[0])
        XCTAssertFalse(lines[0].contains("mistral-key"), "never the value")
        XCTAssertTrue(lines[1].hasSuffix("TINKER_API_KEY kept: Ambient's account key"), lines[1])

        XCTAssertEqual(InstallCommand.adoptProviderKeys(from: checkout, home: scratch.home),
                       [ProviderKeyStore.mistralAPIKey: .alreadySet, ProviderKeyStore.tinkerAPIKey: .keptAccount], "a second run changes nothing")
        XCTAssertEqual(InstallCommand.adoptProviderKeys(from: scratch.url, home: scratch.home), [:], "no .env, nothing to say")
    }

    func testLocatingACheckoutFindsNoneWithoutFailing() throws {
        let scratch = ScratchHome()
        let nowhere = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        XCTAssertNil(try CheckoutResolver.locate(argument: nil, environment: [:], home: scratch.home,
                                                 binary: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: nowhere))
        XCTAssertThrowsError(try CheckoutResolver.resolve(argument: nil, environment: [:], home: scratch.home,
                                                          binary: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: nowhere, verb: "setup")) { error in
            XCTAssertEqual((error as? AIIFailure)?.code, .usage)
            XCTAssertEqual((error as? AIIFailure)?.hint, "pass one: aii setup ~/Documents/rao/repositories/AII")
        }
        XCTAssertThrowsError(try CheckoutResolver.locate(argument: "/private/tmp", environment: [:], home: scratch.home,
                                                         binary: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: nowhere)) { error in
            XCTAssertEqual((error as? AIIFailure)?.code, .usage, "a named folder that isn't a checkout is still an error")
        }
    }
}
