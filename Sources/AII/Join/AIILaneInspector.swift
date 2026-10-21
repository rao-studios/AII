//
//  AIILaneInspector.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What one app's lane holds, read the way that app reads it: its groups under an
//        owner, and a sample of its documents checked against aii-record/1. For the lane
//        doctor (`aii lanes doctor`), which walks a lane down the runtime stack.
//  IN:   An app, the owner to read under, a home.
//  OUT:  AIILaneInspection: plain values, so the aii command needs no wire types.
//  PIN:  Read-only, and as the app: its own secret, on Thread's direct port, so the lane is
//        the one its calls land in. Library lists the owner's groups; ExportCorpus samples
//        the owner's documents without their vectors.
//

#if os(macOS)
import Foundation
import Seam

public struct AIILaneInspection: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public var id: String
        public var label: String
        public var documents: Int

        public init(id: String, label: String, documents: Int) {
            self.id = id
            self.label = label
            self.documents = documents
        }
    }

    /// One sampled document, against the schema.
    public struct Sample: Sendable, Equatable {
        public var documentID: String
        /// Its metadata is an aii-record/1 envelope.
        public var isRecord: Bool
        /// The envelope's app, when it is one.
        public var recordApp: AIIApp?
        public var kind: String?
        /// Filed under its envelope's own address, `<app>/<kind>/<id>`.
        public var idMatches: Bool

        public init(documentID: String, isRecord: Bool, recordApp: AIIApp? = nil, kind: String? = nil, idMatches: Bool) {
            self.documentID = documentID
            self.isRecord = isRecord
            self.recordApp = recordApp
            self.kind = kind
            self.idMatches = idMatches
        }
    }

    public var owner: AIIOwner
    public var groups: [Group]
    public var sample: [Sample]
    /// Every document the owner holds was sampled.
    public var sampledAll: Bool

    public init(owner: AIIOwner, groups: [Group], sample: [Sample], sampledAll: Bool) {
        self.owner = owner
        self.groups = groups
        self.sample = sample
        self.sampledAll = sampledAll
    }
}

public enum AIILaneInspector {
    /// Reads `app`'s lane under `owner`, as `app`, with up to `sampleSize` documents.
    public static func inspect(app: AIIApp, owner: AIIOwner, home: AIIHome,
                               sampleSize: Int = 50) async throws -> AIILaneInspection {
        try await inspect(app: app, owner: owner, wire: PosixThreadWire(home: home, identity: .app(app)),
                          sampleSize: sampleSize)
    }

    static func inspect(app: AIIApp, owner: AIIOwner, wire: any ThreadWire, sampleSize: Int) async throws -> AIILaneInspection {
        var library = Thread_V1_ThreadLibraryRequest()
        library.ownerID = owner.rawValue
        let groups = try await wire.library(library).groups
            .filter { $0.ownerID.isEmpty || $0.ownerID == owner.rawValue }
            .map { AIILaneInspection.Group(id: $0.id, label: $0.label, documents: $0.documents.count) }

        var export = Thread_V1_ThreadExportCorpusRequest()
        export.ownerID = owner.rawValue
        export.limit = Int32(max(sampleSize, 1))
        let page = try await wire.exportCorpus(export)
        let sample = page.documents.map { document -> AIILaneInspection.Sample in
            let record = AIIRecord.decode(document.metadata)
            return AIILaneInspection.Sample(documentID: document.id, isRecord: record != nil, recordApp: record?.app,
                                            kind: record?.kind.rawValue, idMatches: record?.documentID == document.id)
        }
        return AIILaneInspection(owner: owner, groups: groups.sorted { $0.id < $1.id }, sample: sample,
                                 sampledAll: !page.hasMore_p)
    }
}
#endif
