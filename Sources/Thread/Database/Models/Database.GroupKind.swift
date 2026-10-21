//
//  Database.GroupKind.swift
//  Thread
//
//  Created by Ritesh Pakala on 04/14/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

extension Database {
    /// The semantic category of the group a partition belongs to.
    /// Derived at runtime from registry data, never stored.
    enum GroupKind: String, Codable {
        case memory
        case resonance
        case document

        var billable: Bool {
            self != .resonance
        }
        
        /// Display label used in prompts and briefings.
        var label: String {
            switch self {
            case .memory:    return "Memory"
            case .resonance: return "Resonance"
            case .document:  return "Document"
            }
        }

        /// Resolves the group kind for a partition by inspecting the registry.
        /// Uses the deterministic group ID patterns:
        ///   - `"memory-<ownerId>"`    → `.memory`
        ///   - `"resonance-<ownerId>"` → `.resonance`
        ///   - anything else           → `.document`
        ///
        /// Falls back to `.document` when the registry or mapping is unavailable.
        static func resolve(for partition: Partition, registry: ThreadRegistry?) -> GroupKind {
            let ownerId = partition.ownerId
            guard let groupId = registry?.ownerDocumentGroup[ownerId]?[partition.documentId] else { return .document }
            if groupId == "memory-\(ownerId)"    { return .memory }
            if groupId == "resonance-\(ownerId)" { return .resonance }
            return .document
        }
    }
}
