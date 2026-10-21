//
//  ModificationRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/08/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct ModificationRequest: Codable {
    let documentAccess: SewnRegistry.Access?
    let groupAccess: SewnRegistry.Access?
    let update: SewnUpdate
    let sewn: SewnRequest
    
    enum CodingKeys: String, CodingKey {
        case documentAccess = "document_access"
        case groupAccess = "group_access"
        case update
        case sewn
    }
}
