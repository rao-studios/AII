//
//  LaunchSpecTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import XCTest
@testable import AII

final class LaunchSpecTests: XCTestCase {
    let home = AIIHome(root: URL(fileURLWithPath: "/tmp/rao"))
    let shell: [String: String] = [
        "PATH": "/usr/bin", "HOME": "/Users/x", "LANG": "en_US.UTF-8", "HF_ENDPOINT": "https://hf",
        "MISTRAL_API_KEY": "leaked?", "OPENAI_API_KEY": "leaked?",
        "AII_HOME": "/elsewhere", "THREAD_NODE_ID": "stale", "SEWN_DATA_DIR": "/stale", "AWS_SECRET": "no",
        "THREAD_PQ_MLX": "1",
    ]

    func testSewnRunsFromTheHomeOnTheSharedPorts() {
        let spec = LaunchSpecs.sewn(home: home, config: AIIConfig(), challengeApp: .ambient, inherited: shell)
        XCTAssertEqual(spec.role, .sewn)
        XCTAssertEqual(PrivateFile.path(spec.executable), "/tmp/rao/aii/bin/AIIServer")
        XCTAssertEqual(spec.arguments, ["sewn", "--host", "127.0.0.1", "--port", "47080", "--grpc-port", "47091",
                                        "--data-dir", "/tmp/rao/aii/sewn/db"], "the role is the binary's first argument")
        XCTAssertEqual(PrivateFile.path(spec.workingDirectory), "/tmp/rao/aii")
        XCTAssertEqual(spec.environment["AII_HOME"], "/tmp/rao")
        XCTAssertEqual(spec.environment["HF_HOME"], "/tmp/rao/models/huggingface")
        XCTAssertNil(spec.environment["SEWN_DATA_DIR"], "never inherited, even under an allowed prefix")
        XCTAssertNil(spec.environment["MISTRAL_API_KEY"])
        XCTAssertNil(spec.environment["OPENAI_API_KEY"])
        XCTAssertNil(spec.environment["AWS_SECRET"])
        XCTAssertEqual(spec.environment["HF_ENDPOINT"], "https://hf")
        XCTAssertEqual(spec.challenge, .app(.ambient))
        XCTAssertEqual(PrivateFile.path(spec.startLock), "/tmp/rao/aii/run/start.lock")
        XCTAssertEqual(PrivateFile.path(spec.runRecord), "/tmp/rao/aii/run/sewn.json")
    }

    func testSewnHonoursItsConfig() {
        let config = AIIConfig(sewn: .init(httpPort: 1, grpcPort: 2, dataDir: "/data/sewn"))
        let spec = LaunchSpecs.sewn(home: home, config: config, executable: URL(fileURLWithPath: "/checkout/AIIServer"),
                                    workingDirectory: URL(fileURLWithPath: "/checkout"), challengeApp: .craft, inherited: [:])
        XCTAssertEqual(spec.arguments, ["sewn", "--host", "127.0.0.1", "--port", "1", "--grpc-port", "2", "--data-dir", "/data/sewn"])
        XCTAssertEqual(spec.environment["HF_HOME"], "/tmp/rao/models/huggingface")
        XCTAssertEqual(PrivateFile.path(spec.workingDirectory), "/checkout")
    }

    /// A config made of keys this build does not read is no config at all: the defaults
    /// apply, and the models stay in AII_HOME.
    func testAnUnfamiliarConfigReadsAsTheDefaults() throws {
        let test = TestHome()
        try PrivateFile.ensureDirectory(test.home.aiiDirectory)
        try PrivateFile.writeAtomically(Data(#"{"hfHome":"~/Documents/huggingface","httpPort":1}"#.utf8), to: test.home.aiiConfigFile)
        let config = AIIConfig.load(home: test.home)
        XCTAssertEqual(config, AIIConfig())
        let spec = LaunchSpecs.sewn(home: test.home, config: config, challengeApp: .ambient,
                                    inherited: ["HF_HOME": "/Users/x/Documents/huggingface"])
        XCTAssertEqual(spec.environment["HF_HOME"], PrivateFile.path(test.home.huggingFaceHome))
        XCTAssertEqual(spec.ports, AIIPortPlan.sewn)
    }

    func testTheConfigNamesBothServers() throws {
        let config = AIIConfig(sewn: .init(httpPort: 1), thread: .init(grpcPort: 9, dataDir: "/Volumes/T9/index", graphBackend: "keyword"))
        let data = try AIIHome.encoder.encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AIIConfig.self, from: data), config)
        XCTAssertEqual(config.sewnPorts, AIIPorts(http: 1, grpc: AIIPortPlan.sewn.grpc))
        XCTAssertEqual(config.threadPorts, AIIPorts(http: AIIPortPlan.thread.http, grpc: 9))
        XCTAssertEqual(PrivateFile.path(config.threadDataDirectory(home: home)), "/Volumes/T9/index")
    }

    /// The one Thread runs for every app: no app, no secret, no node id in its environment;
    /// the index embeds with the master list's model.
    func testTheThreadRunsForEveryAppWithNothingSecretAnywhere() {
        let spec = LaunchSpecs.thread(home: home, config: AIIConfig(), challengeApp: .craft, inherited: shell)
        XCTAssertEqual(spec.role, .thread)
        XCTAssertEqual(PrivateFile.path(spec.executable), "/tmp/rao/aii/bin/AIIServer")
        XCTAssertEqual(spec.arguments, [
            "thread", "--host", "127.0.0.1", "--port", "47081", "--grpc-port", "47090",
            "--mothership-host", "127.0.0.1", "--mothership-grpc-port", "47091",
            "--data-dir", "/tmp/rao/aii/thread/db", "--use-mlx", "--mlx-model", AIIModels.embedding.id,
        ])
        XCTAssertNil(spec.environment["THREAD_NODE_ID"])
        XCTAssertEqual(spec.environment["AII_HOME"], "/tmp/rao")
        XCTAssertEqual(spec.environment["HF_HOME"], "/tmp/rao/models/huggingface")
        XCTAssertEqual(spec.environment["THREAD_PQ_MLX"], "1")
        XCTAssertNil(spec.environment["MISTRAL_API_KEY"])
        XCTAssertEqual(PrivateFile.path(spec.runRecord), "/tmp/rao/aii/run/thread.json")
        XCTAssertEqual(PrivateFile.path(spec.workingDirectory), "/tmp/rao/aii")
        XCTAssertEqual(spec.challenge, .app(.craft))
        XCTAssertEqual(PrivateFile.path(spec.startLock), "/tmp/rao/aii/run/start.lock", "one lock for the stack")
    }

    func testTheThreadHonoursItsConfigAndOptions() {
        let config = AIIConfig(sewn: .init(grpcPort: 5), thread: .init(httpPort: 8081, grpcPort: 9090, dataDir: "/Volumes/T9/index", graphBackend: "keyword"))
        let spec = LaunchSpecs.thread(home: home, config: config, executable: URL(fileURLWithPath: "/checkout/AIIServer"),
                                      options: ThreadLaunchOptions(graphModel: "org/model", mothership: false),
                                      workingDirectory: URL(fileURLWithPath: "/checkout"), challengeApp: .ambient,
                                      inherited: ["HF_HOME": "/Users/x/Documents/huggingface"])
        XCTAssertFalse(spec.arguments.contains("--mothership-host"))
        XCTAssertEqual(spec.ports, AIIPorts(http: 8081, grpc: 9090))
        XCTAssertTrue(spec.arguments.contains("/Volumes/T9/index"))
        XCTAssertEqual(Array(spec.arguments.suffix(7)),
                       ["--graph-backend", "keyword", "--use-mlx", "--mlx-model", AIIModels.embedding.id, "--graph-model", "org/model"],
                       "the config's backend, then the options, in the order Thread's flags are documented")
        XCTAssertEqual(spec.environment["HF_HOME"], "/tmp/rao/models/huggingface", "never the shell's")
        XCTAssertEqual(PrivateFile.path(spec.workingDirectory), "/checkout")
    }
}

final class AIIPortPlanTests: XCTestCase {
    func testEveryPortIsDistinctAndClearOfTheOtherStacks() {
        let ports = [AIIPortPlan.sewn.http, AIIPortPlan.sewn.grpc, AIIPortPlan.thread.http, AIIPortPlan.thread.grpc]
        XCTAssertEqual(Set(ports).count, ports.count)
        XCTAssertTrue(Set(ports).isDisjoint(with: AIIPortPlan.reservedElsewhere))
        XCTAssertEqual(AIIPortPlan.thread, AIIPorts(http: 47081, grpc: 47090), "the one Thread listens where Ambient's did")
    }

    func testAppNames() {
        XCTAssertEqual(AIIApp(header: " Craft\n"), .craft)
        XCTAssertEqual(AIIApp(header: "mary"), "mary", "any app name: the set is open")
        XCTAssertNil(AIIApp(header: "aii"), "the stack's own name")
        XCTAssertNil(AIIApp(header: nil))
    }
}

final class EnvFileTests: XCTestCase {
    func testParsing() {
        let pairs = EnvFile.parse("""
        # comment
        SUPABASE_URL=https://x.supabase.co
        export SUPABASE_ANON_KEY="anon"
          QUOTED='single'
        NOEQUALS
        =novalue
        EMPTY=
        """)
        XCTAssertEqual(pairs.map(\.key), ["SUPABASE_URL", "SUPABASE_ANON_KEY", "QUOTED", "EMPTY"])
        XCTAssertEqual(pairs.map(\.value), ["https://x.supabase.co", "anon", "single", ""])
    }

    func testTheStacksFileTakesOnlyPublicValues() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        XCTAssertThrowsError(try AIIEnvironmentFile.write(["MISTRAL_API_KEY": "k"], to: test.home.aiiEnvFile))
        try AIIEnvironmentFile.write(["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"], to: test.home.aiiEnvFile)
        XCTAssertEqual(EnvFile.read(test.home.aiiEnvFile), ["SUPABASE_URL": "u", "SUPABASE_ANON_KEY": "a"])
        XCTAssertEqual(test.mode(test.home.aiiEnvFile), 0o600)
    }

    func testApplyingNeverOverridesTheEnvironmentOrADeniedKey() throws {
        let test = TestHome()
        try test.home.provision(by: .ambient)
        let file = test.home.aiiDirectory.appendingPathComponent("probe.env")
        let unique = "RAO_TEST_\(UUID().uuidString.prefix(8))"
        setenv("\(unique)_SET", "shell", 1)
        try PrivateFile.writeAtomically(Data("\(unique)_NEW=file\n\(unique)_SET=file\nMISTRAL_API_KEY=file\n".utf8), to: file)
        let applied = EnvFile.apply(file, denying: AIIEnvironmentFile.deniedKeys)
        XCTAssertFalse(applied.contains("MISTRAL_API_KEY"))
        XCTAssertEqual(ProcessInfo.processInfo.environment["\(unique)_NEW"], "file")
        XCTAssertEqual(ProcessInfo.processInfo.environment["\(unique)_SET"], "shell")
        unsetenv("\(unique)_NEW")
        unsetenv("\(unique)_SET")
    }
}

final class StackChallengeTests: XCTestCase {
    typealias KAT = StackSecretTests.KAT

    private func body(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testVerdicts() {
        func verdict(_ data: Data?, status: Int? = 200, secret: String = "s3cret", app: AIIApp? = nil) -> StackVerdict {
            StackChallenge.verdict(status: status, body: data, nonce: KAT.nonce, secret: secret, expectedApp: app)
        }
        XCTAssertEqual(verdict(nil, status: nil), .down)
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret]), status: 503), .down)
        XCTAssertEqual(verdict(body(["stack": "open"])), .open)
        XCTAssertEqual(verdict(body(["stack": "matched"])), .stale, "an answer that is not a proof is something else on the port")
        XCTAssertEqual(verdict(body(["status": "ok"])), .stale)
        XCTAssertEqual(verdict(body(["stack": "proof"])), .stale)
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret])), .stale, "a proof without a contract is not ours")
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret, "contract": 1])), .ours(contract: 1))
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret, "contract": 1]), secret: "other"), .stale)
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret, "app": "ambient", "contract": 7]), app: .ambient),
                       .ours(contract: 7), "the contract is reported as answered; the caller compares it")
        XCTAssertEqual(verdict(body(["stack": "proof", "proof": KAT.proofForS3cret, "app": "craft", "contract": 1]), app: .ambient),
                       .stale, "a proof for another app than the one asked is not ours")
        XCTAssertEqual(StackChallenge.verdict(status: 200, body: body(["stack": "proof", "proof": KAT.proofForS3cret, "app": "aii", "contract": 1]),
                                              nonce: KAT.nonce, secret: "s3cret", expected: .stack),
                       .ours(contract: 1), "the stack identity challenges as itself")
    }

    func testTheChallengeNamesTheIdentityAndNeverTheSecret() {
        let headers = StackChallenge.headers(nonce: KAT.nonce, app: .veil)
        XCTAssertEqual(headers, ["X-Ambient-Nonce": KAT.nonce, "X-AII-App": "veil"])
        XCTAssertEqual(StackChallenge.headers(nonce: KAT.nonce, app: nil), ["X-Ambient-Nonce": KAT.nonce])
        XCTAssertEqual(StackChallenge.headers(nonce: KAT.nonce, identity: .stack), ["X-Ambient-Nonce": KAT.nonce, "X-AII-App": "aii"])
    }
}
