//
//  ThreadWire.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: How AIIInstance reaches the one Thread: its direct gRPC port, one connection per
//        call, every call carrying the app's own secret.
//  IN:   AIIInstance (remember, recall, forget).
//  OUT:  The seven calls AIIInstance and AIILaneInspector make, as the generated Seam types.
//  PIN:  Direct, never through Sewn: the lane comes from the secret the call presents,
//        and RemoveGroups is served on the direct port only. Loopback only. The port is
//        read per call, so a moved Thread (aii/config.json) is found. A protocol so tests
//        stand a fake in.
//

#if os(macOS)
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Seam

protocol ThreadWire: Sendable {
    func index(_ request: Thread_V1_ThreadIndexRequest) async throws -> Thread_V1_ThreadIndexResponse
    func search(_ request: Thread_V1_ThreadSearchRequest) async throws -> Thread_V1_ThreadSearchResponse
    func remove(_ request: Thread_V1_ThreadRemoveRequest) async throws -> Thread_V1_ThreadRemoveResponse
    func removeGroups(_ request: Thread_V1_ThreadRemoveGroupsRequest) async throws -> Thread_V1_ThreadRemoveGroupsResponse
    func documents(_ request: Thread_V1_ThreadDocumentsRequest) async throws -> Thread_V1_ThreadDocumentsResponse
    func library(_ request: Thread_V1_ThreadLibraryRequest) async throws -> Thread_V1_ThreadLibraryResponse
    func exportCorpus(_ request: Thread_V1_ThreadExportCorpusRequest) async throws -> Thread_V1_ThreadExportCorpusResponse
}

struct PosixThreadWire: ThreadWire {
    let home: AIIHome
    let identity: StackIdentity

    func index(_ request: Thread_V1_ThreadIndexRequest) async throws -> Thread_V1_ThreadIndexResponse {
        try await call { try await Thread_V1_ThreadQuery.Client(wrapping: $0).index(request, options: Self.options) }
    }

    func search(_ request: Thread_V1_ThreadSearchRequest) async throws -> Thread_V1_ThreadSearchResponse {
        try await call { try await Thread_V1_ThreadQuery.Client(wrapping: $0).search(request, options: Self.options) }
    }

    func remove(_ request: Thread_V1_ThreadRemoveRequest) async throws -> Thread_V1_ThreadRemoveResponse {
        try await call { try await Thread_V1_ThreadQuery.Client(wrapping: $0).remove(request, options: Self.options) }
    }

    func removeGroups(_ request: Thread_V1_ThreadRemoveGroupsRequest) async throws -> Thread_V1_ThreadRemoveGroupsResponse {
        try await call { try await Thread_V1_ThreadUpdate.Client(wrapping: $0).removeGroups(request, options: Self.options) }
    }

    func documents(_ request: Thread_V1_ThreadDocumentsRequest) async throws -> Thread_V1_ThreadDocumentsResponse {
        try await call { try await Thread_V1_ThreadLibrary.Client(wrapping: $0).documents(request, options: Self.options) }
    }

    func library(_ request: Thread_V1_ThreadLibraryRequest) async throws -> Thread_V1_ThreadLibraryResponse {
        try await call { try await Thread_V1_ThreadLibrary.Client(wrapping: $0).library(request, options: Self.options) }
    }

    func exportCorpus(_ request: Thread_V1_ThreadExportCorpusRequest) async throws -> Thread_V1_ThreadExportCorpusResponse {
        try await call { try await Thread_V1_ThreadLibrary.Client(wrapping: $0).exportCorpus(request, options: Self.options) }
    }

    private static let options: CallOptions = {
        var options = CallOptions.defaults
        options.timeout = .seconds(60)
        options.maxRequestMessageBytes = 32 << 20
        options.maxResponseMessageBytes = 32 << 20
        return options
    }()

    private func call<R: Sendable>(_ body: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> R) async throws -> R {
        let port = AIIConfig.load(home: home).threadPorts.grpc
        let transport = try HTTP2ClientTransport.Posix.http2NIOPosix(
            target: .ipv4(host: "127.0.0.1", port: port), transportSecurity: .plaintext)
        let (home, identity) = (home, identity)
        let secret = StackSecretClientInterceptor(secret: { try? home.readSecret(for: identity) })
        return try await withGRPCClient(transport: transport, interceptors: [secret]) { client in
            try await body(client)
        }
    }
}
#endif
