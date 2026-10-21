// swift-tools-version: 6.2
// Created by Ritesh Pakala on 10/21/26.
// Copyright © 2026 Rao Studios LLC.
// WHAT: AII — the Ambient Intelligence Index, one package for the local stack every app runs on.
//       Libraries: AII (the foundation — the ~/.rao contract, keys, lanes, the record schema, the
//       master model list, launcher, supervisor, status client — and Join/, what an app inherits and
//       holds: AIIAppDescriptor, AIIRecordable, AIIInstance), Seam (the gRPC wire), Sewn and Thread (the
//       two servers, as libraries). Two executables: AIIServer (`AIIServer sewn …`, `AIIServer thread …`,
//       `AIIServer probe …`) and aii, the command that manages the stack on this Mac.
// OUT:  Apps take this package by URL with `traits: []` and name AII (and Seam, to speak the wire
//       themselves). AIIServer is built from this checkout by Scripts/build-servers.sh into
//       .build/<config>/ and installed into ~/.rao/aii/bin by `aii install` or an app's bundle
//       (AIIInstaller) — never built by an app.
// PIN:  The `Server` trait, on by default, gates every dependency only the servers and the aii command
//       need: Frigate (MLX and its SinatraHarness product), ArgumentParser, Hummingbird, HummingbirdWebSocket,
//       Web3, Supabase, Prometheus. With the trait off, SwiftPM 6.2+ prunes those packages from resolution, so an app
//       never fetches MLX; one unguarded reference would undo that. No path dependencies: a fresh clone
//       resolves on its own (Scripts/setup.sh). grpc,
//       protobuf, log and crypto are shared by Seam and AII and stay unconditional. No type shares a
//       module's name (AII, Seam, Sewn, Thread, AIIServer, AIICLI). Foundation's `Thread` class shadows
//       the Thread module for qualified lookups, so nothing writes `Thread.X`. Floor macOS 15.
import PackageDescription

let package = Package(
    name: "AII",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AII", targets: ["AII"]),
        .library(name: "Seam", targets: ["Seam"]),
        .library(name: "Sewn", targets: ["Sewn"]),
        .library(name: "Thread", targets: ["Thread"]),
        .executable(name: "AIIServer", targets: ["AIIServer"]),
        .executable(name: "aii", targets: ["AIICLI"]),
    ],
    traits: [
        .trait(
            name: "Server",
            description: "Build the servers: links Frigate (MLX and SinatraHarness), Hummingbird, Supabase, Web3, Prometheus and ArgumentParser."),
        .default(enabledTraits: ["Server"]),
    ],
    dependencies: [
        // Shared by Seam and AII — unconditional, resolved by every consumer.
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
        // Server only. Every use below carries `.when(traits: ["Server"])`, so a consumer with
        // `traits: []` never resolves these.
        .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMajor(from: "1.3.0")),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/Boilertalk/Web3.swift.git", from: "0.6.0"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.41.1"),
        .package(url: "https://github.com/swift-server/swift-prometheus.git", from: "2.0.0"),
        // Frigate: the vendored MLX stack, and the SinatraHarness product (GPL-3.0-only inside the MIT
        // package) that Sewn's `local` provider runs through. To iterate on it beside AII:
        // `swift package edit Frigate --path ../Frigate` (Scripts/build-metallib.sh follows the edit).
        .package(url: "https://github.com/rao-studios/Frigate.git", branch: "main"),
    ],
    targets: [
        // MARK: - AII — Core/, the foundation (Contract/, Keys/, Models/, Launcher/ (macOS only),
        // Supervisor/, Client/), and Join/, what an app inherits and holds. On Seam and the
        // gRPC wire every consumer already resolves; never MLX, never server code.
        .target(
            name: "AII",
            dependencies: [
                "Seam",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // MARK: - Seam — the wire. Generated protobuf/gRPC code under Generated/, from Protos/.
        .target(
            name: "Seam",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // MARK: - Sewn — the HTTP/WS server as a library. Swift 5 mode: MLXArray is not Sendable.
        .target(
            name: "Sewn",
            dependencies: [
                "Seam",
                "AII",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["Server"])),
                .product(name: "Hummingbird", package: "hummingbird", condition: .when(traits: ["Server"])),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket", condition: .when(traits: ["Server"])),
                .product(name: "Web3", package: "Web3.swift", condition: .when(traits: ["Server"])),
                .product(name: "Web3PromiseKit", package: "Web3.swift", condition: .when(traits: ["Server"])),
                .product(name: "Web3ContractABI", package: "Web3.swift", condition: .when(traits: ["Server"])),
                .product(name: "Supabase", package: "supabase-swift", condition: .when(traits: ["Server"])),
                .product(name: "Prometheus", package: "swift-prometheus", condition: .when(traits: ["Server"])),
                // The on-device provider; every call site is behind `#if canImport(MLXLLM)`.
                .product(name: "MLX", package: "Frigate", condition: .when(platforms: [.macOS], traits: ["Server"])),
                .product(name: "MLXLMCommon", package: "Frigate", condition: .when(platforms: [.macOS], traits: ["Server"])),
                .product(name: "MLXLLM", package: "Frigate", condition: .when(platforms: [.macOS], traits: ["Server"])),
                // The on-device vision slot (LocalVision). Once this is linked, MLXLMCommon's
                // registry would try the VLM factory first, so SinatraHarness loads chat models
                // through LLMModelFactory by name.
                .product(name: "MLXVLM", package: "Frigate", condition: .when(platforms: [.macOS], traits: ["Server"])),
                .product(name: "FrigateBridge", package: "Frigate", condition: .when(platforms: [.macOS], traits: ["Server"])),
                .product(name: "SinatraHarness", package: "Frigate", condition: .when(platforms: [.macOS], traits: ["Server"])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - Thread — the index as a library (Swift 6 mode).
        .target(
            name: "Thread",
            dependencies: [
                "Seam",
                "AII",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["Server"])),
                .product(name: "Hummingbird", package: "hummingbird", condition: .when(traits: ["Server"])),
                .product(name: "MLX", package: "Frigate", condition: .when(traits: ["Server"])),
                .product(name: "MLXLMCommon", package: "Frigate", condition: .when(traits: ["Server"])),
                .product(name: "MLXLLM", package: "Frigate", condition: .when(traits: ["Server"])),
                .product(name: "mlx_embeddings", package: "Frigate", condition: .when(traits: ["Server"])),
                .product(name: "MLXAccelerate", package: "Frigate", condition: .when(traits: ["Server"])),
                .product(name: "Frigate", package: "Frigate", condition: .when(traits: ["Server"])),
                // mlx-swift-lm 3.x takes the downloader and tokenizer as parameters; FrigateBridge
                // carries Frigate's concrete HubDownloader / HubTokenizerLoader.
                .product(name: "FrigateBridge", package: "Frigate", condition: .when(traits: ["Server"])),
            ]
        ),
        // MARK: - AIIServer — the one binary: a root command whose subcommands are the two
        // servers (`sewn`, `thread`) and the probe (`probe`, a terminal client for Sewn's chat wire).
        .executableTarget(
            name: "AIIServer",
            dependencies: [
                "Sewn",
                "Thread",
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["Server"])),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MARK: - AIICLI — the `aii` command and its studio: whose build is installed, the two servers,
        // the lanes, the models, and a doctor. AII and ArgumentParser only (no Seam, no MLX); behind the
        // Server trait like AIIServer, so a consumer with `traits: []` never resolves ArgumentParser.
        .executableTarget(
            name: "AIICLI",
            dependencies: [
                "AII",
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["Server"])),
            ]
        ),
        // MARK: - Tests
        // AIITests holds Generated/ (record.proto, lanes.proto, internal), for the
        // conformance tests: AII's Swift forms against their proto3 JSON.
        .testTarget(
            name: "AIITests",
            dependencies: [
                "AII", "Seam",
                .product(name: "GRPCInProcessTransport", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "AIICLITests",
            dependencies: ["AIICLI", "AII"]
        ),
        .testTarget(
            name: "SeamTests",
            dependencies: [
                "Seam",
                .product(name: "GRPCInProcessTransport", package: "grpc-swift"),
            ]
        ),
        .testTarget(
            name: "SewnTests",
            dependencies: [
                "Sewn", "Seam", "AII",
                .product(name: "HummingbirdTesting", package: "hummingbird", condition: .when(traits: ["Server"])),
            ]
        ),
        .testTarget(
            name: "ThreadTests",
            dependencies: [
                "Thread", "Seam", "AII",
                .product(name: "HummingbirdTesting", package: "hummingbird", condition: .when(traits: ["Server"])),
            ]
        ),
    ]
)
