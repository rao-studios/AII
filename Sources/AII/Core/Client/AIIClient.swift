//
//  AIIClient.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The one client an app reads the Ambient Intelligence Index through over
//        HTTP: both servers' health, this lane's stats, the base models and whether
//        each is on this Mac, the Thread nodes Sewn knows.
//  IN:   Each app's status view and model settings; the aii command, as the stack.
//  OUT:  Sendable values. No gRPC: depositing and searching is AIIInstance's, over Seam.
//  PIN:  Loopback only, no proxy, no cache, no cookies — a request that isn't to
//        127.0.0.1 is refused before it is made. The secret is attached by a
//        `sign` hook the app provides (Ambient's LocalStackCredential refuses to
//        sign for a port it hasn't verified); the default reads the identity's secret
//        from ~/.rao. A 401 is reported as such, never as "nothing there".
//

import Foundation

public enum AIIClientError: Error, Equatable, CustomStringConvertible {
    case notLoopback(String)
    case unauthorized
    case http(Int, String?)
    case transport(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .notLoopback(let host): return "\(host) is not this machine; the stack is only ever asked on loopback"
        case .unauthorized: return "the stack refused the secret presented (401)"
        case .http(let status, let body): return "the stack answered \(status)\(body.map { ": \($0)" } ?? "")"
        case .transport(let reason): return reason
        case .decoding(let reason): return "unexpected answer from the stack: \(reason)"
        }
    }
}

public struct AIIClient: Sendable {
    public typealias Signer = @Sendable (inout URLRequest) -> Void

    /// Who the client speaks as: an app, or the stack (the aii command).
    public let identity: StackIdentity
    public let home: AIIHome
    public let sewnBaseURL: URL
    public let threadBaseURL: URL
    private let sign: Signer
    private let secretForChallenge: @Sendable () -> String?

    /// - Parameters:
    ///   - sign: Attaches the secret to a request. Default: `X-Ambient-Secret` from
    ///     `home.readSecret(for: identity)`.
    public init(identity: StackIdentity, home: AIIHome = .resolved(), config: AIIConfig? = nil, sign: Signer? = nil) {
        let config = config ?? AIIConfig.load(home: home)
        self.identity = identity
        self.home = home
        self.sewnBaseURL = URL(string: "http://127.0.0.1:\(config.sewnPorts.http)")!
        self.threadBaseURL = URL(string: "http://127.0.0.1:\(config.threadPorts.http)")!
        let secret: @Sendable () -> String? = { try? home.readSecret(for: identity) }
        self.secretForChallenge = secret
        self.sign = sign ?? { request in
            if let value = secret() { request.setValue(value, forHTTPHeaderField: StackSecret.headerName) }
        }
    }

    /// The client of an app.
    public init(app: AIIApp, home: AIIHome = .resolved(), config: AIIConfig? = nil, sign: Signer? = nil) {
        self.init(identity: .app(app), home: home, config: config, sign: sign)
    }

    /// The app it speaks as; nil for the stack.
    public var app: AIIApp? { identity.app }

    // MARK: - Health

    /// Both servers challenged as this identity: no secret leaves the process.
    public func health(timeout: TimeInterval = 2) async -> (sewn: StackVerdict, thread: StackVerdict) {
        guard let secret = secretForChallenge() else { return (.down, .down) }
        let sewn = await StackProbe.challengeWithBody(url: sewnBaseURL.appendingPathComponent("health"), secret: secret,
                                                      identity: identity, timeout: timeout).verdict
        let thread = await StackProbe.challengeWithBody(url: threadBaseURL.appendingPathComponent("health"), secret: secret,
                                                        identity: identity, timeout: timeout).verdict
        return (sewn, thread)
    }

    /// Thread's /health, with its embedder block.
    public func threadHealth(timeout: TimeInterval = 2) async -> (verdict: StackVerdict, embedder: ThreadEmbedderState?) {
        guard let secret = secretForChallenge() else { return (.down, nil) }
        let (verdict, body) = await StackProbe.challengeWithBody(url: threadBaseURL.appendingPathComponent("health"), secret: secret,
                                                                 identity: identity, timeout: timeout)
        return (verdict, body.flatMap(ThreadEmbedderState.parse(healthBody:)))
    }

    // MARK: - The index

    /// This lane's counts and top entities (Thread `GET /v1/stats`); every lane's, for the stack.
    public func stats() async throws -> AIIStats {
        try await get(threadBaseURL.appendingPathComponent("v1/stats"), as: AIIStats.self)
    }

    /// The Thread nodes Sewn knows (`GET /v1/threads`).
    public func threads() async throws -> [AIIThreadNode] {
        struct Response: Decodable { var nodes: [AIIThreadNode] }
        return try await get(sewnBaseURL.appendingPathComponent("v1/threads"), as: Response.self).nodes
    }

    // MARK: - Models

    /// Every base model on the master list, with whether it is on this Mac
    /// (Sewn `GET /v1/providers/local/models`).
    public func models(_ entries: [AIIModels.Entry] = AIIModels.all) async throws -> [AIIModelState] {
        struct Info: Decodable { var id: String; var state: String; var progress: Double?; var reason: String? }
        struct Response: Decodable { var models: [Info] }
        var states: [AIIModelState] = []
        // Sewn reads at most 16 ids per call.
        for chunk in stride(from: 0, to: entries.count, by: 16).map({ Array(entries[$0..<min($0 + 16, entries.count)]) }) {
            var components = URLComponents(url: sewnBaseURL.appendingPathComponent("v1/providers/local/models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "ids", value: chunk.map(\.id).joined(separator: ","))]
            let response = try await get(components.url!, as: Response.self)
            for info in response.models {
                let disk: AIIModelState.Disk
                switch info.state {
                case "absent": disk = .absent
                case "downloading": disk = .downloading(info.progress)
                case "installed": disk = .installed
                case "failed": disk = .failed(info.reason)
                default: disk = .unknown(info.state)
                }
                states.append(AIIModelState(id: info.id, disk: disk, entry: AIIModels.entry(id: info.id)))
            }
        }
        return states
    }

    /// Fetch a model without loading it (`POST /v1/providers/local/download`).
    public func download(model id: String) async throws {
        try await post(sewnBaseURL.appendingPathComponent("v1/providers/local/download"), body: ["model": id])
    }

    /// Choose and load the on-device chat model (`POST /v1/providers/local/warm`).
    public func warm(model id: String, load: Bool = true) async throws {
        try await post(sewnBaseURL.appendingPathComponent("v1/providers/local/warm"), body: ["model": id, "load": load])
    }

    /// Delete a model from this Mac (`POST /v1/providers/local/remove`). Sewn refuses
    /// what Thread runs (AIIModels.kept) and what is loaded or downloading.
    public func remove(model id: String) async throws {
        try await post(sewnBaseURL.appendingPathComponent("v1/providers/local/remove"), body: ["model": id])
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await perform(&request)
        do {
            return try AIIHome.decoder.decode(T.self, from: data)
        } catch {
            throw AIIClientError.decoding("\(error)")
        }
    }

    private func post(_ url: URL, body: [String: Any]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try await perform(&request)
    }

    private func perform(_ request: inout URLRequest) async throws -> Data {
        guard let host = request.url?.host(), StackSecret.isLoopback(host: host) else {
            throw AIIClientError.notLoopback(request.url?.host() ?? "?")
        }
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        sign(&request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw AIIClientError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw AIIClientError.unauthorized
        default: throw AIIClientError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()
}
