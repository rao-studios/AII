//
//  ThreadServer.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import ArgumentParser
import Seam
import Foundation
import GRPCCore
import Logging
import Hummingbird
import AII
#if canImport(MLX)
import Frigate
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension ThreadServer {
    /// The stack secret rides only to the loopback mothership the launcher
    /// started — never to a remote one, and never to Fleet. On the shared
    /// ~/.rao stack it is the stack's own identity (`secrets/aii`): one Thread
    /// serves every app, and Sewn records its node as `aii`, visible to all.
    static func mothershipInterceptors(secret: String?, mothershipHost: String) -> [any ClientInterceptor] {
        guard let secret, !secret.isEmpty, StackSecret.isLoopback(authority: mothershipHost) else { return [] }
        return [StackSecretClientInterceptor(secret: secret)]
    }

    /// The secret this Thread registers with: the stack identity's on the shared
    /// stack, none when open.
    static func mothershipSecret(stack: StackMode) -> String? {
        stack.keyring?.secret(for: .stack)
    }

    /// Where on-device models live: AII's `<rao home>/models/huggingface` — AII_HOME's, else
    /// ~/.rao's. Mandatory for every Rao app: HF_HOME does not move it, and nothing goes to
    /// Frigate's own default (~/.cache/huggingface).
    static func modelsHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        AIIHome.resolved(environment).huggingFaceHome
    }

    /// Where this Thread keeps its state: `--data-dir`, then THREAD_DATA_DIR,
    /// then — on the shared stack — AII_HOME/aii/thread/db, the one index every
    /// app's lane lives in; nil leaves FilePersistence's own default.
    static func resolveDataDirectory(argument: String?, environment: [String: String]) -> String? {
        if let argument, !argument.isEmpty { return argument }
        if let fromEnvironment = environment["THREAD_DATA_DIR"], !fromEnvironment.isEmpty { return fromEnvironment }
        if let home = try? AIIHome.fromEnvironment(environment) {
            return PrivateFile.path(home.threadDataDirectory)
        }
        return nil
    }

    /// The shared stack's lanes and the stack's own secret, made on first start so
    /// a Thread that comes up before any app ran still registers (Sewn's keyring
    /// picks `secrets/aii` up on its next miss): a lane for every app with a secret,
    /// then a live registry for the apps that register later. Unscoped off the stack.
    static func prepareStack(_ stack: StackMode, environment: [String: String], logger: Logger) -> LaneResolver {
        guard stack.keyring != nil, let home = try? AIIHome.fromEnvironment(environment) else {
            return LaneResolver(stack: stack, lanes: nil)
        }
        do {
            _ = try home.ensureSecret(for: .stack)
            let lanes = try AIILanes.ensure(home: home)
            logger.info("Lanes: \(lanes.apps.map { "\($0.rawValue)=\(lanes.id(for: $0)?.rawValue ?? "?")" }.joined(separator: " "))")
            return LaneResolver(stack: stack, lanes: AIILaneRegistry(home: home))
        } catch {
            // Without lanes every app's request is refused — loudly, in the log the
            // launcher tails — rather than filed somewhere nobody can read it back.
            logger.error("Lanes: could not prepare ~/.rao for the shared index: \(error)")
            return LaneResolver(stack: stack, lanes: nil)
        }
    }
}

func configureRoutes(
    _ router: Router<ThreadRequestContext>,
    _ database: Database,
    embeddingModelProvider: any EmbeddingProviding,
    graphExtractor: any GraphExtracting,
    stack: StackMode,
    resolver: LaneResolver = .unscoped
) {
    registerHealthRoute(router, stack: stack) {
        HealthEmbedder(provider: embeddingModelProvider, index: await database.indexState)
    }
    registerSearchRoute(router, database, embeddingModelProvider: embeddingModelProvider, resolver: resolver)
    registerBatchEmbeddingsRoute(router, database, embeddingModelProvider: embeddingModelProvider,
                                 graphExtractor: graphExtractor, resolver: resolver)
    registerLibraryRoute(router, database, resolver: resolver)
    registerGraphRoute(router, database, embeddingModelProvider: embeddingModelProvider, resolver: resolver)
    registerGraphAdminRoutes(router, database, embeddingModelProvider: embeddingModelProvider,
                             graphExtractor: graphExtractor, resolver: resolver)
    registerStatsRoute(router, database, resolver: resolver)
}

/// Thread, as `AIIServer thread …` runs it. Public for the one binary's root command; the
/// options and everything else stay internal (ThreadTests reaches them with `@testable`).
public struct ThreadServer: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "thread",
        abstract: "Thread: the index of the Ambient Intelligence Index.")

    public init() {}

    @ArgumentParser.Option(name: .long, help: "Host address.")
    var host: String = AppConstants.defaultHost

    @ArgumentParser.Option(name: .long, help: "Port number.")
    var port: Int = AppConstants.defaultPort

    @ArgumentParser.Flag(name: .long, help: "Disable LLM graph extraction (keyword entities only).")
    var noGraphExtraction: Bool = false

    @ArgumentParser.Option(name: .long, help: "Graph extraction backend: mlx (on-device, default) | mistral (API) | keyword.")
    var graphBackend: String = "mlx"

    @ArgumentParser.Option(name: .long, help: "Mistral model for API graph extraction.")
    var graphMistralModel: String = "mistral-tiny"

    #if canImport(MLX)
    @ArgumentParser.Flag(name: .long, help: "Use on-device MLX embedding model instead of Mistral API.")
    var useMLX: Bool = false

    @ArgumentParser.Option(name: .long, help: "On-device embedding model: a Hub repo (org/repo[@revision]) or a snapshot directory. Default: the AII master list's embedding model.")
    var mlxModel: String = AIIModels.embedding.pinnedSpec

    @ArgumentParser.Option(name: .long, help: "MLX Hub model ID for on-device graph extraction (an instruct LLM; embedding is --mlx-model). Default: the AII master list's standard general model.")
    var graphModel: String = MLXGraphExtractionProvider.defaultModel
    #endif

    @ArgumentParser.Option(name: .long, help: "gRPC server port for Database fan-out calls.")
    var grpcPort: Int = 9090

    @ArgumentParser.Option(name: .long, help: "Mothership (Database) host. Leave empty to run standalone.")
    var mothershipHost: String = ""

    @ArgumentParser.Option(name: .long, help: "Mothership (Database) gRPC port.")
    var mothershipGrpcPort: Int = 9091

    @ArgumentParser.Option(name: .long, help: "Fleet destination host (for dataset import). Leave empty to skip.")
    var fleetHost: String = ""

    @ArgumentParser.Option(name: .long, help: "Fleet destination gRPC port.")
    var fleetGrpcPort: Int = 9092

    @ArgumentParser.Option(name: .long, help: "Fixed node UUID (env THREAD_NODE_ID). Overrides any persisted node-id on disk.")
    var nodeId: String?

    @ArgumentParser.Option(name: .long, help: "Directory for on-disk state (default ~/Documents/thread-db; env THREAD_DATA_DIR).")
    var dataDir: String?

    enum CodingKeys: CodingKey {
        case host, port, grpcPort, mothershipHost, mothershipGrpcPort, fleetHost, fleetGrpcPort, nodeId, dataDir
        case noGraphExtraction, graphBackend, graphMistralModel
        #if canImport(MLX)
        case useMLX, mlxModel, graphModel
        #endif
    }

    @MainActor
    public func run() async throws {
        // ── Load .env before anything reads ProcessInfo.environment ──────────────
        loadDotEnv()

        // ── Stack secret: decided once, before anything answers. A Thread told
        // to use AII_HOME never comes up open: it serves every identity's secret
        // and cuts each call to that identity's lane.
        let stack: StackMode
        do {
            stack = try StackMode.thread(environment: ProcessInfo.processInfo.environment)
        } catch {
            FileHandle.standardError.write(Data("thread: can't start the local stack: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }

        // ── Storage root: --data-dir, THREAD_DATA_DIR, AII_HOME/aii/thread/db,
        // then ~/Documents/thread-db
        let dataRoot = FilePersistence.configure(
            dataDirectory: Self.resolveDataDirectory(argument: dataDir, environment: ProcessInfo.processInfo.environment))

        // ── Logging ──────────────────────────────────────────────────────────────
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
        var logger = Logger(label: "thread")
        logger.logLevel = .debug
        logger.info("Storage root: \(dataRoot.path)")
        logger.info("Stack: \(stack.summary)")
        let resolver = Self.prepareStack(stack, environment: ProcessInfo.processInfo.environment, logger: logger)

        // ── Core services ─────────────────────────────────────────────────────────
        let (fixedNodeId, rejectedNodeId) = NodeIdentity.override(
            argument: nodeId, environment: ProcessInfo.processInfo.environment)
        if let rejectedNodeId {
            logger.warning("NodeIdentity: ignoring a node id that is not a UUID (\(rejectedNodeId.prefix(16))…); using the persisted one")
        }
        let database = Database(nodeId: fixedNodeId)
        let embeddingModelProvider: any EmbeddingProviding = makeEmbeddingProvider()
        let graphExtractor: any GraphExtracting = makeGraphExtractor()

        // Fetch and load the embedder now: a first run downloads it, and the first
        // filing should not be what waits. Then hold the table against its stamp.
        Task.detached { await embeddingModelProvider.warmup() }
        Task {
            await database.initializationTask.value
            if let space = embeddingModelProvider.vectorSpace {
                let health = embeddingModelProvider.health
                await database.reconcileEmbedder(
                    vectorSpace: space,
                    model: health?.model ?? space,
                    revision: health?.revision)
            }
        }

        // ── Router + middleware ───────────────────────────────────────────────────
        let router = Router(context: ThreadRequestContext.self)
        if stack.isLocal {
            // Launched by an app for itself: no browser is a client, so no
            // CORS — and every request must carry the app's secret. Nothing
            // else guards these routes (/v1/clear among them). Added before
            // any route: Hummingbird binds middleware at registration.
            router.middlewares.add(StackSecretMiddleware<ThreadRequestContext>(mode: stack))
        } else {
            router.middlewares.add(CORSMiddleware(
                allowOrigin: .all,
                allowHeaders: [.accept, .authorization, .contentType, .origin],
                allowMethods: [.get, .post, .options]
            ))
        }

        // ── Register ALL routes before Application.init freezes the responder ────
        configureRoutes(router, database, embeddingModelProvider: embeddingModelProvider,
                        graphExtractor: graphExtractor, stack: stack, resolver: resolver)

        // ── GRPC Server ────────────────────
        let grpcServer = ThreadGRPCServer()
        await grpcServer.start(database: database, embeddingProvider: embeddingModelProvider,
                               graphExtractor: graphExtractor, host: host, grpcPort: grpcPort,
                               stack: stack, resolver: resolver)

        // A Thread can dial a Sewn mothership and/or a Fleet destination. Both reuse
        // the same destination-agnostic dispatcher (it serves search/library/graph).
        // Strong owners that must outlive `app.runService()`. The registration
        // clients spawn their heartbeat/session loops with `[weak self]`, so
        // without an owner here the actor is deallocated the moment its first
        // session ends — after which the reconnect loop sees a nil `self` and
        // silently stops. The mothership client happened to survive only because
        // the availability route closure retained it; the Fleet client had no
        // such owner and so never reconnected.
        var registrationClients: [MothershipRegistrationClient] = []

        if !mothershipHost.isEmpty || !fleetHost.isEmpty {
            let dispatcher = MothershipRequestDispatcher(
                database: database,
                embeddingProvider: embeddingModelProvider,
                graphExtractor: graphExtractor,
                logger: logger,
                resolver: resolver
            )

            if !mothershipHost.isEmpty {
                let client = MothershipRegistrationClient(
                    mothershipHost: mothershipHost,
                    mothershipGRPCPort: mothershipGrpcPort,
                    threadId: database.nodeId,
                    threadHost: host,
                    threadGRPCPort: grpcPort,
                    threadHTTPPort: port,
                    requestDispatcher: dispatcher,
                    logger: SwiftLogSeamLogger(logger),
                    interceptors: Self.mothershipInterceptors(
                        secret: Self.mothershipSecret(stack: stack), mothershipHost: mothershipHost)
                )
                await client.startHeartbeatLoop()
                registerAvailabilityRoute(router, registrationClient: client)
                registrationClients.append(client)
            }

            if !fleetHost.isEmpty {
                let fleetClient = MothershipRegistrationClient(
                    mothershipHost: fleetHost,
                    mothershipGRPCPort: fleetGrpcPort,
                    threadId: database.nodeId,
                    threadHost: host,
                    threadGRPCPort: grpcPort,
                    threadHTTPPort: port,
                    requestDispatcher: dispatcher,
                    logger: SwiftLogSeamLogger(logger)
                )
                await fleetClient.startHeartbeatLoop()
                registrationClients.append(fleetClient)
                logger.info("Thread: connecting to Fleet destination \(fleetHost):\(fleetGrpcPort)")
            }
        }

        // ── Build Application AFTER all routes are registered ────────────────────
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "Thread"
            ),
            logger: logger
        )

        let threadLogger = ThreadLogger(logger)
        threadLogger.info("Startup", "Thread starting on http://\(host):\(port)", service: .startup)

        do {
            try await app.runService()
        } catch {
            await database.shutdown()
            throw error
        }
        await database.shutdown()

        // Keep the registration clients alive across the whole serve loop above;
        // their session/heartbeat tasks hold only `[weak self]`.
        withExtendedLifetime(registrationClients) {}
    }

    /// Reads the `.env` file from the working directory and injects any
    /// `KEY=VALUE` pairs into the process environment via `setenv`.
    /// Existing OS-level env vars are never overwritten (overwrite flag = 0),
    /// so a value already exported in the shell always wins.
    /// Hummingbird has no built-in dotenv support unlike Vapor's
    /// `Environment.dotenv()`; this replaces that functionality.
    private func loadDotEnv() {
        let path = FileManager.default.currentDirectoryPath + "/.env"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let eqRange = trimmed.range(of: "=") else { continue }
            let key   = String(trimmed[..<eqRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[eqRange.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            setenv(key, value, 0) // 0 = don't overwrite an already-exported var
        }
    }

    private func makeEmbeddingProvider() -> any EmbeddingProviding {
        var logger = Logger(label: "thread")
        logger.logLevel = .debug
        #if canImport(MLX)
        if useMLX {
            if MLXRuntimeProbe.metalKernelLibraryAvailable() {
                logger.info("Embedding backend: MLX (\(mlxModel))")
                return MLXEmbeddingModelProvider(modelId: mlxModel, modelsHome: Self.modelsHome())
            }
            logger.warning("Embedding backend: MLX requested but this build has no Metal kernel library (default.metallib) — MLX would abort the process. Falling back to Mistral API.")
        }
        #endif
        logger.info("Embedding backend: Mistral API (mistral-embed)")
        return EmbeddingModelProvider(logger: logger)
    }

    /// LLM extraction backend selection: on-device MLX (default), Mistral API,
    /// or keyword-only. Extraction failures never fail ingest — GraphEnrichment
    /// keeps the keyword entities.
    private func makeGraphExtractor() -> any GraphExtracting {
        var logger = Logger(label: "thread")
        logger.logLevel = .debug

        guard !noGraphExtraction else {
            logger.info("Graph extraction: disabled — keyword entities only")
            return KeywordGraphExtractionProvider()
        }

        switch graphBackend {
        case "mistral":
            let keys = ProviderKeyStore.process
            let key = keys.value(for: ProviderKeyStore.mistralAPIKey) ?? ""
            if key.isEmpty {
                guard keys.isFileBacked else {
                    logger.warning("Graph extraction: Mistral backend requested but MISTRAL_API_KEY is not set — falling back to keyword extraction.")
                    return KeywordGraphExtractionProvider()
                }
                // A shared stack reads the key per call: a user who saves one
                // after launch gets extraction without a restart. Until then
                // each attempt fails and ingest keeps the keyword entities.
                logger.warning("Graph extraction: no Mistral key yet in AII_HOME/keys — extraction starts once one is saved.")
            }
            logger.info("Graph extraction: Mistral API (\(graphMistralModel))")
            return MistralGraphExtractionProvider(model: graphMistralModel, logger: logger)

        case "mlx":
            #if canImport(MLX)
            if MLXRuntimeProbe.metalKernelLibraryAvailable() {
                logger.info("Graph extraction: MLX (\(graphModel))")
                return MLXGraphExtractionProvider(modelId: graphModel, modelsHome: Self.modelsHome())
            }
            logger.warning("Graph extraction: MLX requested but this build has no Metal kernel library (default.metallib) — MLX would abort the process on first use. Falling back to keyword extraction; use --graph-backend mistral for API extraction, or rebuild Frigate with its metallib step.")
            #else
            logger.warning("Graph extraction: MLX backend requested but this build has no MLX support — falling back to keyword extraction (use --graph-backend mistral for API extraction).")
            #endif
            return KeywordGraphExtractionProvider()

        default:
            logger.info("Graph extraction: keyword backend")
            return KeywordGraphExtractionProvider()
        }
    }
}
