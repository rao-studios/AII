//
//  SewnCore.GroupKind.swift
//  Sewn
//
//  Created by Ritesh Pakala on 04/14/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

extension SewnCore {
    /// The semantic category of the group a partition belongs to. Derived at
    /// runtime and never persisted.
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

        /// The group kind for a partition. Stubbed: it always answers `.document`, because
        /// `SewnRegistry` no longer maps partitions to groups (Thread owns groups), so
        /// compaction files every own-owner passage with the documents.
        static func resolve(for partition: Partition, registry: SewnRegistry?) -> GroupKind {
            return .document
        }
    }
}
