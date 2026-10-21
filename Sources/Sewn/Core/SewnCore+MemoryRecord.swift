//
//  SewnCore+MemoryRecord.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The aii-record/1 envelope Sewn files what it writes back from a conversation
//        in: a summary, the recap ledger, a resonant passage — each kind `memory`.
//  IN:   The auto-memory, recap and resonance writers (chat, streamed chat, realtime).
//  OUT:  The envelope's canonical JSON, as the document's metadata in Thread.
//  PIN:  The same schema every app's records use, so an app's recall decodes Sewn's
//        documents through the one path (AIIRecord.decode). For an app's caller a
//        write-back is the document `<app>/memory/<id>` in the wire group
//        `<app>-memory-<owner>` or `<app>-resonance-<owner>`: the envelope's group is
//        `memory-<owner>` or `resonance-<owner>`, so the envelope names both, and its
//        source says which writer. The text is the document's partition, not the
//        envelope's. A caller that is no app (an open, hosted Sewn) has no lane: no
//        envelope, and the groups stay `memory-<owner>` and `resonance-<owner>`.
//

import AII
import Foundation

extension SewnCore {
    enum MemoryWriter: String {
        case summary = "sewn-summary"
        case recap = "sewn-recap"
        case resonance = "sewn-resonance"

        var title: String {
            switch self {
            case .summary: return "Conversation memory"
            case .recap: return "Chat recap"
            case .resonance: return "Resonant passage"
            }
        }

        var group: String { self == .resonance ? "resonance" : "memory" }
    }

    /// The envelope for a write-back of `app`'s, or nil when the caller is no app. `id` is
    /// the record's own id; the document is filed as `memoryDocumentId(id, app:)`.
    static func memoryMetadata(_ writer: MemoryWriter, id: String, groupLabel: String,
                               tags: [String], ownerId: String, app: AIIApp?) -> Data? {
        guard let app else { return nil }
        let record = AIIRecord(app: app, id: id, kind: .memory, title: writer.title,
                               group: AIIRecord.Group(id: "\(writer.group)-\(ownerId)", label: groupLabel),
                               source: AIIRecord.Source(kind: writer.rawValue), tags: tags)
        return try? record.canonicalJSON()
    }

    /// The group a write-back of `kind` (`memory`, `resonance`) is filed in. For an app's
    /// caller it is the app's own, `<app>-memory-<owner>`: Thread binds a group id to the
    /// first lane that files into it, so two apps sharing an owner (aii-local, or one
    /// account) need two groups. A caller that is no app keeps `memory-<owner>`.
    static func memoryGroupId(_ kind: String, ownerId: String, app: AIIApp?) -> String {
        guard let app else { return "\(kind)-\(ownerId)" }
        return AIIRecord.groupID(app: app, group: "\(kind)-\(ownerId)")
    }

    /// A write-back's document id: `<app>/memory/<id>` for an app's caller, so the
    /// envelope's documentID is the real one; the bare id for a caller that is no app.
    static func memoryDocumentId(_ id: String, app: AIIApp?) -> String {
        guard let app, AIIRecord.isValidID(id) else { return id }
        return AIIRecord.documentID(app: app, kind: .memory, id: id)
    }
}
