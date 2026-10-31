//
//  ChatRequests.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/28/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

extension Requests {
    struct Chat {}
}

extension Requests.Chat {
    struct Get: NetworkRequest {
        typealias Response = Result

        var path: String { "v1/chat/completions" }
        var method: RequestMethod { .post }

        let model: String
        let messages: [Message]
        let maxTokens: Int?
        let temperature: Double?
        let topP: Double?
        let stream: Bool?
        let stop: [String]?
        let tools: [Tool]?
        let reasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case maxTokens = "max_tokens"
            case temperature
            case topP = "top_p"
            case stream
            case stop
            case tools
            case reasoningEffort = "reasoning_effort"
        }

        init(
            model: String,
            messages: [Message],
            maxTokens: Int? = nil,
            temperature: Float = 0.4,
            topP: Float = 0.9,
            stream: Bool = false,
            stop: [String]? = nil,
            tools: [Tool]? = nil
        ) {
            self.model = model
            self.messages = messages
            self.maxTokens = maxTokens
            self.temperature = Double(temperature)
            // Mistral answers 400 "top_p must be 1 when using greedy sampling" to
            // temperature 0 with any other top_p (every structured sentiment call failed
            // this way, 2026-10-17); greedy decoding ignores top_p anyway.
            self.topP = temperature == 0 ? 1 : Double(topP)
            self.stream = stream
            self.stop = stop
            self.tools = tools
            self.reasoningEffort = ModelConfig.mistralReasoningEffort(for: model)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(topP, forKey: .topP)
            try container.encodeIfPresent(stream, forKey: .stream)
            try container.encodeIfPresent(stop, forKey: .stop)
            try container.encodeIfPresent(tools, forKey: .tools)
            try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            model = try values.decode(String.self, forKey: .model)
            messages = try values.decode([Message].self, forKey: .messages)
            maxTokens = try values.decodeIfPresent(Int.self, forKey: .maxTokens)
            temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
            topP = try values.decodeIfPresent(Double.self, forKey: .topP)
            stream = try values.decodeIfPresent(Bool.self, forKey: .stream)
            stop = try values.decodeIfPresent([String].self, forKey: .stop)
            tools = try values.decodeIfPresent([Tool].self, forKey: .tools)
            reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        }

        /// OpenAI/Mistral function-calling tool declaration.
        struct Tool: Codable {
            let type: String
            let function: Function

            struct Function: Codable {
                let name: String
                let description: String?
                let parameters: JSONValue?
            }
        }

        struct ToolCall: Codable {
            let id: String?
            let type: String?
            let function: Function?

            struct Function: Codable {
                let name: String
                let arguments: String

                enum CodingKeys: String, CodingKey {
                    case name, arguments
                }

                init(name: String, arguments: String) {
                    self.name = name
                    self.arguments = arguments
                }

                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    name = try values.decode(String.self, forKey: .name)
                    if let text = try? values.decode(String.self, forKey: .arguments) {
                        arguments = text
                    } else if let object = try? values.decode(JSONValue.self, forKey: .arguments) {
                        arguments = object.jsonString()
                    } else {
                        arguments = "{}"
                    }
                }
            }
        }

        // MARK: Response Model (Mistral-compatible)
        struct Result: Codable {
            let id: String
            let object: String
            let created: Int
            let model: String
            let choices: [Choice]
            let usage: Usage

            enum CodingKeys: String, CodingKey {
                case id
                case object
                case created
                case model
                case choices
                case usage
            }
        }

        struct Usage: Codable {
            let promptTokens: Int
            let completionTokens: Int
            let totalTokens: Int

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
            
            var description: String {
                """
                Prompt Tokens: \(promptTokens)
                Completion Tokens: \(completionTokens)
                Total Tokens: \(totalTokens)
                """
            }
        }

        struct Choice: Codable {
            let index: Int
            let message: Message
            let finishReason: String

            enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
            }
        }

        struct Message: Codable {
            let role: String
            let toolCalls: [ToolCall]?
            let content: String

            enum CodingKeys: String, CodingKey {
                case role
                case toolCalls = "tool_calls"
                case content
            }

            init(role: String,
                 toolCalls: [ToolCall]?,
                 content: String) {
                self.role = role
                self.toolCalls = toolCalls
                self.content = content
            }

            init(role: String,
                 content: String) {
                self.role = role
                self.toolCalls = nil
                self.content = content
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                role = try values.decode(String.self, forKey: .role)
                toolCalls = try values.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
                content = try values.decodeIfPresent(MistralContent.self, forKey: .content)?.text ?? ""
            }
        }
    }

    /// A Mistral message's (or stream delta's) `content`: a plain string, or, from a
    /// reasoning model (Large 4), an array of typed parts — `{"type":"thinking","thinking":
    /// [{"type":"text","text":…}]}` then `{"type":"text","text":…}`. The text parts are the
    /// answer; the thinking is kept apart so it never reaches the reply (or the voice).
    /// Each is nil when the content has no part of that kind.
    struct MistralContent: Decodable {
        let text: String?
        let thinking: String?

        private struct Part: Decodable {
            struct Inner: Decodable {
                let text: String?
            }
            let type: String
            let text: String?
            let thinking: [Inner]?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                text = nil
                thinking = nil
            } else if let string = try? container.decode(String.self) {
                text = string
                thinking = nil
            } else {
                let parts = try container.decode([Part].self)
                let answer = parts.filter { $0.type == "text" }
                let thought = parts.filter { $0.type == "thinking" }
                text = answer.isEmpty ? nil : answer.compactMap(\.text).joined()
                thinking = thought.isEmpty
                    ? nil : thought.flatMap { $0.thinking ?? [] }.compactMap(\.text).joined()
            }
        }
    }
}
