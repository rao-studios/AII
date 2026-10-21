//
//  main.swift
//  Notes
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The smallest app on the Ambient Intelligence Index. Two declarations make it one:
//        the lane (AIIAppDescriptor) and the schema of what it pushes into it
//        (AIIRecordable). Then every verb an app uses, in order.
//  IN:   A Mac where AII is installed (`aii install`, or any Rao app) — the servers are
//        adopted when running, started when not.
//  OUT:  Each step, one line: the lane registered, three notes filed, the closest ones
//        recalled as Notes, a question answered on this Mac and cited, the group forgotten.
//

import AII
import Foundation

/// The lane: Notes' name in the index. The first app to register a name on a Mac owns it.
enum Notes: AIIAppDescriptor {
    static let app: AIIApp = "notes"
    static let displayName = "Notes"
}

/// The schema of what Notes pushes into its lane. Its fields are its own; AII files each
/// value in an aii-record/1 envelope and hands it back as a Note.
struct Note: AIIRecordable {
    static let kind: AIIRecord.Kind = "note"
    static let group = AIIRecord.Group(id: "notes", label: "Notes")

    var recordID: String
    var title: String
    var body: String
    var tags: [String] = []

    /// What is embedded and searched.
    var text: String { body }
}

let notes = [
    Note(recordID: "standup-1015", title: "Stand-up, 15 October",
         body: "Ada leads Joltvault. The demo moved to Thursday at ten.", tags: ["standup"]),
    Note(recordID: "retro-1010", title: "Retro, 10 October",
         body: "Joltvault's index rebuild took eleven minutes; Ada wants it under one.", tags: ["retro"]),
    Note(recordID: "idea-0930", title: "Idea, 30 September",
         body: "A lane per app keeps each app's notes apart in one index on the Mac."),
]

let aii = AIIInstance(Notes.self)   // AIIInstance(Notes.self, owner: .local) files under aii-local, beside the Rao apps
do {
    try await aii.join()
    print("join      the \"notes\" lane is registered; Sewn and Thread proved its secret")

    let filed = try await aii.remember(notes)
    print("remember  \(filed) notes filed under \(aii.owner) in notes-notes")

    for match in try await aii.recall("Who leads Joltvault?", as: Note.self, topK: 2) {
        print("recall    \(match.value.title) · distance \(String(format: "%.3f", match.hit.distance))")
    }

    do {
        var cited: [String] = []
        var answer = ""
        for try await event in aii.ask("Who leads Joltvault, and when is the demo?") {
            switch event {
            case .references(let references): cited = references.map(\.id)
            case .token(let text): answer += text
            case .contribution, .finished: break
            }
        }
        print("ask       \(answer.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("          may cite \(cited.joined(separator: ", "))")
    } catch {
        print("ask       not answered: \(error)")
        print("          the on-device model may be missing: aii models pull generalStandard")
    }

    let forgotten = try await aii.forget(groups: ["notes"])
    print("forget    \(forgotten.documentCount) documents in \(forgotten.groups.joined(separator: ", ")); the lane stays (aii lanes)")
    await aii.leave()
} catch {
    await aii.leave()
    print("notes: \(error)")
    print("  is AII installed? aii status, then aii install")
    exit(1)
}
