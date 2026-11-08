//
//  Extractor.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: `GET /v1/graph/extractor` — whether this node reads with a model, which one, whether it is
//        loaded, what waits and what the node's GPU holds — and `PUT /v1/graph/extractor
//        {"enabled": …}`, the switch an app's settings turn (Craft's Settings › Knowledge › Relations).
//  IN:   The extractor gate, the code-relations line.
//  OUT:  ExtractorStatus; switching off also lets the waiting code relations go.
//  PIN:  ANY APP MAY TURN IT. Unlike the extraction policy (which decides what the graph says, so
//        only the stack identity sets it), the switch decides only whether this Mac's GPU is spent
//        on readings: an app that runs a large model of its own may turn them off. Off, ingest still
//        files every document with keyword entities.
//

import AII
import Foundation
import Hummingbird
#if canImport(MLX)
import MLX
#endif

/// What MLX holds in this process: the extractor's and the embedder's weights, a reading's state, the allocator's cache.
struct NodeGPU: Codable, Sendable, Equatable {
    let activeBytes: Int
    let cacheBytes: Int
    let peakBytes: Int

    static func now() -> NodeGPU? {
        #if canImport(MLX)
        guard MLXRuntimeProbe.metalKernelLibraryAvailable() else { return nil }
        return NodeGPU(activeBytes: MLX.Memory.activeMemory, cacheBytes: MLX.Memory.cacheMemory,
                       peakBytes: MLX.Memory.peakMemory)
        #else
        return nil
        #endif
    }
}

struct ExtractorStatus: ResponseCodable, Codable, Sendable, Equatable {
    let enabled: Bool
    let backend: String
    let model: String?
    let loaded: Bool
    let reading: Bool
    let waiting: Int
    let yieldingTo: [String]
    let readings: Int
    let lastReadingSeconds: Double?
    let idleReleaseSeconds: Int
    /// Code relations waiting in the node's one line, read since start, dropped past its capacity.
    let relationsPending: Int
    let relationsRead: Int
    let relationsDropped: Int
    let gpu: NodeGPU?

    static func current(gate: GraphExtractorGate, relations: CodeRelationQueue?) async -> ExtractorStatus {
        let state = await gate.state
        return ExtractorStatus(
            enabled: state.enabled, backend: state.backend.rawValue, model: state.model, loaded: state.loaded,
            reading: state.reading, waiting: state.waiting, yieldingTo: state.yieldingTo, readings: state.readings,
            lastReadingSeconds: state.lastReadingSeconds, idleReleaseSeconds: state.idleReleaseSeconds,
            relationsPending: await relations?.pending ?? 0, relationsRead: await relations?.read ?? 0,
            relationsDropped: await relations?.dropped ?? 0, gpu: NodeGPU.now())
    }
}

func registerExtractorRoutes(
    _ app: some RouterMethods<ThreadRequestContext>,
    gate: GraphExtractorGate,
    relations: CodeRelationQueue?
) {
    app.get("/v1/graph/extractor") { _, _ async throws -> ExtractorStatus in
        await ExtractorStatus.current(gate: gate, relations: relations)
    }

    app.put("/v1/graph/extractor") { request, context async throws -> ExtractorStatus in
        let body = try await request.decode(as: ExtractorSwitch.self, context: context)
        await gate.setEnabled(body.enabled)
        if !body.enabled, let dropped = await relations?.clear(), dropped > 0 {
            context.logger.info("Graph extraction off: \(dropped) waiting code relation(s) let go")
        }
        return await ExtractorStatus.current(gate: gate, relations: relations)
    }
}
