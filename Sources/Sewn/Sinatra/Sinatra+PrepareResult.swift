//
//  Sinatra+PrepareResult.swift
//  Sewn
//
//  Created by Ritesh Pakala on 04/12/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Foundation

extension Sinatra {
    /// The result returned by `Sinatra.prepare`.
    ///
    /// Bundles the token ledger for billing with any document-performance
    /// updates that should be written back to `SewnRegistry.documentStats`.
    /// The caller (`SewnCore.handleChat`) persists the updates via
    /// `RegistryMutator.accumulatePerformance` after the primary generation
    /// completes — keeping Sinatra free of direct registry dependencies.
    struct PrepareResult {
        /// Token usage from Sinatra's internal LLM call.
        /// Empty on all early-exit paths (no LLM was invoked).
        let ledger: Gita.TokenLedger

        /// Per-document performance updates accumulated during this `prepare` cycle.
        /// Keyed by `DocumentID` — the same key used in `SewnRegistry.documentStats`.
        /// Empty when no interactions were recorded (e.g. early exits or no parked data).
        let documentStatsUpdates: [DocumentID: SewnCore.DocumentStats]

        /// The resonance partition extracted from this prepare cycle, when a clear
        /// resonance signal was detected. Non-nil only when the user demonstrably
        /// engaged with a specific passage of the previous assistant response.
        ///
        /// The caller is responsible for storing this in the user's "Resonance" group
        /// via `BatchPutItem` + `indexQueue.enqueuePut`. A non-nil value also means
        /// the GBT+IMBHS training gate was passed for this cycle.
        let resonancePartition: Sinatra.ResonancePartition?

        static var empty: PrepareResult {
            PrepareResult(ledger: Gita.TokenLedger(), documentStatsUpdates: [:], resonancePartition: nil)
        }
    }
}
