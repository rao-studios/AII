//
//  GroupRemoveResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupRemoveResponse: Codable {
    /// The group that was removed. `nil` if the caller does not own the group.
    let groupId: String?
    /// IDs of every document that was removed with the group.
    let documentIds: [String]
    let user: SewnCore.User

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case documentIds = "document_ids"
        case user
    }
}
