//
//  Flow4_ExtractionTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Keyword fallback + the pure LLM-output parser (no MLX required).
//

import XCTest
import Logging
@testable import Thread

final class Flow4_ExtractionTests: XCTestCase {

    func test_keywordFallback_producesConceptEntities_noRelationships() async throws {
        let provider = KeywordGraphExtractionProvider()
        let payload = try await provider.extract(
            from: ["radioactivity research radium polonium radioactivity research radium"],
            logger: .test
        )
        XCTAssertFalse(payload.entities.isEmpty)
        XCTAssertTrue(payload.entities.allSatisfy { $0.kind == "concept" })
        XCTAssertTrue(payload.relationships.isEmpty)
    }

    func test_parser_acceptsBareJSON() throws {
        let json = """
        {"entities":[{"name":"Marie Curie","kind":"person"},{"name":"Radium","kind":"concept"}],\
        "relationships":[{"subject":"Marie Curie","predicate":"discovered","object":"Radium"}]}
        """
        let payload = try GraphExtractionParser.parse(json)
        XCTAssertEqual(payload.entities.count, 2)
        XCTAssertEqual(payload.relationships.count, 1)
        XCTAssertEqual(payload.relationships.first?.predicate, "discovered")
    }

    func test_parser_acceptsProseAndFencedJSON() throws {
        let fenced = """
        Sure, here is the graph:
        ```json
        {"entities":[{"name":"Alpha","kind":"concept"}],"relationships":[]}
        ```
        Hope that helps!
        """
        let payload = try GraphExtractionParser.parse(fenced)
        XCTAssertEqual(payload.entities.count, 1)
        XCTAssertEqual(payload.entities.first?.name, "Alpha")
    }

    func test_parser_dropsRelationshipsReferencingUnknownEntities() throws {
        let json = """
        {"entities":[{"name":"A","kind":"concept"}],\
        "relationships":[{"subject":"A","predicate":"rel","object":"Ghost"}]}
        """
        let payload = try GraphExtractionParser.parse(json)
        XCTAssertEqual(payload.entities.count, 1)
        XCTAssertTrue(payload.relationships.isEmpty, "object 'Ghost' not among entities")
    }

    func test_parser_defaultsMissingKindToConcept_dropsEmptyNames() throws {
        let json = """
        {"entities":[{"name":"NoKind"},{"name":"  "}],"relationships":[]}
        """
        let payload = try GraphExtractionParser.parse(json)
        XCTAssertEqual(payload.entities.count, 1)
        XCTAssertEqual(payload.entities.first?.kind, "concept")
    }

    /// PIN: a small model's looser shape still parses: an entity as a bare name, a relationship as a three-part array;
    /// a relationship of four parts is skipped, not the answer (Granite 4.0 H-Micro, 2026-11-07).
    func test_parser_readsBareNamesAndArrayTriples_skipsOtherShapes() throws {
        let json = #"{"entities":["Ambient","Craft",{"name":"coding app","kind":"concept"}],"relationships":[["Craft","is","coding app"],["Ambient","links","people","places"],{"subject":"Craft","predicate":"files into","object":"Ambient"}]}"#
        let payload = try GraphExtractionParser.parse(json)
        XCTAssertEqual(payload.entities.map(\.name), ["Ambient", "Craft", "coding app"])
        XCTAssertEqual(payload.relationships.map(\.predicate), ["is", "files into"])
    }

    func test_parser_throwsOnMalformedInput() {
        XCTAssertThrowsError(try GraphExtractionParser.parse("there is no json object here"))
    }
}
