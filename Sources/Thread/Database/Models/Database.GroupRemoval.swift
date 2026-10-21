//
//  Database.GroupRemoval.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  What a RemoveGroups did: the groups that are gone, the documents unlinked from
//  their owner, and those of them no owner holds any more — purged by the caller.
//

extension Database {
    struct GroupRemoval: Sendable, Equatable {
        var groups: [GroupID] = []
        var unlinked: [DocumentID] = []
        var fullyRemoved: [DocumentID] = []
    }
}
