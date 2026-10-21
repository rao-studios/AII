//
//  ExtractionRoute.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a deposited document's graph entities come from, by what it is.
//  PIN:  One Thread extracts for every app, so the rule is by media type, not by
//        who launched it. Prose without entities goes to the LLM extractor
//        (keywords stand in until it answers). Code without entities gets its
//        identifiers, exactly, as `sym:` entities — never the LLM. Pictures get
//        nothing: there is no text to read. A caller that supplied entities has
//        said what the document is about; nothing is added.
//

import Foundation

enum ExtractionRoute: Equatable, Sendable {
    /// Keyword placeholders now, the LLM extractor's payload when it answers.
    case llm
    /// The identifiers in the text, as entities; no LLM.
    case identifiers
    /// No entities at all.
    case none

    static func decide(mediaType: MediaType, hasCallerEntities: Bool) -> ExtractionRoute {
        if hasCallerEntities { return .none }
        switch mediaType {
        case .text: return .llm
        case .code: return .identifiers
        case .image: return .none
        }
    }

    /// The provisional entities for a document on this route, and whether the LLM
    /// should replace them.
    func entities(for texts: [String], cap: Int) -> (entities: [Database.GraphPayload.EntityIn], needsExtraction: Bool) {
        switch self {
        case .llm:
            return (TagGenerator.generate(from: texts).map { .init(name: $0, kind: "concept") }, true)
        case .identifiers:
            return (CodeIdentifierExtractor.entities(from: texts, cap: cap), false)
        case .none:
            return ([], false)
        }
    }
}

/// Code's own entities: the identifiers its text names, exactly, under the `sym:`
/// namespace the code instrument matches (GraphStore+Identifiers).
enum CodeIdentifierExtractor {
    static let namespace = "sym:"

    static func entities(from texts: [String], cap: Int) -> [Database.GraphPayload.EntityIn] {
        let terms = GraphStore.identifierTerms(queryText: texts.joined(separator: "\n"), entities: [])
        var seen = Set<String>()
        var out: [Database.GraphPayload.EntityIn] = []
        for term in terms where seen.insert(term.lowercased()).inserted {
            out.append(.init(name: namespace + term, kind: "concept"))
            if out.count >= max(cap, 1) { break }
        }
        return out
    }
}
