//
//  DocumentListResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/13/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation


struct DocumentListResponse: Codable {
    var object: String = "list"
    let documents: [SewnCore.Document]
    let access: [DocumentID : SewnRegistry.Access]
}
