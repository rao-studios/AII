//
//  AIIAnswer.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: One question to Sewn, grounded in the app's lane, streamed back: what it may
//        cite, the tokens, who contributed, and whether Sewn remembered the conversation.
//  IN:   AIIInstance.ask, with the app's secret and its owner (the lane's, or the one the
//        instance was made with); `Options.provider` to choose the backend.
//  OUT:  `Event`s: `.references`, `.token`, `.contribution`, `.finished(autoMemory:)`.
//  PIN:  No account. With no provider named, Sewn decides (LocalOnlyGrant): on device when
//        the stack holds no key, else through the provider whose key it holds
//        (~/.rao/keys/providers.json). `.local` pins this Mac: nothing leaves it. Scope
//        `personal` over everything the owner holds, so the turn retrieves the app's own
//        records and its memory. Loopback only, no proxy, no cache, no cookies. An error
//        after the stream opened arrives as `data: {"error":…}` and is thrown as `Failure`.
//

#if os(macOS)
import Foundation

public enum AIIAnswer {

    public struct Message: Codable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable { case user, assistant, system }
        public var role: Role
        public var content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// A voice and a name for the answer.
    public struct Persona: Codable, Sendable, Equatable {
        public var name: String?
        public var voice: String?
        public var userName: String?

        public init(name: String? = nil, voice: String? = nil, userName: String? = nil) {
            self.name = name
            self.voice = voice
            self.userName = userName
        }

        enum CodingKeys: String, CodingKey {
            case name, voice
            case userName = "user_name"
        }
    }

    /// Which backend answers. The raw values are Sewn's wire.
    public enum Provider: String, Codable, Sendable {
        /// This Mac: nothing leaves it.
        case local
        /// Mistral's hosted API, with the key the stack holds.
        case mistral
        /// Thinking Machines' Tinker, with the key the stack holds.
        case tinker
    }

    public struct Options: Sendable, Equatable {
        /// The turns before this one, oldest first.
        public var history: [Message]
        public var maxTokens: Int
        public var temperature: Double?
        public var instructions: String?
        public var persona: Persona?
        /// An on-device model, `org/repo[@rev]`; nil for this Mac's chosen one.
        public var model: String?
        /// Nil: Sewn decides — on device when the stack holds no key, else the provider whose
        /// key it holds. `.local` pins this Mac.
        public var provider: Provider?

        public init(history: [Message] = [], maxTokens: Int = 512, temperature: Double? = nil,
                    instructions: String? = nil, persona: Persona? = nil, model: String? = nil,
                    provider: Provider? = nil) {
            self.history = history
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.instructions = instructions
            self.persona = persona
            self.model = model
            self.provider = provider
        }
    }

    /// A document the answer may cite.
    public struct Reference: Codable, Sendable, Equatable {
        /// `<app>/<kind>/<id>` for an app's record.
        public var id: String
        public var partitionID: String?
        public var ownerID: String?

        enum CodingKeys: String, CodingKey {
            case id
            case partitionID = "partition_id"
            case ownerID = "owner_id"
        }
    }

    public enum Event: Sendable, Equatable {
        /// First: what the answer may cite.
        case references([Reference])
        case token(String)
        /// Who the answer drew on, as Sewn attributes it (Gita).
        case contribution(AIIJSONValue)
        /// Last. `autoMemory`: Sewn kept this conversation in the app's memory, so the
        /// app may drop its history.
        case finished(autoMemory: Bool)
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let status: Int?
        public let message: String
        public var description: String { status.map { "Sewn answered \($0): \(message)" } ?? message }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 300
        return URLSession(configuration: configuration)
    }

    static func request(question: String, options: Options, app: AIIApp, owner: String, home: AIIHome) throws -> URLRequest {
        let port = AIIConfig.load(home: home).sewnPorts.http
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let secret = try home.readSecret(for: app) {
            request.setValue(secret, forHTTPHeaderField: StackSecret.headerName)
        }
        struct Retrieval: Encodable {
            let owner_id: String
            let scope = "personal"
            let aggregate = true
        }
        struct Body: Encodable {
            let messages: [Message]
            /// Absent when nil: Sewn decides from the keys the stack holds.
            let provider: String?
            let stream = true
            let max_tokens: Int
            let temperature: Double?
            let instructions: String?
            let persona: Persona?
            let model: String?
            let sewn: Retrieval
        }
        let body = Body(messages: options.history + [Message(role: .user, content: question)],
                        provider: options.provider?.rawValue,
                        max_tokens: options.maxTokens, temperature: options.temperature,
                        instructions: options.instructions, persona: options.persona, model: options.model,
                        sewn: Retrieval(owner_id: owner))
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func stream(question: String, options: Options, app: AIIApp, owner: String, home: AIIHome,
                       session: URLSession) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try request(question: question, options: options, app: app, owner: owner, home: home)
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var text = ""
                        for try await line in bytes.lines where text.count < 300 { text += line }
                        throw Failure(status: status, message: text)
                    }
                    var autoMemory = false
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
                        if let failure = chunk.error { throw Failure(status: nil, message: failure.message) }
                        if let references = chunk.references, !references.isEmpty { continuation.yield(.references(references)) }
                        for choice in chunk.choices ?? [] {
                            if let content = choice.delta?.content, !content.isEmpty { continuation.yield(.token(content)) }
                        }
                        if let contribution = chunk.contribution, contribution != .null { continuation.yield(.contribution(contribution)) }
                        if chunk.autoMemory == true { autoMemory = true }
                    }
                    continuation.yield(.finished(autoMemory: autoMemory))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta?
        }
        struct ErrorBody: Decodable { var message: String }
        var choices: [Choice]?
        var references: [Reference]?
        var contribution: AIIJSONValue?
        var autoMemory: Bool?
        var error: ErrorBody?

        enum CodingKeys: String, CodingKey {
            case choices, references, contribution, error
            case autoMemory = "auto_memory"
        }
    }
}
#endif
