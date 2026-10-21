//
//  SewnCore+Get.swift
//  Sewn
//
//  Created by Ritesh Pakala on 11/01/25.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation
import Logging

extension SewnCore {
    /// Returns a `SewnCore.Document` for a filename.
    /// - Parameter key: The filename.
    /// - Returns: SewnCore.Document object.
    func get(_ key: String) -> SewnCore.Document? {
        let storage = FilePersistence(key: key,
                                      kind: .basic,
                                      logger: logger.base)
        return storage.restore()
    }
}
