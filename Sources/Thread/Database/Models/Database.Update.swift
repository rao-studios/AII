//
//  Database.Update.swift
//  Thread
//
//  Created by Ritesh Pakala on 12/15/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

// TODO: What differentiates this from ModifyRequest?
/// A payload to manage metadata for updations. A necessary data object
/// when updating documents or other data types. Maintaining data consistency
/// with the clients.
struct DatabaseUpdate: Codable {
    // A documentId to update.
    let documentId: String
    // Update operation.
    let operation: Operation
    
    enum CodingKeys: String, CodingKey {
        case documentId = "document_id"
        case operation
    }
}

extension DatabaseUpdate {
    enum Operation: String, Codable {
        case remove
        case access
        case group
    }
}
