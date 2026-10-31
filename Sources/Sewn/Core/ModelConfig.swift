//
//  ModelConfig.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Runtime-mutable model selection, keyed by LLMProvider. Every route asks
//  for the model of a (provider, job) pair; nothing infers a provider from a
//  model name any more.
//

import AII
import Foundation

/// Which model serves each job for each provider. Seeded from the environment
//  at boot, mutable at runtime via `PUT /v1/admin/model` so a freshly trained
//  `tinker://…` checkpoint can be deployed without a server restart.
enum ModelConfig {
    /// On-device default: the AII master list's standard general model, the one
    /// Thread extracts with too, so a machine that has it pays nothing to switch.
    static let defaultLocalModel = AIIModels.generalStandard.id
    static let defaultTinkerModel = "thinkingmachines/Inkling-Small"
    /// Large 4 always reasons now (`mistralReasoningEffort`): it streams that reasoning and
    /// the answer as typed content arrays (`Requests.Chat.MistralContent` keeps the text),
    /// and its token budget is floored like any thinking model's (`isThinkingModel`).
    static let defaultMistralModel = "mistral-large-4"

    /// Internal one-shot generations (compact, Sinatra sentiment, auto-memory,
    /// summarize) run on a fast, non-thinking model. Inkling must never double
    /// as the utility model: it deliberates for 30–90s per call, which stacked
    /// into minutes of chat latency — so Tinker borrows Mistral's here.
    static let defaultUtilityModel = "mistral-tiny"

    /// True when the model name belongs to the Mistral API family. Still the
    /// family check `resolveChatModel` uses to police a client's request; it
    /// is no longer how a provider is chosen.
    static func isMistralModel(_ model: String) -> Bool {
        let lowered = model.lowercased()
        return lowered.hasPrefix("mistral") || lowered.hasPrefix("open-mi")
            || lowered.hasPrefix("ministral") || lowered.hasPrefix("codestral")
    }

    /// How a Mistral model reasons, live-verified 2026-10-30.
    enum MistralReasoning: Equatable {
        /// Always reasons: Large 4 takes only "low" | "medium" | "high" (Mistral dropped
        /// "none" between 2026-10-28 and 10-29, and every hosted turn came back empty).
        case mandatory
        /// Reasons only when asked: Medium, Magistral and Small take "none" | "high"
        /// ("low" is a 400).
        case optional
        /// No `reasoning_effort` at all: mistral-tiny, codestral and mistral-large-latest
        /// answer 400 "reasoning_effort is not enabled for this model".
        case unsupported
    }

    static func mistralReasoning(for model: String) -> MistralReasoning {
        let lowered = model.lowercased()
        if lowered.hasPrefix("mistral-large-4") { return .mandatory }
        if lowered.hasPrefix("mistral-medium") || lowered.hasPrefix("magistral")
            || lowered == "mistral-small-latest" || lowered == "mistral-small-2603" {
            return .optional
        }
        return .unsupported
    }

    /// `reasoning_effort` for a Mistral chat request: the least each model takes. A
    /// mandatory reasoner gets "low" (~80–120 reasoning tokens, ~1 s before the first answer
    /// token, 2026-10-30) and streams its thinking apart from the answer
    /// (`Requests.Chat.MistralContent`); an optional one gets "none", so it answers at once.
    static func mistralReasoningEffort(for model: String) -> String? {
        switch mistralReasoning(for: model) {
        case .mandatory: return "low"
        case .optional: return "none"
        case .unsupported: return nil
        }
    }

    private static func environment(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty
        else { return nil }
        return value
    }

    /// Runtime overrides from `PUT /v1/admin/model`. Empty = follow the env.
    private static let overrides = LockedValue<(chat: String, utility: String)>(("", ""))

    /// The on-device model a client chose (Ambient's Settings › On-device): set by a warm or
    /// an on-device request that names one. One Sewn serves the Mac, so the last choice
    /// wins. Empty = `SEWN_LOCAL_MODEL`, else the default.
    private static let localChoice = LockedValue<String>("")

    /// Make `model` the on-device model every local job runs — replies, `/v1/complete`,
    /// compaction, recap and auto-memory alike — so a client's choice never has the
    /// harness swapping between it and the default. Nil or empty clears the choice; an id
    /// that is not an on-device model is ignored.
    static func chooseLocalModel(_ model: String?) {
        let model = model ?? ""
        guard model.isEmpty || accepts(model, provider: .local) else { return }
        localChoice.withLock { $0 = model }
    }

    /// The chat model for one provider.
    static func chatModel(for provider: LLMProvider) -> String {
        let override = overrides.withLock { $0.chat }
        if !override.isEmpty, accepts(override, provider: provider) { return override }
        switch provider {
        case .mistral:
            return environment("SEWN_CHAT_MODEL").flatMap {
                isMistralModel($0) ? $0 : nil
            } ?? defaultMistralModel
        case .tinker:
            return environment("TINKER_MODEL") ?? defaultTinkerModel
        case .local:
            let chosen = localChoice.withLock { $0 }
            if !chosen.isEmpty { return chosen }
            return environment("SEWN_LOCAL_MODEL") ?? defaultLocalModel
        }
    }

    /// The utility model for one provider. Hosted providers share Mistral's
    /// fast one; local has only its own.
    static func utilityModel(for provider: LLMProvider) -> String {
        let override = overrides.withLock { $0.utility }
        if !override.isEmpty { return override }
        switch provider {
        case .mistral, .tinker:
            return environment("UTILITY_MODEL") ?? defaultUtilityModel
        case .local:
            return chatModel(for: .local)
        }
    }

    /// Pair-coding synthesis for `/v1/code/complete`. Mary does not send a
    /// model id; this is Sewn's pin.
    static func codingModel(for provider: LLMProvider) -> String {
        switch provider {
        case .mistral:
            return environment("SEWN_CODING_MODEL") ?? defaultCodingModel
        case .tinker:
            return chatModel(for: .tinker)
        case .local:
            return environment("SEWN_LOCAL_CODING_MODEL") ?? chatModel(for: .local)
        }
    }

    /// The provider that could serve this model id, by family. A request may
    /// name a model, but only one belonging to the provider it selected —
    /// otherwise a `tinker://` id would be posted to Mistral's API.
    static func accepts(_ model: String, provider: LLMProvider) -> Bool {
        switch provider {
        case .mistral:
            return isMistralModel(model)
        case .tinker:
            return model.hasPrefix("tinker://") || model.contains("/")
        case .local:
            return model.contains("/") && !model.hasPrefix("tinker://")
        }
    }

    static func update(chatModel: String? = nil, utilityModel: String? = nil) {
        overrides.withLock {
            if let chatModel { $0.chat = chatModel }
            if let utilityModel { $0.utility = utilityModel }
        }
    }

    /// What `GET /v1/admin/model` reports: the server-default provider's pair.
    static var chatModel: String { chatModel(for: .serverDefault) }
    static var utilityModel: String { utilityModel(for: .serverDefault) }

    /// A client-supplied `model` is honored only when it belongs to the
    /// provider serving the request; anything else falls back to that
    /// provider's configured chat model.
    static func resolveChatModel(requested: String?, provider: LLMProvider) -> String {
        guard let requested, !requested.isEmpty else { return chatModel(for: provider) }
        return accepts(requested, provider: provider) ? requested : chatModel(for: provider)
    }

    /// The vision model serving `/v1/vision/look`; override with
    /// `VISION_MODEL` in `.env`. The Pixtral ids are RETIRED (the API answers
    /// `invalid_model`, live-verified 2026-08-11) — vision now rides the
    /// multimodal mainline; medium is the same family the chat lane uses.
    static var visionModel: String {
        ProcessInfo.processInfo.environment["VISION_MODEL"] ?? "mistral-medium-latest"
    }

    // MARK: - On-device vision

    /// Rao's MLX conversion of Ministral 3 8B Instruct (Veil's scripts/vision), the vision
    /// model every Rao app reads pictures with on this Mac, through `LocalVision`. Pinned on
    /// the AII master list (`AIIModels.vision`); bumping the revision there is how a new
    /// conversion ships.
    static let defaultLocalVisionModel = AIIModels.vision.id
    static let defaultLocalVisionRevision = AIIModels.vision.revision ?? ""

    /// The on-device vision model a request gets when it names none: `SEWN_LOCAL_VISION_MODEL`
    /// (`org/repo[@revision]`, or an absolute snapshot directory), else the pinned conversion.
    static var localVisionModel: String {
        environment("SEWN_LOCAL_VISION_MODEL") ?? AIIModels.vision.pinnedSpec
    }

    /// Seconds with no picture before the vision model is let go (`SEWN_LOCAL_VISION_IDLE_SECONDS`,
    /// at least 10). It is about ten gigabytes beside the chat model.
    static var localVisionIdleSeconds: TimeInterval {
        environment("SEWN_LOCAL_VISION_IDLE_SECONDS").flatMap(TimeInterval.init).map { max(10, $0) } ?? 300
    }

    // MARK: - Realtime opening pass

    /// Model that speaks the realtime route's instant opening while retrieval
    /// and the grounded pass run. Must be fast and non-thinking — the opening
    /// exists to cover the primary model's deliberation, so routing it through
    /// a thinking model would defeat the point. `mistral-small-latest` over
    /// `utilityModel` (mistral-tiny): the opening is user-visible prose, not an
    /// extraction job.
    static var openingModel: String {
        ProcessInfo.processInfo.environment["SEWN_REALTIME_OPENING_MODEL"]
            ?? "mistral-small-latest"
    }

    static let defaultCodingModel = "codestral-latest"

    /// The opening is one-to-two sentences; a tight budget keeps a rambling
    /// generation from delaying the grounded continuation.
    static let openingMaxTokens = 80

    /// Reasoning models spend a large share of their token budget thinking
    /// before the answer. Worse, when Tinker truncates one at `max_tokens`
    /// mid-reasoning it returns the partial deliberation as a `text` block
    /// (non-stream) or streams nothing at all — which would leak straight to
    /// the user or produce an empty reply. Floor the budget high enough that
    /// the model reaches its actual answer; Inkling has been observed to
    /// deliberate past 2k tokens on instruction-heavy chat prompts.
    static let thinkingTokenFloor = 4_096

    /// True for models that emit thinking before their response (Inkling, any
    /// tinker:// checkpoint, Qwen3 hybrids without the `/no_think` switch, and Mistral
    /// Large 4, whose "low" reasoning alone spent 299 of a 300-token budget, 2026-10-30).
    static func isThinkingModel(_ model: String) -> Bool {
        model.localizedCaseInsensitiveContains("inkling")
            || model.hasPrefix("tinker://")
            || supportsNoThinkSwitch(model)
            || mistralReasoning(for: model) == .mandatory
    }

    /// Qwen3 hybrid models honor a `/no_think` soft switch in the prompt that
    /// suppresses deliberation entirely (the 2507 instruct variants dropped it).
    static func supportsNoThinkSwitch(_ model: String) -> Bool {
        model.localizedCaseInsensitiveContains("qwen3")
            && !model.contains("2507")
    }

    /// The effective max-token budget for a chat generation: the requested
    /// value, floored for thinking models.
    static func chatMaxTokens(requested: Int?, model: String) -> Int {
        let requested = requested ?? GenerationDefaults.maxTokens
        guard isThinkingModel(model) else { return requested }
        return max(requested, thinkingTokenFloor)
    }
}
