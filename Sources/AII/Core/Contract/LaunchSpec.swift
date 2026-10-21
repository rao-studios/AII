//
//  LaunchSpec.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Exactly how the shared Sewn and the one Thread are started: executable,
//        arguments, environment, working directory, where they log and where
//        their run record goes.
//  IN:   AIISupervisor, in every app, and the dev scripts.
//  OUT:  Byte-identical launches whichever app does the launching, so a
//        change to Sewn's or Thread's flags is made here once.
//  PIN:  Nothing secret in argv (`ps` shows it to every user): AII_HOME rides
//        in the environment and the servers read their secrets from it. A child
//        inherits only an allowlisted slice of the launcher's environment —
//        never AII_HOME itself or a provider key. Neither server is told which
//        app launched it: both run for every app and learn who is calling from
//        the secret each request carries. Both are the one binary, AIIServer,
//        told which server to be by its first argument.
//

import Foundation

public struct LaunchSpec: Sendable, Equatable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        case sewn
        case thread

        /// The first argument of AIIServer: which server this process is.
        public var subcommand: String { rawValue }

        public var displayName: String {
            switch self {
            case .sewn: return "Sewn"
            case .thread: return "Thread"
            }
        }
    }

    /// The one binary both roles run: AII_HOME/aii/bin/AIIServer, or a checkout's build.
    public static let executableName = "AIIServer"

    public var role: Role
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var ports: AIIPorts
    public var runRecord: URL
    public var logFile: URL
    /// Whose secret /health should prove: X-AII-App on the challenge. An app's, or the
    /// stack's when the aii command launches.
    public var challenge: StackIdentity?

    public init(role: Role, executable: URL, arguments: [String], environment: [String: String],
                workingDirectory: URL, ports: AIIPorts, runRecord: URL, logFile: URL, challenge: StackIdentity?) {
        self.role = role
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.ports = ports
        self.runRecord = runRecord
        self.logFile = logFile
        self.challenge = challenge
    }

    public var healthURL: URL { URL(string: "http://127.0.0.1:\(ports.http)/health")! }
    /// Held while starting or stopping either server, by every launcher in
    /// every app, so two never act at once. Beside the run records: one lock
    /// for the stack.
    public var startLock: URL { runRecord.deletingLastPathComponent().appendingPathComponent("start.lock") }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(ports.http)")! }
}

/// How the one Thread runs. Its models folder is not a choice: HF_HOME is always
/// AII_HOME/models/huggingface, where every Rao app keeps its models — and
/// neither is its embedder: the index is one vector space (AIIModels.embedding),
/// so `--use-mlx` with that model is the default every launcher passes.
public struct ThreadLaunchOptions: Sendable, Equatable {
    /// `--use-mlx`: embed on device, with `mlxModel`.
    public var useMLX: Bool
    /// `--graph-backend mlx|mistral|keyword`. Nil: Thread's default (mlx).
    public var graphBackend: String?
    public var mlxModel: String?
    public var graphModel: String?
    /// Overrides the config's data directory (a test's scratch index).
    public var dataDirectory: URL?
    /// Overrides the config's ports.
    public var ports: AIIPorts?
    /// Register with the shared Sewn. Off: the Thread runs standalone.
    public var mothership: Bool
    /// Appended as given, last.
    public var extraArguments: [String]

    public init(useMLX: Bool = true, graphBackend: String? = nil, mlxModel: String? = AIIModels.embedding.id,
                graphModel: String? = nil, dataDirectory: URL? = nil, ports: AIIPorts? = nil,
                mothership: Bool = true, extraArguments: [String] = []) {
        self.useMLX = useMLX
        self.graphBackend = graphBackend
        self.mlxModel = mlxModel
        self.graphModel = graphModel
        self.dataDirectory = dataDirectory
        self.ports = ports
        self.mothership = mothership
        self.extraArguments = extraArguments
    }
}

public enum LaunchSpecs {

    /// Environment names a child inherits from its launcher.
    public static let inheritedNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TZ",
        "XDG_CACHE_HOME",                       // Frigate's cache root fallback
        "SUPABASE_URL", "SUPABASE_ANON_KEY",    // public; a shell value beats aii.env
    ]

    /// Environment prefixes a child inherits.
    public static let inheritedPrefixes = [
        "LC_",                                  // locale
        "HF_",                                  // HF_HOME, HF_ENDPOINT, HF_HUB_* — model downloads
        "MLX_",                                 // MLX diagnostics and compile switches
        "SEWN_", "THREAD_", "FRIGATE_",         // the servers' own knobs
    ]

    /// Never inherited, even under an allowed prefix: the launcher sets what
    /// matters explicitly.
    public static let neverInherited: Set<String> = [
        AIIHome.environmentKey,
        "THREAD_NODE_ID", "SEWN_DATA_DIR", "THREAD_DATA_DIR",
    ]

    /// The allowlisted slice of `environment`.
    public static func inherited(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            guard !neverInherited.contains(name), !name.hasSuffix("_API_KEY") else { return false }
            return inheritedNames.contains(name) || inheritedPrefixes.contains { name.hasPrefix($0) }
        }
    }

    // MARK: - Sewn

    /// The shared Sewn.
    /// - Parameters:
    ///   - executable: Default AII_HOME/aii/bin/AIIServer; a dev launcher
    ///     passes its checkout's build.
    ///   - workingDirectory: Default AII_HOME/aii. A checkout build runs in
    ///     its checkout so it finds that checkout's `.env`.
    ///   - buildID: Reported as AII_SEWN_BUILD, for logs.
    ///   - challenge: The launching identity, whose secret /health proves.
    ///   - inherited: The launcher's environment; filtered here.
    public static func sewn(
        home: AIIHome,
        config: AIIConfig? = nil,
        executable: URL? = nil,
        workingDirectory: URL? = nil,
        buildID: String? = nil,
        challenge: StackIdentity,
        inherited: [String: String]
    ) -> LaunchSpec {
        let config = config ?? AIIConfig.load(home: home)
        let ports = config.sewnPorts
        var environment = Self.inherited(inherited)
        environment[AIIHome.environmentKey] = PrivateFile.path(home.root)
        environment["HF_HOME"] = PrivateFile.path(home.huggingFaceHome)
        if let buildID { environment["AII_SEWN_BUILD"] = buildID }
        return LaunchSpec(
            role: .sewn,
            executable: executable ?? home.serverBinary,
            arguments: [
                LaunchSpec.Role.sewn.subcommand,
                "--host", "127.0.0.1",
                "--port", String(ports.http),
                "--grpc-port", String(ports.grpc),
                "--data-dir", PrivateFile.path(config.sewnDataDirectory(home: home)),
            ],
            environment: environment,
            workingDirectory: workingDirectory ?? home.aiiDirectory,
            ports: ports,
            runRecord: home.sewnRunRecord,
            logFile: home.sewnLogFile,
            challenge: challenge
        )
    }

    /// The shared Sewn, challenged as an app.
    public static func sewn(
        home: AIIHome,
        config: AIIConfig? = nil,
        executable: URL? = nil,
        workingDirectory: URL? = nil,
        buildID: String? = nil,
        challengeApp: AIIApp,
        inherited: [String: String]
    ) -> LaunchSpec {
        sewn(home: home, config: config, executable: executable, workingDirectory: workingDirectory,
             buildID: buildID, challenge: .app(challengeApp), inherited: inherited)
    }

    // MARK: - Thread

    /// The one Thread.
    /// - Parameters:
    ///   - executable: Default AII_HOME/aii/bin/AIIServer; a dev launcher passes
    ///     its checkout's build.
    ///   - sewnPorts: Where the shared Sewn listens (for registration).
    ///   - workingDirectory: Default AII_HOME/aii. A checkout build runs in
    ///     its checkout so it finds that checkout's `.env`.
    ///   - challenge: The launching identity, whose secret /health proves.
    public static func thread(
        home: AIIHome,
        config: AIIConfig? = nil,
        executable: URL? = nil,
        sewnPorts: AIIPorts? = nil,
        options: ThreadLaunchOptions = ThreadLaunchOptions(),
        workingDirectory: URL? = nil,
        challenge: StackIdentity,
        inherited: [String: String]
    ) -> LaunchSpec {
        let config = config ?? AIIConfig.load(home: home)
        let ports = options.ports ?? config.threadPorts
        let sewnPorts = sewnPorts ?? config.sewnPorts
        let dataDirectory = options.dataDirectory ?? config.threadDataDirectory(home: home)
        var arguments = [
            LaunchSpec.Role.thread.subcommand,
            "--host", "127.0.0.1",
            "--port", String(ports.http),
            "--grpc-port", String(ports.grpc),
        ]
        if options.mothership {
            arguments += [
                "--mothership-host", "127.0.0.1",
                "--mothership-grpc-port", String(sewnPorts.grpc),
            ]
        }
        arguments += ["--data-dir", PrivateFile.path(dataDirectory)]
        if let graphBackend = options.graphBackend ?? config.thread.graphBackend { arguments += ["--graph-backend", graphBackend] }
        if options.useMLX { arguments.append("--use-mlx") }
        if let mlxModel = options.mlxModel { arguments += ["--mlx-model", mlxModel] }
        if let graphModel = options.graphModel { arguments += ["--graph-model", graphModel] }
        arguments += options.extraArguments

        var environment = Self.inherited(inherited)
        environment[AIIHome.environmentKey] = PrivateFile.path(home.root)
        environment["HF_HOME"] = PrivateFile.path(home.huggingFaceHome)

        return LaunchSpec(
            role: .thread,
            executable: executable ?? home.serverBinary,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory ?? home.aiiDirectory,
            ports: ports,
            runRecord: home.threadRunRecord,
            logFile: home.threadLogFile,
            challenge: challenge
        )
    }

    /// The one Thread, challenged as an app.
    public static func thread(
        home: AIIHome,
        config: AIIConfig? = nil,
        executable: URL? = nil,
        sewnPorts: AIIPorts? = nil,
        options: ThreadLaunchOptions = ThreadLaunchOptions(),
        workingDirectory: URL? = nil,
        challengeApp: AIIApp,
        inherited: [String: String]
    ) -> LaunchSpec {
        thread(home: home, config: config, executable: executable, sewnPorts: sewnPorts, options: options,
               workingDirectory: workingDirectory, challenge: .app(challengeApp), inherited: inherited)
    }
}
