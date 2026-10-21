//
//  ModificationResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/08/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct ModificationResponse: Codable {
    var document: SewnCore.Document?
    var documentAccess: SewnRegistry.Access?
    var groupAccess: SewnRegistry.Access?
    var groupId: String?
    var user: SewnCore.User
    
    enum CodingKeys: String, CodingKey {
        case document
        case documentAccess = "document_access"
        case groupAccess = "group_access"
        case groupId = "group_id"
        case user
    }
}
