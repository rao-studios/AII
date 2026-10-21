//
//  ThreadEmbedderState.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The index's embedding model as Thread's /health says: downloading (how
//        far), loading, ready or failed — and whether the stored index was built
//        with it.
//  IN:   The /health body the supervisor already reads for its proof.
//  OUT:  AIIStatus.embedder, shown wherever an app shows the index.
//  PIN:  The one block every app used to parse for itself (Ambient's and Craft's
//        copies, united: Craft's carried the revision). A Thread from before the
//        block says nothing about embedding; that parses to nil, never a guess.
//        What to say about it is each app's: this type has no strings.
//

import Foundation

public struct ThreadEmbedderState: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case idle, downloading, loading, ready, failed
    }

    /// How the stored index relates to the model running now.
    public enum Index: String, Sendable {
        case matches, mismatch, unstamped
    }

    public var model: String?
    public var revision: String?
    /// e.g. `voyage-4@1024`.
    public var vectorSpace: String?
    public var phase: Phase
    /// 0…1 while downloading.
    public var progress: Double?
    public var error: String?
    public var index: Index?
    /// The space the index was built with, when it is not this one.
    public var indexedWith: String?

    public init(model: String? = nil, revision: String? = nil, vectorSpace: String? = nil, phase: Phase,
                progress: Double? = nil, error: String? = nil, index: Index? = nil, indexedWith: String? = nil) {
        self.model = model
        self.revision = revision
        self.vectorSpace = vectorSpace
        self.phase = phase
        self.progress = progress
        self.error = error
        self.index = index
        self.indexedWith = indexedWith
    }

    /// The `embedder` block of a /health body, or nil when there is none.
    public static func parse(healthBody: Data) -> ThreadEmbedderState? {
        guard let object = try? JSONSerialization.jsonObject(with: healthBody) as? [String: Any],
              let block = object["embedder"] as? [String: Any],
              let phase = (block["phase"] as? String).flatMap(Phase.init(rawValue:))
        else { return nil }
        return ThreadEmbedderState(
            model: block["model"] as? String,
            revision: block["revision"] as? String,
            vectorSpace: block["vectorSpace"] as? String,
            phase: phase,
            progress: (block["progress"] as? NSNumber)?.doubleValue,
            error: block["error"] as? String,
            index: (block["index"] as? String).flatMap(Index.init(rawValue:)),
            indexedWith: block["indexedWith"] as? String)
    }

    /// The index was built by another model, or before Thread recorded which: the
    /// node takes no filing and answers no search until it is cleared.
    public var needsRebuild: Bool { index == .mismatch || index == .unstamped }

    /// The model's repo without its org, for a label.
    public var modelName: String? {
        guard let model, !model.isEmpty else { return nil }
        return model.split(separator: "/").last.map(String.init) ?? model
    }
}
