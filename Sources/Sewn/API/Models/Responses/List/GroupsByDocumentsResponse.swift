//
//  GroupsByDocumentsResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupsByDocumentsResponse: Codable {
    var object: String = "list"
    /// Unique groups referenced by the requested documents.
    let groups: [SewnCore.Group]
    /// Maps each requested document ID to its group ID (omitted when ungrouped).
    let documentGroups: [DocumentID: GroupID]
    let access: [GroupID: SewnRegistry.Access]

    enum CodingKeys: String, CodingKey {
        case object
        case groups
        case documentGroups = "document_groups"
        case access
    }
}
