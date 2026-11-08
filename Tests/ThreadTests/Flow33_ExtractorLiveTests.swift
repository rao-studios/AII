//
//  Flow33_ExtractorLiveTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 11/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A real model through the gate: three source files read for code relations, six readings at once
//  (the GPU must hold one reading's state, not six), a paragraph extracted, the model released.
//  Opt-in: THREAD_EXTRACTOR_LIVE_MODEL names a Hub spec (org/repo@commit) or a model folder;
//  Scripts/test-extractor.sh builds, installs mlx.metallib beside the bundle and runs it.
//

import XCTest
import Logging
@testable import Thread
#if canImport(MLX)
import MLX
#endif

final class Flow33_ExtractorLiveTests: XCTestCase {
    private struct Sample {
        let type: String
        let kind: String
        let file: String
        let code: String
    }

    private let samples: [Sample] = [
        Sample(type: "SettingsStore", kind: "struct", file: "Sources/App/SettingsStore.swift", code: """
            import Foundation

            /// Keeps the person's choices between launches.
            struct SettingsStore {
                private let defaults: UserDefaults
                init(defaults: UserDefaults = .standard) { self.defaults = defaults }
                var theme: String {
                    get { defaults.string(forKey: "theme") ?? "system" }
                    nonmutating set { defaults.set(newValue, forKey: "theme") }
                }
                func reset() { defaults.removeObject(forKey: "theme") }
            }
            """),
        Sample(type: "RetryingClient", kind: "class", file: "Sources/App/RetryingClient.swift", code: """
            import Foundation

            final class RetryingClient {
                let session: URLSession
                let attempts: Int
                init(session: URLSession = .shared, attempts: Int = 3) { self.session = session; self.attempts = attempts }
                func data(from url: URL) async throws -> Data {
                    var delay: UInt64 = 200_000_000
                    for attempt in 1...attempts {
                        do { return try await session.data(from: url).0 }
                        catch where attempt < attempts { try await Task.sleep(nanoseconds: delay); delay *= 2 }
                    }
                    throw URLError(.cannotLoadFromNetwork)
                }
            }
            """),
        Sample(type: "ReplyView", kind: "struct", file: "Sources/App/ReplyView.swift", code: """
            import SwiftUI

            struct ReplyView: View {
                let tokens: AsyncStream<String>
                @State private var text = ""
                var body: some View {
                    ScrollView { Text(text).textSelection(.enabled) }
                        .task { for await token in tokens { text += token } }
                }
            }
            """),
    ]

    private func item(_ sample: Sample, index: Int) -> Database.BatchPutItem {
        let symbol = "sym:\(sample.type)"
        return Database.BatchPutItem(
            id: "craft/code/live.\(index)", data: [], texts: ["// \(sample.file)\n\(sample.code)"],
            graph: .init(entities: [.init(name: "project:live", kind: "project"), .init(name: "module:App", kind: "module"),
                                    .init(name: "file:\(sample.file)", kind: "file"), .init(name: symbol, kind: sample.kind)],
                         relationships: [.init(subject: "module:App", predicate: "declares", object: symbol)]),
            mediaType: .code)
    }

    func test_live_aModelReadsThroughTheGate_oneReadingsStateAtATime() async throws {
        guard let spec = ProcessInfo.processInfo.environment["THREAD_EXTRACTOR_LIVE_MODEL"], !spec.isEmpty else {
            throw XCTSkip("set THREAD_EXTRACTOR_LIVE_MODEL (org/repo@commit or a model folder); Scripts/test-extractor.sh runs it")
        }
        #if canImport(MLX)
        // In a test run the library sits in the test bundle (Scripts/test-extractor.sh), not beside the xctest runner.
        let bundled = Bundle(for: Self.self).bundleURL.appendingPathComponent("Contents/MacOS/mlx.metallib")
        guard FileManager.default.fileExists(atPath: bundled.path) || MLXRuntimeProbe.metalKernelLibraryAvailable() else {
            throw XCTSkip("no mlx.metallib beside the test bundle: run Scripts/test-extractor.sh")
        }
        let logger = Logger(label: "flow33")
        let model = MLXGraphExtractionProvider(modelId: spec, modelsHome: ThreadServer.modelsHome())
        let door = GraphExtractorGate(inner: model, backend: .mlx, model: spec, logger: logger, enabled: true,
                                      persist: false, idleRelease: 0, busyApps: { [] })
        let before = MLX.Memory.activeMemory

        var withGoals = 0
        for (index, sample) in samples.enumerated() {
            let start = Date()
            let reading = await CodeRelationEnrichment.relate(item(sample, index: index), extractor: door, existingGraph: nil, logger: logger)
            let goals = reading?.relationships.filter { $0.predicate == CodeRelationEnrichment.serves }.map(\.object) ?? []
            if !goals.isEmpty { withGoals += 1 }
            print("[live] \(sample.type): \(goals) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        }
        let loaded = MLX.Memory.activeMemory
        print("[live] weights resident: \((loaded - before) / 1_048_576) MB")

        MLX.Memory.peakMemory = 0
        let concurrentStart = Date()
        let atOnce = (0..<6).map { item(samples[$0 % samples.count], index: 10 + $0) }
        await withTaskGroup(of: Void.self) { group in
            for reading in atOnce {
                group.addTask { _ = await CodeRelationEnrichment.relate(reading, extractor: door, existingGraph: nil, logger: logger) }
            }
        }
        let peakOverWeights = MLX.Memory.peakMemory - loaded
        print("[live] six readings at once: \(String(format: "%.1f", Date().timeIntervalSince(concurrentStart))) s, peak over the weights \(peakOverWeights / 1_048_576) MB")

        let prose = """
            Ambient keeps a person's notes on their Mac and links each note to the people, places and projects it \
            mentions. Craft, a coding app, files every source file's declared types into the same index so a later \
            question can find the code that persists settings or retries a network request.
            """
        let raw = try await door.respond(instructions: ExtractionPolicyStore.current.effectiveSystemPrompt, input: prose,
                                         maxTokens: 800, logger: logger)
        print("[live] raw extraction answer: \(raw ?? "nil")")
        let payload = try await door.extract(from: ["""
            Ambient keeps a person's notes on their Mac and links each note to the people, places and projects it \
            mentions. Craft, a coding app, files every source file's declared types into the same index so a later \
            question can find the code that persists settings or retries a network request.
            """], logger: logger)
        print("[live] extracted \(payload.entities.count) entities, \(payload.relationships.count) relationships: \(payload.entities.prefix(6).map(\.name))")

        let released = await model.releaseModel(logger: logger)
        let after = MLX.Memory.activeMemory
        print("[live] released: \(released), MLX active \(after / 1_048_576) MB (was \(loaded / 1_048_576) MB)")

        XCTAssertGreaterThanOrEqual(withGoals, 2, "most files get a goal")
        XCTAssertFalse(payload.entities.isEmpty, "extraction parses")
        XCTAssertLessThan(peakOverWeights, 1_024 * 1_048_576, "one reading's state at a time, not six")
        XCTAssertTrue(released)
        XCTAssertLessThan(after, loaded, "the weights leave the GPU")
        #else
        throw XCTSkip("this build has no MLX")
        #endif
    }
}
