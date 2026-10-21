//
//  GraphExtractionModelSpecTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The on-device extraction model loads at the revision its spec pins: `org/repo@<revision>`
//  is a repo and a commit, never one repo id (which the Hub would look up at `main` and miss).
//

#if canImport(MLXLMCommon)
import AII
import MLXLMCommon
import XCTest
@testable import Thread

final class GraphExtractionModelSpecTests: XCTestCase {

    func testAPinnedSpecLoadsItsRevision() {
        let pinned = MLXGraphExtractionProvider.configuration(for: AIIModels.generalStandard.pinnedSpec)
        guard case .id(let id, let revision) = pinned.id else { return XCTFail("\(pinned.id)") }
        XCTAssertEqual(id, AIIModels.generalStandard.id)
        XCTAssertEqual(revision, AIIModels.generalStandard.revision)

        let bare = MLXGraphExtractionProvider.configuration(for: "mlx-community/Some-Model")
        guard case .id(let bareID, let bareRevision) = bare.id else { return XCTFail("\(bare.id)") }
        XCTAssertEqual(bareID, "mlx-community/Some-Model")
        XCTAssertEqual(bareRevision, "main")
    }
}
#endif
