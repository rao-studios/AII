//
//  GraphExtractorGate.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/07/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The one door every model reading in this node goes through, ingest extraction and code
//        relations alike: one at a time on the device, none while an app on the Mac is generating,
//        none while switched off, and the model let go when idle or switched off.
//  IN:   The backend makeGraphExtractor chose, the switch (ExtractorSwitchStore, in the data dir),
//        the apps generating now (AIIBusy marks under AII_HOME).
//  OUT:  GraphExtracting for every caller; `state` for /health and /v1/graph/extractor.
//  PIN:  ONE READING'S MEMORY. A chat session's cache is made outside the model's lock
//        (Frigate's ChatSession), so callers that run at once each hold a whole generation on the
//        GPU. On 2026-11-07 a session-open refile left about 150 Nemo readings in flight, 26 GB of
//        KV beside the weights, and Craft's 122B decoded at 0.26 tok/s. On the device the door
//        admits one reading; the rest wait in the order they came.
//  PIN:  AN APP'S TURN GOES FIRST. A reading that holds the door waits while any busy mark is
//        live, then reads; waiting readings keep their place. Hosted and keyword backends use no
//        GPU here, so they neither queue nor wait.
//  PIN:  OFF MEANS OFF. Switched off, extraction answers with keyword entities and readings with
//        nothing, the waiting readings are let go, and the model is released as soon as no
//        reading holds it. Switched on again, the next reading loads it.
//

import AII
import Foundation
import Logging

/// A backend that holds a model it can let go of (the on-device extractor).
protocol ReleasableExtractor: GraphExtracting {
    /// Drops the model and the GPU cache; false when nothing was loaded.
    func releaseModel(logger: Logger) async -> Bool
    var isModelLoaded: Bool { get async }
}

/// Whether the node reads with a model at all: the switch an app's settings turn (Craft's Relations).
struct ExtractorSwitch: Codable, Sendable, Equatable {
    var enabled: Bool
}

/// The switch, kept beside the index so a restart honours it.
enum ExtractorSwitchStore {
    static let key = "graph-extractor"

    static func load(logger: Logger) -> ExtractorSwitch {
        FilePersistence(key: key, kind: .basic, logger: logger).restore() ?? ExtractorSwitch(enabled: true)
    }

    static func save(_ value: ExtractorSwitch, logger: Logger) {
        FilePersistence(key: key, kind: .basic, logger: logger).save(state: value)
    }
}

actor GraphExtractorGate: GraphExtracting {
    enum Backend: String, Codable, Sendable { case mlx, mistral, keyword }

    /// What the door is doing, as /health and /v1/graph/extractor report it.
    struct State: Codable, Sendable, Equatable {
        let enabled: Bool
        let backend: Backend
        let model: String?
        let loaded: Bool
        /// A reading holds the door.
        let reading: Bool
        /// Readings waiting at the door.
        let waiting: Int
        /// The apps whose turn the reading at the door waits for.
        let yieldingTo: [String]
        /// Readings answered since this node started.
        let readings: Int
        let lastReadingSeconds: Double?
        let idleReleaseSeconds: Int
    }

    private let inner: any GraphExtracting
    private let releasable: (any ReleasableExtractor)?
    private let backend: Backend
    private let model: String?
    private let keywords = KeywordGraphExtractionProvider()
    private let busyApps: @Sendable () -> [String]
    private let persist: Bool
    private let logger: Logger
    private let idleRelease: TimeInterval
    private let pollNanoseconds: UInt64

    private var enabled: Bool
    private var holding = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var yieldingTo: [String] = []
    private var readings = 0
    private var lastReadingSeconds: Double?
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = 0

    /// `busyApps` is the apps generating now (AIIBusy in a server; a stub in tests); `persist` keeps the switch
    /// in the data dir (off in tests that build a gate without one).
    init(inner: any GraphExtracting, backend: Backend, model: String?, logger: Logger,
         enabled: Bool? = nil, persist: Bool = true,
         idleRelease: TimeInterval = GraphExtractorGate.defaultIdleRelease,
         pollInterval: TimeInterval = 1,
         busyApps: @escaping @Sendable () -> [String] = GraphExtractorGate.liveBusyApps) {
        self.inner = inner
        self.releasable = inner as? any ReleasableExtractor
        self.backend = backend
        self.model = model
        self.logger = logger
        self.persist = persist
        self.idleRelease = idleRelease
        self.pollNanoseconds = UInt64(max(0.01, pollInterval) * 1_000_000_000)
        self.busyApps = busyApps
        self.enabled = enabled ?? (persist ? ExtractorSwitchStore.load(logger: logger).enabled : true)
    }

    /// Five minutes without a reading lets the on-device model go (THREAD_EXTRACTOR_IDLE_SECONDS overrides).
    static var defaultIdleRelease: TimeInterval {
        ProcessInfo.processInfo.environment["THREAD_EXTRACTOR_IDLE_SECONDS"].flatMap(TimeInterval.init) ?? 300
    }

    /// The apps holding a live busy mark under this process's AII home.
    static let liveBusyApps: @Sendable () -> [String] = {
        #if os(macOS)
        AIIBusy(home: AIIHome.resolved(ProcessInfo.processInfo.environment)).apps().map(\.rawValue)
        #else
        []
        #endif
    }

    /// Whether this backend runs on this Mac's GPU, so readings queue, yield and release.
    private var onDevice: Bool { backend == .mlx }

    var isEnabled: Bool { enabled }

    var state: State {
        get async {
            State(enabled: enabled, backend: backend, model: model,
                  loaded: await releasable?.isModelLoaded ?? false,
                  reading: holding, waiting: waiters.count, yieldingTo: yieldingTo,
                  readings: readings, lastReadingSeconds: lastReadingSeconds,
                  idleReleaseSeconds: Int(idleRelease))
        }
    }

    // MARK: - GraphExtracting

    func extract(from texts: [String], logger: Logger) async throws -> Database.GraphPayload {
        guard await enter() else { return try await keywords.extract(from: texts, logger: logger) }
        defer { leave() }
        let start = Date()
        let payload = try await inner.extract(from: texts, logger: logger)
        noteReading(since: start)
        return payload
    }

    func respond(instructions: String, input: String, maxTokens: Int, logger: Logger) async throws -> String? {
        guard await enter() else { return nil }
        defer { leave() }
        let start = Date()
        let answer = try await inner.respond(instructions: instructions, input: input, maxTokens: maxTokens, logger: logger)
        noteReading(since: start)
        return answer
    }

    // MARK: - The switch

    /// Turns readings on or off. Off lets every waiting reading go and releases the model once no reading holds it.
    @discardableResult
    func setEnabled(_ value: Bool) async -> State {
        if value != enabled {
            enabled = value
            if persist { ExtractorSwitchStore.save(ExtractorSwitch(enabled: value), logger: logger) }
            logger.info("Graph extraction switched \(value ? "on" : "off")\(model.map { " (\($0))" } ?? "")")
        }
        if !value {
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting { waiter.resume(returning: false) }
            if !holding { await releaseModel(reason: "switched off") }
        }
        return await state
    }

    // MARK: - The door

    /// Takes the door: false when switched off (now, or while waiting). On the device, waits its turn,
    /// then waits while an app generates.
    private func enter() async -> Bool {
        guard enabled else { return false }
        guard onDevice else { return true }
        if holding {
            let admitted = await withCheckedContinuation { waiters.append($0) }
            guard admitted else { return false }
        } else {
            holding = true
        }
        idleTask?.cancel()
        while enabled {
            let apps = busyApps()
            guard !apps.isEmpty else { break }
            if apps != yieldingTo {
                logger.info("Graph extraction waits for \(apps.joined(separator: ", ")) to finish generating (\(waiters.count) waiting)")
                yieldingTo = apps
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        yieldingTo = []
        guard enabled else {
            leave()
            return false
        }
        return true
    }

    /// Hands the door to the next reading in line, or leaves it open and starts the idle clock.
    private func leave() {
        guard onDevice else { return }
        if !waiters.isEmpty, enabled {
            waiters.removeFirst().resume(returning: true)
            return
        }
        holding = false
        if enabled {
            scheduleIdleRelease()
        } else {
            Task { await self.releaseModel(reason: "switched off") }
        }
    }

    private func noteReading(since start: Date) {
        readings += 1
        lastReadingSeconds = Date().timeIntervalSince(start)
    }

    private func scheduleIdleRelease() {
        guard releasable != nil, idleRelease > 0 else { return }
        idleGeneration += 1
        let generation = idleGeneration
        let nanoseconds = UInt64(idleRelease * 1_000_000_000)
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.releaseIfIdle(generation)
        }
    }

    private func releaseIfIdle(_ generation: Int) async {
        guard generation == idleGeneration, !holding, waiters.isEmpty else { return }
        await releaseModel(reason: "idle \(Int(idleRelease)) s")
    }

    private func releaseModel(reason: String) async {
        guard !holding, let releasable else { return }
        if await releasable.releaseModel(logger: logger) {
            logger.info("Graph extraction released its model (\(reason))")
        }
    }
}
