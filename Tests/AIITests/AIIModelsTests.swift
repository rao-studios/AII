//
//  AIIModelsTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import XCTest
@testable import AII

/// The master list of base models: one entry per role, every entry pinned to a commit,
/// so every app and both servers fetch the same bytes.
final class AIIModelsTests: XCTestCase {
    func testOneEntryPerRoleAndEveryRoleListed() {
        let roles = AIIModels.all.map(\.role)
        XCTAssertEqual(Set(roles).count, roles.count, "a role appears once")
        XCTAssertEqual(Set(roles), Set(AIIModels.Role.allCases), "every role has its model")
        for role in AIIModels.Role.allCases {
            XCTAssertEqual(AIIModels.entry(role: role).role, role)
        }
    }

    func testIdsAreHubRepositoriesAndLookupIgnoresCase() {
        for entry in AIIModels.all {
            let parts = entry.id.split(separator: "/")
            XCTAssertEqual(parts.count, 2, "\(entry.id) is org/repo")
            XCTAssertTrue(parts.allSatisfy { !$0.isEmpty }, entry.id)
            XCTAssertEqual(AIIModels.entry(id: entry.id.uppercased())?.id, entry.id)
        }
        XCTAssertNil(AIIModels.entry(id: "nobody/nothing"))
    }

    /// Since 2026-10-14 every entry is pinned: the coding model's mirror is published.
    func testEveryModelIsPinnedToAFullCommit() {
        for entry in AIIModels.all {
            XCTAssertEqual(entry.revision?.count, 40, "\(entry.id) is pinned to a 40-hex commit")
            XCTAssertTrue(entry.revision?.allSatisfy(\.isHexDigit) ?? false, entry.id)
            XCTAssertTrue(entry.isInstallable, entry.id)
            XCTAssertEqual(entry.pinnedSpec, "\(entry.id)@\(entry.revision!)")
        }
    }

    func testTheCodingModelIsRaosMirrorOfTheReapCheckpoint() {
        XCTAssertEqual(AIIModels.coding.id, "rao-studios/Qwen3-Coder-Next-REAP-48B-A3B-mlx-4bit")
        XCTAssertEqual(AIIModels.coding.family, "qwen3_next")
        XCTAssertEqual(AIIModels.coding.vendor, .qwen)
        XCTAssertEqual(AIIModels.coding.downloadBytes, 27_507_938_455, "the Hub tree at the mirrored commit")
    }

    func testSizesAreConsistent() {
        for entry in AIIModels.all {
            XCTAssertGreaterThanOrEqual(entry.downloadBytes, entry.weightsBytes, "\(entry.id): the tree holds the weights")
            XCTAssertGreaterThan(entry.minimumMemoryGB, 0, entry.id)
        }
    }

    func testKeptIsWhatThreadRuns() {
        XCTAssertEqual(AIIModels.kept, [AIIModels.generalStandard.id, AIIModels.embedding.id])
        XCTAssertTrue(AIIModels.kept.isSubset(of: Set(AIIModels.all.map(\.id))))
        XCTAssertEqual(AIIModels.general.map(\.role), [.generalSmall, .generalStandard, .generalLarge], "smallest first")
    }
}
