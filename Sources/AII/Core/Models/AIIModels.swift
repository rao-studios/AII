//
//  AIIModels.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The master list of the base models the Rao ecosystem runs on device —
//        the one place a base model's id and commit are spelled. Voyage for
//        embeddings, Mistral for general language, Qwen Coder for code.
//  IN:   Sewn (its chat default, its vision slot, what it never removes, the
//        catalog row of /v1/providers), Thread (its embedder and its graph
//        extractor), Ambient (the on-device catalogue), Craft (its presets and
//        slots), Veil (its tile embedder).
//  OUT:  Pinned ids. A revision is a 40-hex commit; nil only while a mirror is
//        still to be published (then the model cannot be installed by a preset).
//  PIN:  Literals, reviewed in a diff, never fetched. Two byte counts because
//        the apps measure differently: `downloadBytes` is the Hub tree a first
//        fetch brings down, `weightsBytes` the safetensors alone (what a memory
//        budget wants). `kept` is what Thread itself runs, which no app may
//        remove through Sewn; everything else a person may remove and fetch again.
//        Frigate's `FrigateEmbedder.Profile.voyage4Nano` pins the same embedder
//        commit on the MLX side; the servers' tests hold the two in agreement.
//

import Foundation

public enum AIIModels {

    public enum Vendor: String, Codable, Sendable {
        case voyage, mistral, qwen
    }

    /// What a model is for. A closed set: the roles the stack has, not a list
    /// of models.
    public enum Role: String, CaseIterable, Codable, Sendable {
        /// The one vector space of the index (every Thread lane, Craft, Veil).
        case embedding
        /// The smallest general chat model Ambient offers on device.
        case generalSmall
        /// The standard general model: Sewn's on-device chat, Thread's graph
        /// extraction, Craft's worker. Never removed.
        case generalStandard
        /// The largest general model Ambient offers on device; Craft's fallback primary.
        case generalLarge
        /// Sewn's on-device vision slot (pictures for Veil and Ambient).
        case vision
        /// Craft's primary coding model.
        case coding
    }

    public struct Entry: Sendable, Hashable, Codable, Identifiable {
        /// The Hugging Face repo, `org/name`.
        public let id: String
        /// The commit a fetch pins; nil only while the mirror is unpublished.
        public let revision: String?
        public let vendor: Vendor
        public let role: Role
        /// `config.json`'s `model_type`.
        public let family: String
        /// A product name: never translated.
        public let displayName: String
        public let releasedYear: Int
        public let releasedMonth: Int
        /// The Hub tree a first download fetches: weights, configs, tokenizer, template.
        public let downloadBytes: Int64
        /// The safetensors alone.
        public let weightsBytes: Int64
        /// Below this much memory the Mac cannot hold the model beside the rest of
        /// the stack and still be usable.
        public let minimumMemoryGB: Int

        public init(id: String, revision: String?, vendor: Vendor, role: Role, family: String, displayName: String,
                    releasedYear: Int, releasedMonth: Int, downloadBytes: Int64, weightsBytes: Int64, minimumMemoryGB: Int) {
            self.id = id
            self.revision = revision
            self.vendor = vendor
            self.role = role
            self.family = family
            self.displayName = displayName
            self.releasedYear = releasedYear
            self.releasedMonth = releasedMonth
            self.downloadBytes = downloadBytes
            self.weightsBytes = weightsBytes
            self.minimumMemoryGB = minimumMemoryGB
        }

        /// `org/name@revision`, or the bare id while unpinned.
        public var pinnedSpec: String { revision.map { "\(id)@\($0)" } ?? id }

        /// Whether a preset may install it: a pinned commit exists.
        public var isInstallable: Bool { revision != nil }

        /// The first of the release month, for a locale's "December 2025".
        public var released: Date {
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: releasedYear, month: releasedMonth, day: 1)) ?? .distantPast
        }

        /// Whether a Mac with `physicalMemory` bytes can run this on device.
        public func fits(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
            physicalMemory >= UInt64(minimumMemoryGB) << 30
        }
    }

    // MARK: - The list (pins verified against the Hub and the installed snapshots, 2026-10-14)

    /// voyage-4-nano, Rao's 8-bit MLX conversion, cut to 1024 dimensions: the index's one
    /// vector space, `voyage-4@1024`, shared with Voyage's hosted voyage-4 models.
    public static let embedding = Entry(
        id: "rao-studios/voyage-4-nano-mlx-8bit",
        revision: "5b5f4aff4bd03236bb957dc3b9400fa0eedc8f4c",
        vendor: .voyage, role: .embedding, family: "qwen3",
        displayName: "Voyage 4 nano",
        releasedYear: 2026, releasedMonth: 9,
        downloadBytes: 381_637_676, weightsBytes: 370_132_090, minimumMemoryGB: 8)

    public static let generalSmall = Entry(
        id: "mlx-community/Ministral-3-8B-Instruct-2512-4bit",
        revision: "182f003f01daa75f9de0f2c4d379722fd0bc1c61",
        vendor: .mistral, role: .generalSmall, family: "mistral3",
        displayName: "Ministral 3 8B",
        releasedYear: 2025, releasedMonth: 12,
        downloadBytes: 5_630_654_690, weightsBytes: 5_596_684_559, minimumMemoryGB: 24)

    public static let generalStandard = Entry(
        id: "mlx-community/Mistral-Nemo-Instruct-2407-4bit",
        revision: "647ca0751669b21a364c86ccc5df54c4d7e4e91c",
        vendor: .mistral, role: .generalStandard, family: "mistral",
        displayName: "Mistral Nemo 12B",
        releasedYear: 2024, releasedMonth: 7,
        downloadBytes: 6_905_203_123, weightsBytes: 6_890_078_933, minimumMemoryGB: 24)

    public static let generalLarge = Entry(
        id: "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit",
        revision: "2a1d5eabfc504747bdc24178394821a1efc0edde",
        vendor: .mistral, role: .generalLarge, family: "mistral3",
        displayName: "Mistral Small 3.2 24B",
        releasedYear: 2025, releasedMonth: 6,
        downloadBytes: 13_277_587_940, weightsBytes: 13_260_192_731, minimumMemoryGB: 48)

    /// Rao's 8-bit MLX conversion of Ministral 3 8B Instruct, vision tower and all
    /// (Veil's scripts/vision), served by Sewn's vision slot.
    public static let vision = Entry(
        id: "rao-studios/Ministral-3-8B-Instruct-2512-mlx-8bit",
        revision: "3d71052d4c126d816a5a73df75222ecee8de3036",
        vendor: .mistral, role: .vision, family: "mistral3",
        displayName: "Ministral 3 8B Vision",
        releasedYear: 2025, releasedMonth: 12,
        downloadBytes: 10_414_950_269, weightsBytes: 10_380_812_121, minimumMemoryGB: 32)

    /// Qwen3-Coder-Next, REAP expert-pruned to 48B (3B active), 4-bit MLX. Rao's mirror
    /// of andosen/Qwen3-Coder-Next-REAP-48B-A3B-mlx-4Bit @ e4a6dfc28e890ca695f8d8ae9ef34dea73676198,
    /// byte-identical, published 2026-10-14 (plus LICENSE.txt and a card).
    public static let coding = Entry(
        id: "rao-studios/Qwen3-Coder-Next-REAP-48B-A3B-mlx-4bit",
        revision: "9664f44f273d250ab2fb4450b3310473f2371732",
        vendor: .qwen, role: .coding, family: "qwen3_next",
        displayName: "Qwen3 Coder Next 48B",
        releasedYear: 2026, releasedMonth: 2,
        downloadBytes: 27_507_938_455, weightsBytes: 27_496_309_660, minimumMemoryGB: 48)

    public static let all: [Entry] = [embedding, generalSmall, generalStandard, generalLarge, vision, coding]

    /// The general chat models an app offers on device, smallest first.
    public static let general: [Entry] = [generalSmall, generalStandard, generalLarge]

    /// What Thread itself runs: never removed through Sewn.
    public static let kept: Set<String> = [generalStandard.id, embedding.id]

    public static func entry(role: Role) -> Entry {
        all.first { $0.role == role }!
    }

    /// The entry with this Hub id, case-insensitively; nil for anything not on the list.
    public static func entry(id: String) -> Entry? {
        all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public static func isKept(_ id: String) -> Bool {
        kept.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
}
