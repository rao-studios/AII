//
//  CodeRelationEnrichment.swift
//  Thread
//
//  WHAT: Code relations — the index-time twin of a search's media_type "code". A code document
//        filed with `relate_code` is read once more, after it is filed, by the node's extractor:
//        what is each of its types for? The answer joins the graph its filer gave it, as
//        `<type> serves <goal>` and `<project> pursues <goal>`.
//  IN:   A filed code item (its cards and the entities its filer named), the extractor, the graph.
//  OUT:  The item's graph with the goals added, or nil when there was nothing to add.
//  PIN:  MEANING FROM THE MODEL, FACTS FROM THE FILER. What a file imports, declares and conforms
//        to is the filer's, read off its parser; what a type is *for* is a reading. A goal is a
//        short phrase another project solving the same problem would also write, and the goals
//        the graph already holds that sit nearest are offered first, so a goal is written once and
//        every type in any project that serves it connects to it: two ways to the same end.
//  PIN:  NEVER ON THE FILING'S PATH. The document is put first and is searchable at once; this
//        reading lands after it, queued behind the put (Database.relateCode).
//

import Foundation
import Logging

enum CodeRelationEnrichment {
    /// The kind a goal is filed as, and what links a type and a project to one.
    static let goalKind = "goal"
    static let serves = "serves"
    static let pursues = "pursues"
    /// What a filer says a file's module or file declares by: the types read are those it names (`types(in:)`).
    static let declares = "declares"
    /// The entity kinds a filer names a type by: what a goal is read for.
    static let typeKinds: Set<String> = ["struct", "class", "actor", "enum", "protocol", "interface", "trait", "type"]
    static let maxTypes = 12
    static let offeredGoals = 24
    static let maxTokens = 400
    static let inputChars = 3_000

    static let instructions = """
        You read the code of one source file and say, for each type it declares, the end goal that type serves in its \
        program: what it is for, not what it is made of. Write each goal as a short phrase of two to six words that \
        another project solving the same problem would also write, such as "persist settings between launches", \
        "stream a model's reply to the screen" or "retry a failed network request". When one of the goals already known \
        says the same thing, write it exactly as it is listed. Leave out a type that only serves its own file.
        Respond with ONLY a JSON object — no prose, no code fences: {"goals":[{"type":"<a type listed>","goal":"..."}]}
        """

    /// Reads one filed code item and returns its graph with the goals its types serve added; nil when it names no type,
    /// the extractor has no model, or the answer held nothing usable.
    static func relate(_ item: Database.BatchPutItem, extractor: any GraphExtracting, existingGraph: GraphStore?,
                       logger: Logger) async -> Database.GraphPayload? {
        let types = self.types(in: item.graph)
        guard !types.isEmpty else { return nil }
        let text = item.texts.joined(separator: "\n\n")
        let offered = goals(in: existingGraph, near: text, limit: offeredGoals)
        let input = self.input(types: types.map(\.display), goals: offered, cards: String(text.prefix(inputChars)))
        do {
            guard let answer = try await extractor.respond(instructions: instructions, input: input, maxTokens: maxTokens, logger: logger) else {
                return nil
            }
            let added = parse(answer, types: types, projects: item.graph.entities.filter { $0.kind == "project" }.map(\.name))
            guard !added.relationships.isEmpty else { return nil }
            return merged(item.graph, adding: added)
        } catch {
            logger.warning("Code relations failed for doc \(item.id): \(error) — filed without them")
            return nil
        }
    }

    /// The types the file declares, as the model is shown them (no namespace) and as the graph knows them.
    ///
    /// PIN: THE FILE'S OWN TYPES. A filer that says what the file declares (`<module> declares <type>`) is taken at its
    /// word: a type the file only uses — a standard library's String, a framework's base class — is never read, or every
    /// project in a language would pursue "represent textual data" and the goals would link everything. A filer that
    /// sends no `declares` has every type it named read.
    static func types(in graph: Database.GraphPayload) -> [(display: String, entity: String)] {
        let declared = Set(graph.relationships.filter { $0.predicate.lowercased() == declares }.map(\.object))
        var seen = Set<String>()
        return graph.entities.filter {
            typeKinds.contains($0.kind.lowercased()) && (declared.isEmpty || declared.contains($0.name))
        }.compactMap { entity in
            let display = entity.name.split(separator: ":", maxSplits: 1).last.map(String.init) ?? entity.name
            return seen.insert(display).inserted ? (display, entity.name) : nil
        }.prefix(maxTypes).map { $0 }
    }

    /// The goals the graph holds that share the most words with the file, then the most mentioned; at most `limit`.
    static func goals(in graph: GraphStore?, near text: String, limit: Int) -> [String] {
        guard let graph else { return [] }
        let words = Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
        let known = graph.entities.values.filter { $0.kind == goalKind }
        func shared(_ name: String) -> Int { Set(name.split(separator: " ").map(String.init)).intersection(words).count }
        return known.sorted { (shared($0.name), $0.mentionCount, $1.name) > (shared($1.name), $1.mentionCount, $0.name) }
            .prefix(limit).map(\.name)
    }

    static func input(types: [String], goals: [String], cards: String) -> String {
        var parts = ["Types: " + types.joined(separator: ", ")]
        if !goals.isEmpty { parts.append("Goals already known:\n" + goals.map { "- " + $0 }.joined(separator: "\n")) }
        parts.append("The file's code:\n" + cards)
        return parts.joined(separator: "\n\n")
    }

    /// A goal as it is filed: lowercase words, single-spaced, no closing punctuation; nil for none or more than eight words.
    static func goal(_ phrase: String) -> String? {
        let words = phrase.lowercased().split { $0.isWhitespace }.map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 8 else { return nil }
        return words.joined(separator: " ")
    }

    /// The answer as entities and relationships: a goal for a type the filer named, each once, and every project the item
    /// named pursuing each goal once. Anything else is left out.
    static func parse(_ answer: String, types: [(display: String, entity: String)], projects: [String]) -> Database.GraphPayload {
        guard let first = answer.firstIndex(of: "{"), let last = answer.lastIndex(of: "}"), first < last,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[first...last].utf8)) as? [String: Any],
              let goals = object["goals"] as? [[String: Any]] else { return Database.GraphPayload() }
        let byName = Dictionary(types.map { ($0.display, $0.entity) }, uniquingKeysWith: { a, _ in a })
        var entities: [Database.GraphPayload.EntityIn] = []
        var relationships: [Database.GraphPayload.RelationIn] = []
        var seen = Set<String>()
        func relate(_ subject: String, _ predicate: String, _ object: String) {
            guard seen.insert(subject + "|" + predicate + "|" + object).inserted else { return }
            relationships.append(.init(subject: subject, predicate: predicate, object: object))
        }
        for item in goals {
            guard let name = (item["type"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "` ")),
                  let type = byName[name] ?? byName[name.split(separator: ".").last.map(String.init) ?? name],
                  let phrase = item["goal"] as? String, let goal = goal(phrase) else { continue }
            if !entities.contains(where: { $0.name == goal }) { entities.append(.init(name: goal, kind: goalKind)) }
            relate(type, serves, goal)
            for project in projects { relate(project, pursues, goal) }
        }
        return Database.GraphPayload(entities: entities, relationships: relationships)
    }

    /// The filer's graph with the reading added: its entities and relationships first, as it gave them.
    static func merged(_ graph: Database.GraphPayload, adding added: Database.GraphPayload) -> Database.GraphPayload {
        var out = graph
        for entity in added.entities where !out.entities.contains(where: { $0.name == entity.name && $0.kind == entity.kind }) {
            out.entities.append(entity)
        }
        out.relationships += added.relationships
        return out
    }
}
