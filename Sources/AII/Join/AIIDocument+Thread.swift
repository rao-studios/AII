//
//  AIIDocument+Thread.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A document as Thread's wire carries it: the index item, the requests that file a
//        set of documents under an owner, and a document read back from Thread.
//  IN:   AIIDocuments (AIIInstance.remember, or an app with its own Thread client: Craft,
//        Veil); a ThreadDocumentContent from Documents or ExportCorpus.
//  OUT:  `indexItem()`; `indexRequests(_:owner:)`; `AIIDocument(content:)`.
//  PIN:  Public, so every app files exactly what AIIInstance files. The document id is
//        `<app>/<kind>/<id>`, the name the title, the metadata the envelope's canonical
//        JSON, the entities the declared ones plus the tags. Partitions are described to
//        Thread (ThreadPartitionInput) only when one has a url or a vector. Requests are
//        grouped by app and group, since one request files into one group, and split so
//        none passes `maximumRequestBytes` (the wire's limit is 32 MB; one picture with its
//        tile vectors is about 5 MB).
//

#if os(macOS)
import Foundation
import Seam

extension AIIDocument {

    /// What one request may carry before it is split.
    public static let maximumRequestBytes = 16 * 1024 * 1024

    /// This document as Thread's index item.
    public func indexItem() throws -> Thread_V1_ThreadIndexItem {
        var item = Thread_V1_ThreadIndexItem()
        item.documentID = documentID
        item.name = record.title
        item.texts = partitions.map(\.text)
        item.mediaType = record.mediaType.rawValue
        item.metadata = try metadata()
        item.entities = graphEntities.map { entity in
            var out = Thread_V1_ThreadGraphEntityIn()
            out.name = entity.name
            out.kind = entity.kind
            return out
        }
        item.relationships = relationships.map { relationship in
            var out = Thread_V1_ThreadGraphRelationIn()
            out.subject = relationship.subject
            out.predicate = relationship.predicate
            out.object = relationship.object
            return out
        }
        if partitions.contains(where: { $0.url != nil || $0.embedding != nil }) {
            item.partitions = partitions.map { partition in
                var input = Thread_V1_ThreadPartitionInput()
                input.url = partition.url ?? ""
                input.embedding = partition.embedding ?? []
                return input
            }
        }
        return item
    }

    /// The requests that file `documents` under `owner`: one per app and group, in the
    /// order they first appear, each split to stay under `maximumBytes`.
    public static func indexRequests(_ documents: [AIIDocument], owner: AIIOwner,
                                     maximumBytes: Int = maximumRequestBytes) throws -> [Thread_V1_ThreadIndexRequest] {
        var order: [String] = []
        var byGroup: [String: [AIIDocument]] = [:]
        for document in documents {
            try document.validate()
            let key = document.wireGroupID
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(document)
        }
        var requests: [Thread_V1_ThreadIndexRequest] = []
        for key in order {
            guard let members = byGroup[key], let first = members.first else { continue }
            var request = Thread_V1_ThreadIndexRequest()
            request.ownerID = owner.rawValue
            request.groupID = key
            request.groupLabel = first.record.group.label
            request.scope = "personal"
            var size = 0
            for document in members {
                let item = try document.indexItem()
                let bytes = try item.serializedBytes() as [UInt8]
                if !request.items.isEmpty, size + bytes.count > maximumBytes {
                    requests.append(request)
                    request.items = []
                    size = 0
                }
                request.items.append(item)
                size += bytes.count
            }
            requests.append(request)
        }
        return requests
    }

    /// A document read back from Thread: the envelope from its metadata, its partitions with
    /// their urls and vectors (when the read asked for embeddings), and each region a url
    /// names. Its graph isn't read back. Nil when the metadata isn't an aii-record/1 envelope.
    public init?(content: Thread_V1_ThreadDocumentContent) {
        guard let record = AIIRecord.decode(content.metadata) else { return nil }
        let described = content.partitions
        // A partition with no url of its own reports where Thread stores the document.
        let storage = "/documents/\(content.id)"
        let partitions = content.texts.enumerated().map { index, text -> Partition in
            guard index < described.count else { return Partition(text: text) }
            var url = described[index].url
            if url.hasPrefix("file:"), url.hasSuffix(storage) { url = "" }
            return Partition(text: text, url: url.isEmpty ? nil : url,
                             embedding: described[index].embedding.isEmpty ? nil : described[index].embedding,
                             region: AIIRecord.Region(url: url))
        }
        self.init(record: record, partitions: partitions)
    }
}
#endif
