//
//  ThreadGRPCServer.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Seam
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import AII

actor ThreadGRPCServer {
    private var serverTask: Task<Void, Error>?

    func start(
        database: Database,
        embeddingProvider: any EmbeddingProviding,
        graphExtractor: any GraphExtracting,
        host: String,
        grpcPort: Int,
        stack: StackMode,
        resolver: LaneResolver = .unscoped
    ) {
        let query   = ThreadQueryServiceImpl(database: database, embeddingProvider: embeddingProvider,
                                            graphExtractor: graphExtractor, resolver: resolver)
        let library = ThreadLibraryServiceImpl(database: database, resolver: resolver)
        let graph   = ThreadGraphServiceImpl(database: database, embeddingProvider: embeddingProvider, resolver: resolver)
        let update  = ThreadUpdateServiceImpl(database: database, resolver: resolver)
        serverTask = Task {
            let transport = HTTP2ServerTransport.Posix(
                // Where the HTTP server binds (`--host`): loopback for a Thread an
                // app launched for itself, 0.0.0.0 only where a deployment asks.
                address: .ipv4(host: host, port: grpcPort),
                transportSecurity: .plaintext,
                config: .defaults {
                    // Direct-connect clients (Bonnie) push deposits and pull
                    // full document content here. The default 64 KiB receive
                    // window throttles anything sizeable to ~window/RTT —
                    // same congestion fix as the mothership session transport.
                    $0.rpc.maxRequestPayloadSize = 100 * 1024 * 1024
                    $0.http2.targetWindowSize = 16 * 1024 * 1024
                    $0.http2.maxFrameSize = 1 << 20
                    $0.compression.enabledAlgorithms = [.gzip, .none]
                }
            )
            // Local mode: a stack secret gates every RPC — Remove and ExportCorpus
            // among them — as StackSecretMiddleware does for HTTP. On the shared
            // stack every identity's secret is accepted (the impls then cut each
            // call to that identity's lane); on a one-app stack the one secret.
            // Hosted (no env var): nothing is installed.
            let seamLogger = SwiftLogSeamLogger(database.logger.base)
            let interceptors = StackSecretServerInterceptor.forLocalMode(resolver: stack.grpcResolver, logger: seamLogger)
            let server = GRPCServer(
                transport: transport,
                services: [query, library, graph, update],
                interceptors: interceptors)
            database.logger.info("ThreadGRPCServer", "gRPC server listening on \(host):\(grpcPort)", service: .startup)
            do {
                try await server.serve()
            } catch is CancellationError {
                // stop() — a shutdown, not a failure.
            } catch {
                // Most often the port is taken. Dying loudly lets the launcher
                // see it, rather than a Thread nobody can query.
                database.logger.error("ThreadGRPCServer", "gRPC server on \(host):\(grpcPort) failed: \(error)", service: .startup)
                exit(EXIT_FAILURE)
            }
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
    }
}
