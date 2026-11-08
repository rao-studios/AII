//
//  Flow31_CodeRelationTests.swift
//  ThreadTests
//
//  Code relations: a code item filed with `relate_code` is read once more after it is filed,
//  for the end goal each type serves, and the reading joins the graph its filer gave it.
//

import XCTest
import Logging
@testable import Thread

final class Flow31_CodeRelationTests: XCTestCase {
    /// Answers every reading with one canned reply, and keeps what it was asked.
    private actor Reader: GraphExtracting {
        let reply: String?
        private(set) var asked: [String] = []
        init(_ reply: String?) { self.reply = reply }
        func extract(from texts: [String], logger: Logger) async throws -> Database.GraphPayload { .init() }
        func respond(instructions: String, input: String, maxTokens: Int, logger: Logger) async throws -> String? {
            asked.append(input)
            return reply
        }
    }

    private func item(entities: [Database.GraphPayload.EntityIn], relationships: [Database.GraphPayload.RelationIn] = []) -> Database.BatchPutItem {
        Database.BatchPutItem(id: "craft/code/abc.0123.4567", data: [], texts: ["// craft:type Store\nstruct Store { func save() {} }"],
                              graph: .init(entities: entities, relationships: relationships), mediaType: .code)
    }

    private let filed: [Database.GraphPayload.EntityIn] = [
        .init(name: "file:Sources/Store.swift", kind: "file"), .init(name: "project:abc", kind: "project"),
        .init(name: "module:App", kind: "module"), .init(name: "sym:Store", kind: "struct"),
        .init(name: "sym:Store.save", kind: "function"), .init(name: "sym:Cache", kind: "class"),
    ]

    /// PIN: the reading joins the filer's graph — its entities and relationships first, as given — as `<type> serves
    /// <goal>` and `<project> pursues <goal>`; a goal is filed lowercase, single-spaced, with no closing punctuation, and
    /// only for a type the filer named.
    func test_aReadingAddsWhatEachTypeIsFor_toTheGraphTheFilerGave() async throws {
        let reader = Reader(#"Here: {"goals":[{"type":"Store","goal":"Persist settings  between launches."},{"type":"Ghost","goal":"haunt"},{"type":"Cache","goal":"keep reads fast"}]}"#)
        let given = item(entities: filed, relationships: [.init(subject: "project:abc", predicate: "declares", object: "module:App")])
        let reading = await CodeRelationEnrichment.relate(given, extractor: reader, existingGraph: nil, logger: .test)
        let related = try XCTUnwrap(reading)
        XCTAssertEqual(Array(related.entities.prefix(filed.count)).map(\.name), filed.map(\.name), "the filer's entities first")
        XCTAssertEqual(related.relationships.first?.predicate, "declares", "the filer's relationships kept")
        XCTAssertEqual(Set(related.entities.filter { $0.kind == "goal" }.map(\.name)), ["persist settings between launches", "keep reads fast"])
        let triples = Set(related.relationships.map { "\($0.subject) \($0.predicate) \($0.object)" })
        XCTAssertTrue(triples.isSuperset(of: ["sym:Store serves persist settings between launches", "sym:Cache serves keep reads fast",
                                              "project:abc pursues persist settings between launches", "project:abc pursues keep reads fast"]), "\(triples)")
        XCTAssertFalse(triples.contains { $0.contains("haunt") }, "a type the filer did not name gets nothing")
        let asked = await reader.asked
        XCTAssertTrue(asked.first?.hasPrefix("Types: Store, Cache") == true, "the types, without their namespace: \(asked)")
    }

    /// Nothing to read, no model to ask, or an answer with nothing usable: the item stays as it was filed.
    func test_nothingIsAdded_whenThereIsNoTypeNoModelOrNoUsableAnswer() async {
        let noTypes = item(entities: [.init(name: "file:README.md", kind: "file")])
        let none1 = await CodeRelationEnrichment.relate(noTypes, extractor: Reader(#"{"goals":[]}"#), existingGraph: nil, logger: .test)
        XCTAssertNil(none1)
        let none2 = await CodeRelationEnrichment.relate(item(entities: filed), extractor: Reader(nil), existingGraph: nil, logger: .test)
        XCTAssertNil(none2, "an extractor with no model answers nothing")
        let none3 = await CodeRelationEnrichment.relate(item(entities: filed), extractor: Reader("I could not tell."), existingGraph: nil, logger: .test)
        XCTAssertNil(none3)
        let keywords = await CodeRelationEnrichment.relate(item(entities: filed), extractor: KeywordGraphExtractionProvider(), existingGraph: nil, logger: .test)
        XCTAssertNil(keywords, "the keyword fallback has no model to read with")
    }

    /// The goals the graph holds are offered nearest first — the most words shared with the file — so a goal is written
    /// once and every type that serves it, in any project, connects to it.
    func test_theGoalsKnownAreOfferedNearestFirst() {
        var graph = GraphStore()
        _ = graph.upsert(.init(entities: [.init(name: "persist settings between launches", kind: "goal"),
                                          .init(name: "render a chart", kind: "goal"),
                                          .init(name: "Ada", kind: "person")]), documentId: "d1")
        let offered = CodeRelationEnrichment.goals(in: graph, near: "struct SettingsStore { func persist() }", limit: 5)
        XCTAssertEqual(offered.first, "persist settings between launches")
        XCTAssertFalse(offered.contains("ada"), "only goals")
        XCTAssertEqual(CodeRelationEnrichment.goals(in: graph, near: "x", limit: 1).count, 1)
    }

    func test_aGoalIsFiledAsLowercaseWordsAndNoLongerThanEight() {
        XCTAssertEqual(CodeRelationEnrichment.goal("  Retry a failed  Network request!"), "retry a failed network request")
        XCTAssertNil(CodeRelationEnrichment.goal("   "))
        XCTAssertNil(CodeRelationEnrichment.goal("one two three four five six seven eight nine"))
    }
}
