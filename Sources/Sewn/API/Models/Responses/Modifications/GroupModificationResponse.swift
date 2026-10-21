//
//  GroupModificationResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 02/28/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct GroupModificationResponse: Codable {
    let groupId: String
    let access: SewnRegistry.Access?
    let label: String?
    let user: SewnCore.User

    init(groupId: String,
         access: SewnRegistry.Access?,
         label: String? = nil,
         user: SewnCore.User) {
        self.groupId = groupId
        self.access = access
        self.label = label
        self.user = user
    }

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case access
        case label
        case user
    }
}
