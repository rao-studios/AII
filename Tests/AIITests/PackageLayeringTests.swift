//
//  PackageLayeringTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Standing rules for the one package — what the manifest's PIN says, checked:
//        server packages behind the trait, AII on Seam and the wire only, no module cycle,
//        no type named like a module; and every Swift file opens with its name, its target,
//        its author's dated line and the copyright, every manifest with the same two lines
//        after its tools version. Generated and third-party files are listed as exempt.
//  OUT:  Package.swift as text, and the Swift files under Sources/, Tests/ and Examples/.
//  PIN:  One unguarded reference to a Server-only package would make every app resolve
//        Frigate; a type named like a module would break qualified lookup for everyone
//        who imports it. The compiler catches neither.
//

import Foundation
import XCTest

final class PackageLayeringTests: XCTestCase {

    /// Packages only the servers need. Every product reference to one of these must
    /// carry the Server trait, so a consumer with `traits: []` never resolves it.
    static let serverOnlyPackages = [
        "swift-argument-parser", "hummingbird", "hummingbird-websocket", "Web3.swift",
        "supabase-swift", "swift-prometheus", "Frigate",
    ]

    static let moduleNames = ["AII", "Seam", "Sewn", "Thread", "AIIServer", "AIICLI"]

    static let author = "Ritesh Pakala"
    static let copyright = "Copyright © 2026 Rao Studios LLC."

    /// Written by Scripts/generate-seam.sh, or carrying another author's copyright. Nothing else is exempt.
    static let headerExempt: Set<String> = [
        "Sources/Seam/Generated/fleet.pb.swift", "Sources/Seam/Generated/fleet.grpc.swift",
        "Sources/Seam/Generated/thread.pb.swift", "Sources/Seam/Generated/thread.grpc.swift",
        "Tests/AIITests/Generated/lanes.pb.swift", "Tests/AIITests/Generated/record.pb.swift",
        "Sources/Sewn/API/Network/Dictionary/DictionaryCodingKey.swift", "Sources/Sewn/API/Network/Dictionary/DictionaryDecoder.swift",
        "Sources/Sewn/API/Network/Dictionary/DictionaryEncoder.swift", "Sources/Sewn/API/Network/Dictionary/DictionaryErrors.swift",
        "Sources/Thread/API/Network/Dictionary/DictionaryCodingKey.swift", "Sources/Thread/API/Network/Dictionary/DictionaryDecoder.swift",
        "Sources/Thread/API/Network/Dictionary/DictionaryEncoder.swift", "Sources/Thread/API/Network/Dictionary/DictionaryErrors.swift",
        "Sources/Sewn/Sinatra/ML/SVM/DataSet.swift",
        "Sources/Sewn/Utilities/Persistence/FilePersistence.swift", "Sources/Sewn/Utilities/Persistence/Persistence.swift",
        "Sources/Thread/Utilities/Persistence/FilePersistence.swift", "Sources/Thread/Utilities/Persistence/Persistence.swift",
    ]

    static func swiftFiles(under relative: String) -> [URL] {
        let base = root.appendingPathComponent(relative, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/.build/") && !$0.path.contains("/.swiftpm/") }
            .sorted { $0.path < $1.path }
    }

    static func relative(_ url: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AIITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Throws rather than returning empty: most assertions below are "this text does
    /// not appear", and an empty read satisfies all of them.
    static func manifest() throws -> String {
        try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    }

    /// The manifest with `//` comments removed — its headers NAME the things the rules forbid.
    static func code(_ manifest: String) -> [String] {
        manifest.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let slashes = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<slashes.lowerBound])
        }
    }

    func testTheManifestNeedsAToolchainThatPrunesTraitGatedDependencies() throws {
        let first = try XCTUnwrap(try Self.manifest().split(separator: "\n").first)
        let version = first.replacingOccurrences(of: "// swift-tools-version:", with: "").trimmingCharacters(in: .whitespaces)
        let parts = version.split(separator: ".").compactMap { Int($0) }
        XCTAssertGreaterThanOrEqual(parts.count, 2, "\(first)")
        XCTAssertTrue(parts[0] > 6 || (parts[0] == 6 && parts[1] >= 2), "tools 6.2 or later: \(first)")
    }

    func testEveryServerOnlyProductIsBehindTheServerTrait() throws {
        let lines = Self.code(try Self.manifest())
        var seen: Set<String> = []
        for (number, line) in lines.enumerated() where line.contains(".product(name:") {
            for package in Self.serverOnlyPackages where line.contains("package: \"\(package)\"") {
                seen.insert(package)
                XCTAssertTrue(line.contains("traits: [\"Server\"]"),
                              "Package.swift:\(number + 1) references \(package) without the Server trait: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(seen, Set(Self.serverOnlyPackages), "every server-only package is referenced at least once")
    }

    /// A fresh clone resolves on its own: Frigate (SinatraHarness inside it) comes from GitHub, like the rest.
    func testNoPathDependencies() throws {
        let manifest = try Self.manifest()
        XCTAssertEqual(Self.code(manifest).filter { $0.contains(".package(path:") }, [])
        // `code` would cut a URL at its `//`; a commented-out line starts with `//`, so it can't match.
        let lines = manifest.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains { $0.hasPrefix(".package(url: \"https://github.com/rao-studios/Frigate.git\"") })
        XCTAssertFalse(Self.code(manifest).contains { $0.contains("package: \"SinatraHarness\"") },
                       "SinatraHarness is a Frigate product; a second package declaring that target cannot share the graph")
    }

    func testTheServerTraitIsOnByDefault() throws {
        let code = Self.code(try Self.manifest()).joined(separator: "\n")
        XCTAssertTrue(code.contains(".trait(") && code.contains("name: \"Server\""))
        XCTAssertTrue(code.contains(".default(enabledTraits: [\"Server\"])"))
    }

    /// The servers and the `aii` command; the four libraries apps and servers link.
    func testTwoExecutablesAndFourLibraries() throws {
        let code = Self.code(try Self.manifest()).joined(separator: "\n")
        XCTAssertEqual(code.components(separatedBy: ".executable(name:").count - 1, 2)
        XCTAssertEqual(code.components(separatedBy: ".executableTarget(").count - 1, 2)
        XCTAssertTrue(code.contains(".executable(name: \"AIIServer\", targets: [\"AIIServer\"])"))
        XCTAssertTrue(code.contains(".executable(name: \"aii\", targets: [\"AIICLI\"])"))
        for library in ["AII", "Seam", "Sewn", "Thread"] {
            XCTAssertTrue(code.contains(".library(name: \"\(library)\", targets: [\"\(library)\"])"), library)
        }
    }

    /// What an app links is the foundation and Join/: Seam and the wire every consumer
    /// resolves anyway, never a server package.
    func testTheAIITargetDependsOnlyOnSeamAndTheWire() throws {
        let code = Self.code(try Self.manifest()).joined(separator: "\n")
        let start = try XCTUnwrap(code.range(of: #"\.target\(\s*name: "AII","#, options: .regularExpression), "the AII target")
        let rest = code[start.upperBound...]
        let end = rest.range(of: ".target(")?.lowerBound ?? rest.endIndex
        let target = String(rest[..<end])
        let products = target.components(separatedBy: ".product(name: \"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        XCTAssertEqual(Set(products), ["Crypto", "GRPCCore", "GRPCNIOTransportHTTP2", "GRPCProtobuf", "SwiftProtobuf", "Logging"], target)
        XCTAssertTrue(target.contains("\"Seam\""), target)
        XCTAssertFalse(target.contains("traits:"), "nothing the AII target links is behind a trait")
    }

    /// AII depends on Seam, so Seam may never depend on AII.
    func testSeamDoesNotImportAII() throws {
        let seam = Self.root.appendingPathComponent("Sources/Seam", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: seam, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "import AII" },
                           url.lastPathComponent)
        }
    }

    /// A type that shares a module's name shadows it for every `Module.Type` lookup in
    /// a package that imports both; Foundation's `Thread` already does that to the Thread
    /// module, which is why nothing writes `Thread.X` — and why no type of ours may be
    /// named `Thread`, `Sewn`, `Seam`, `AII`, `AIIServer` or `AIICLI`.
    func testNoTypeIsNamedLikeAModule() throws {
        let sources = Self.root.appendingPathComponent("Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(
            pattern: #"\b(actor|class|struct|enum|protocol|typealias)\s+(\#(Self.moduleNames.joined(separator: "|")))\b"#)
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                let declaration = String(text[Range(match.range, in: text)!])
                offenders.append("\(url.path.replacingOccurrences(of: Self.root.path + "/", with: "")): \(declaration)")
            }
        }
        XCTAssertEqual(offenders, [], "a type named like a module")
    }

    func testEveryModuleHasItsTargetDirectory() {
        for module in Self.moduleNames {
            let directory = Self.root.appendingPathComponent("Sources/\(module)", isDirectory: true)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                          "Sources/\(module) is missing")
        }
    }

    func testEverySwiftFileOpensWithItsNameTargetAuthorAndCopyright() throws {
        let created = try NSRegularExpression(pattern: #"^//  Created by \#(Self.author) on \d\d/\d\d/\d\d\.$"#)
        var offenders: [String] = [], seen = 0
        for (root, base) in [("Sources", "Sources"), ("Tests", "Tests"), ("Examples/Notes/Sources", "Sources")] {
            for file in Self.swiftFiles(under: root) where !Self.headerExempt.contains(Self.relative(file)) {
                seen += 1
                let lines = try Self.lines(file)
                let target = file.deletingLastPathComponent().pathComponents.drop { $0 != base }.dropFirst().first ?? ""
                var opens = lines.count >= 7
                    && Array(lines[0..<4]) == ["//", "//  \(file.lastPathComponent)", "//  \(target)", "//"]
                    && Self.matches(created, lines[4])
                    && lines[5] == "//  \(Self.copyright)"
                if opens {   // provenance may follow the copyright; then the block closes
                    var i = 6
                    while i < lines.count, lines[i].hasPrefix("//  Based on: ") { i += 1 }
                    opens = i < lines.count && lines[i] == "//"
                }
                if !opens { offenders.append(Self.relative(file)) }
            }
        }
        XCTAssertGreaterThan(seen, 500, "the walk found the tree")
        XCTAssertEqual(offenders, [], "does not open with its name, target, author and copyright")
    }

    func testTheExemptFilesAreGeneratedOrCarryAnotherCopyright() throws {
        for path in Self.headerExempt.sorted() {
            let body = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)   // a stale entry throws
            XCTAssertTrue(body.hasPrefix("// DO NOT EDIT.") || body.range(of: "copyright", options: .caseInsensitive) != nil, path)
            XCTAssertFalse(body.contains(Self.copyright), "\(path) is ours now: take it off the list")
        }
    }

    func testTheManifestsNameTheirAuthorAndCopyrightAfterTheToolsVersion() throws {
        let created = try NSRegularExpression(pattern: #"^// Created by \#(Self.author) on \d\d/\d\d/\d\d\.$"#)
        for manifest in ["Package.swift", "Examples/Notes/Package.swift"] {
            let lines = try Self.lines(Self.root.appendingPathComponent(manifest))
            XCTAssertTrue(lines.count > 3 && lines[0].hasPrefix("// swift-tools-version:")
                          && Self.matches(created, lines[1]) && lines[2] == "// \(Self.copyright)", manifest)
        }
    }
}
