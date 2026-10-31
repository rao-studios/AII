//
//  LLMProviderTests.swift
//  SewnTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The provider enum, its wire values, and the per-provider model tables.
//  These raw values are shared with Mary's LLMEngineChoice — a rename here
//  silently reroutes every one of her turns.
//

import XCTest
@testable import Sewn

final class LLMProviderTests: XCTestCase {

    func testRawValuesAreTheWireContractWithMary() {
        XCTAssertEqual(LLMProvider.allCases.map(\.rawValue), ["mistral", "tinker", "local"])
        XCTAssertEqual(LLMProvider(rawValue: "hosted"), nil)
    }

    func testOnlyLocalHasNoHostedTransport() {
        XCTAssertEqual(LLMProvider.mistral.hostedBase, .mistral)
        XCTAssertEqual(LLMProvider.tinker.hostedBase, .tinker)
        XCTAssertNil(LLMProvider.local.hostedBase)
        XCTAssertTrue(LLMProvider.local.isLocal)
    }

    func testAMissingKeyIsAnAnswerNotACrash() {
        // The whole point of apiKeyIfPresent: a client may select a provider
        // whose key was never configured, and the server must survive saying so.
        XCTAssertNoThrow(NetworkService.BaseEndpoint.tinker.apiKeyIfPresent)
        XCTAssertEqual(NetworkService.BaseEndpoint.tinker.apiKeyEnvVar, "TINKER_API_KEY")
        XCTAssertEqual(NetworkService.BaseEndpoint.mistral.apiKeyEnvVar, "MISTRAL_API_KEY")
    }
}

final class ModelConfigProviderTests: XCTestCase {

    override func tearDown() {
        ModelConfig.chooseLocalModel(nil)
        super.tearDown()
    }

    /// Settings › On-device in Ambient: the chosen model is every local job's model, so the
    /// harness never swaps between it and the default mid-turn.
    func testAChosenOnDeviceModelRunsEveryLocalJob() {
        let small = "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit"
        ModelConfig.chooseLocalModel(small)
        XCTAssertEqual(ModelConfig.chatModel(for: .local), small)
        XCTAssertEqual(ModelConfig.utilityModel(for: .local), small)
        XCTAssertEqual(ModelConfig.resolveChatModel(requested: nil, provider: .local), small)
        // Hosted lanes never see it.
        XCTAssertEqual(ModelConfig.resolveChatModel(requested: nil, provider: .mistral), ModelConfig.chatModel(for: .mistral))
        XCTAssertNotEqual(ModelConfig.utilityModel(for: .mistral), small)
    }

    func testAHostedNameIsNeverChosenAndNilClearsTheChoice() {
        ModelConfig.chooseLocalModel("mlx-community/Ministral-3-8B-Instruct-2512-4bit")
        ModelConfig.chooseLocalModel("mistral-medium-latest")
        XCTAssertEqual(ModelConfig.chatModel(for: .local), "mlx-community/Ministral-3-8B-Instruct-2512-4bit")
        ModelConfig.chooseLocalModel(nil)
        XCTAssertEqual(ModelConfig.chatModel(for: .local),
                       ProcessInfo.processInfo.environment["SEWN_LOCAL_MODEL"] ?? ModelConfig.defaultLocalModel)
    }

    func testOnlyAPlainHubIDReachesTheDisk() {
        XCTAssertNoThrow(try LocalModelStoreError.validated("mlx-community/Mistral-Nemo-Instruct-2407-4bit"))
        for bad in ["../etc", "mlx-community/../../x", "a/b/c", "/abs/path", "noslash", "org/", "org/.hidden"] {
            XCTAssertThrowsError(try LocalModelStoreError.validated(bad), bad)
        }
    }

    func testTheHostedDefaultIsMistralLargeFour() {
        // Public preview id from Mistral's changelog (2026-10-06); priced in Gita.ModelCatalog.
        XCTAssertEqual(ModelConfig.defaultMistralModel, "mistral-large-4")
        XCTAssertTrue(ModelConfig.isMistralModel(ModelConfig.defaultMistralModel))
    }

    func testEachMistralModelGetsTheLeastReasoningItTakes() {
        // Large 4 must reason: Mistral 400s "none" since 2026-10-29 ("supported values: high, low, medium").
        XCTAssertEqual(ModelConfig.mistralReasoning(for: ModelConfig.defaultMistralModel), .mandatory)
        XCTAssertEqual(ModelConfig.mistralReasoningEffort(for: ModelConfig.defaultMistralModel), "low")
        XCTAssertEqual(ModelConfig.mistralReasoningEffort(for: "mistral-large-4-0"), "low")
        // These reason only when asked and 400 "low": reasoning off.
        for model in ["mistral-medium-latest", "mistral-medium-3-5", "magistral-medium-latest", "mistral-small-latest"] {
            XCTAssertEqual(ModelConfig.mistralReasoning(for: model), .optional, model)
            XCTAssertEqual(ModelConfig.mistralReasoningEffort(for: model), "none", model)
        }
        // These answer 400 "reasoning_effort is not enabled for this model".
        for model in ["mistral-tiny", "codestral-latest", "mistral-large-latest"] {
            XCTAssertNil(ModelConfig.mistralReasoningEffort(for: model), model)
        }
    }

    func testLargeFoursBudgetIsFlooredForItsReasoning() {
        // "low" reasoning alone spent 299 of a 300-token budget (2026-10-30).
        XCTAssertTrue(ModelConfig.isThinkingModel("mistral-large-4"))
        XCTAssertEqual(ModelConfig.chatMaxTokens(requested: 80, model: "mistral-large-4"),
                       ModelConfig.thinkingTokenFloor)
        XCTAssertEqual(ModelConfig.chatMaxTokens(requested: 80, model: "mistral-large-latest"), 80)
        XCTAssertFalse(ModelConfig.isThinkingModel("mistral-tiny"))
    }

    func testAReasoningMessageKeepsOnlyItsAnswerText() throws {
        // Large 4's non-stream reply shape, 2026-10-30.
        let json = """
        {"role":"assistant","tool_calls":null,"content":[
          {"type":"thinking","thinking":[{"type":"text","text":"The user wants a greeting."}]},
          {"type":"text","text":"Hi there, "},{"type":"text","text":"lovely to see you."}]}
        """
        let message = try JSONDecoder().decode(Requests.Chat.Get.Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.content, "Hi there, lovely to see you.")

        let plain = try JSONDecoder().decode(
            Requests.Chat.Get.Message.self, from: Data(#"{"role":"assistant","content":"Hello."}"#.utf8))
        XCTAssertEqual(plain.content, "Hello.")
        let toolOnly = try JSONDecoder().decode(
            Requests.Chat.Get.Message.self, from: Data(#"{"role":"assistant","content":null}"#.utf8))
        XCTAssertEqual(toolOnly.content, "")
    }

    func testAThinkingOnlyStreamChunkCarriesNoText() throws {
        func text(_ content: String) throws -> String? {
            try JSONDecoder().decode(Requests.Chat.MistralContent.self, from: Data(content.utf8)).text
        }
        XCTAssertNil(try text(#"[{"type":"thinking","thinking":[{"type":"text","text":"Hmm"}],"closed":true}]"#))
        XCTAssertEqual(try text(#"[{"type":"text","text":"A warm cup"}]"#), "A warm cup")
        XCTAssertEqual(try text(#"" for me.""#), " for me.")
        XCTAssertNil(try text("null"))
    }

    func testThinkingIsKeptApartFromTheAnswer() throws {
        func content(_ json: String) throws -> Requests.Chat.MistralContent {
            try JSONDecoder().decode(Requests.Chat.MistralContent.self, from: Data(json.utf8))
        }
        let thought = try content(#"[{"type":"thinking","thinking":[{"type":"text","text":"The user "},{"type":"text","text":"is tired."}]}]"#)
        XCTAssertEqual(thought.thinking, "The user is tired.")
        XCTAssertNil(thought.text)
        let answer = try content(#"[{"type":"text","text":"Tea, then bed."}]"#)
        XCTAssertNil(answer.thinking)
        XCTAssertEqual(answer.text, "Tea, then bed.")
        XCTAssertNil(try content(#""plain""#).thinking)
    }

    func testTheWireCarriesReasoningOnlyWhenThereIsSome() throws {
        func json(_ delta: ChatCompletionDelta) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(delta)) as? [String: Any])
        }
        XCTAssertNil(try json(ChatCompletionDelta(role: nil, content: "Hi"))["reasoning"])
        let thinking = try json(ChatCompletionDelta(role: nil, content: nil, reasoning: "Hmm"))
        XCTAssertEqual(thinking["reasoning"] as? String, "Hmm")
        XCTAssertNil(thinking["content"])
    }

    func testOnlyAFailingHTTPStatusRejectsAStream() throws {
        let url = try XCTUnwrap(URL(string: "https://api.mistral.ai/v1/chat/completions"))
        func response(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        XCTAssertNil(HostedStreamRejected.failingStatus(response(200)))
        XCTAssertEqual(HostedStreamRejected.failingStatus(response(400)), 400)
        let rejected = HostedStreamRejected(status: 400, body: Data(#"{"message":"reasoning_effort none"}"#.utf8))
        XCTAssertEqual(rejected.description, #"Provider answered HTTP 400: {"message":"reasoning_effort none"}"#)
    }

    func testOnlyALargeFourRequestCarriesReasoningEffort() throws {
        func body(_ model: String) throws -> [String: Any] {
            let data = try JSONEncoder().encode(Requests.Chat.Get(model: model, messages: []))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try body("mistral-large-4")["reasoning_effort"] as? String, "low")
        XCTAssertNil(try body("mistral-tiny")["reasoning_effort"])
    }

    func testGreedySamplingSendsTopPOne() throws {
        // Mistral rejects temperature 0 with top_p ≠ 1 (400, invalid_request_greedy_sampling).
        let greedy = Requests.Chat.Get(model: "mistral-tiny", messages: [], temperature: 0)
        XCTAssertEqual(greedy.topP, 1)
        let sampled = Requests.Chat.Get(model: "mistral-tiny", messages: [], temperature: 0.4)
        XCTAssertEqual(try XCTUnwrap(sampled.topP), 0.9, accuracy: 1e-6)
    }

    func testEachProviderHasItsOwnChatModelFamily() {
        XCTAssertTrue(ModelConfig.isMistralModel(ModelConfig.chatModel(for: .mistral)))
        XCTAssertTrue(ModelConfig.chatModel(for: .local).contains("/"))
        XCTAssertFalse(ModelConfig.isMistralModel(ModelConfig.chatModel(for: .local)))
    }

    /// The bug this design exists to close: a `tinker://` id must never be
    /// posted to Mistral's host just because the client asked for it.
    func testARequestedModelIsRefusedWhenItBelongsToAnotherProvider() {
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "tinker://run/42", provider: .mistral),
            ModelConfig.chatModel(for: .mistral))
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "mistral-large-latest", provider: .tinker),
            ModelConfig.chatModel(for: .tinker))
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "tinker://run/42", provider: .tinker),
            "tinker://run/42")
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "mistral-large-latest", provider: .mistral),
            "mistral-large-latest")
    }

    func testAnEmptyRequestFallsBackToTheProvidersOwnModel() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(
                ModelConfig.resolveChatModel(requested: nil, provider: provider),
                ModelConfig.chatModel(for: provider))
            XCTAssertEqual(
                ModelConfig.resolveChatModel(requested: "", provider: provider),
                ModelConfig.chatModel(for: provider))
        }
    }

    /// Inkling deliberates for 30–90s; it must never serve an extraction job.
    func testTinkerBorrowsMistralsUtilityModelAndLocalUsesItsOwn() {
        XCTAssertEqual(ModelConfig.utilityModel(for: .tinker), ModelConfig.defaultUtilityModel)
        XCTAssertEqual(ModelConfig.utilityModel(for: .mistral), ModelConfig.defaultUtilityModel)
        XCTAssertEqual(ModelConfig.utilityModel(for: .local), ModelConfig.chatModel(for: .local))
    }

    func testCodingPinsCodestralForMistralAndStaysOnDeviceForLocal() {
        XCTAssertEqual(ModelConfig.codingModel(for: .mistral), ModelConfig.defaultCodingModel)
        XCTAssertTrue(ModelConfig.isMistralModel(ModelConfig.codingModel(for: .mistral)))
        XCTAssertEqual(ModelConfig.codingModel(for: .local), ModelConfig.chatModel(for: .local))
    }
}
