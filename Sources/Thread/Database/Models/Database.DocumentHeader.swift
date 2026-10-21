//
//  Database.DocumentHeader.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What a search hit carries back when the caller asks (`include_metadata`): the
//        document's name, the group its owner filed it under, and its metadata as
//        deposited — enough for a record-shaped client to decode the hit — and the
//        document's own url, which tells a partition's own address (a region of a
//        picture) from the document's.
//  PIN:  The group is the hit owner's own: its place in `ownerDocumentGroup`, else the
//        first of that owner's groups listing the document — never another owner's, the
//        rule removes and moves follow (ThreadRegistry.unfile). Metadata is returned byte
//        for byte.
//

import Foundation

extension Database {
    struct DocumentHeader: Sendable, Equatable {
        var name: String?
        var groupId: GroupID?
        var metadata: Data?
        /// Where the document itself lives; a partition whose url differs has its own.
        var documentURL: URL?
    }

    nonisolated func documentHeader(for documentId: DocumentID, owner ownerId: String,
                                    registry: ThreadRegistry?) -> DocumentHeader {
        let owner = ThreadRegistry.Owner(id: ownerId)
        let group = registry.flatMap { registry in
            registry.ownerDocumentGroup[ownerId]?[documentId]
                ?? (registry.documentGroups[documentId] ?? []).filter { registry.groupOwners[$0] == owner }.sorted().first
        }
        let document = document(for: documentId)
        return DocumentHeader(name: document?.name, groupId: group,
                              metadata: table?.index(for: documentId)?.metadata, documentURL: document?.url)
    }
}
