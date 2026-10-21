//
//  AIIDocumentTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  A record as Thread files it: tags join the graph as plain concept entities, partitions
//  are described only when they carry a url or a vector, a set of documents is filed one
//  request per group and split by size, what can't be filed is refused before it is sent,
//  and a document reads back from Thread with its regions.
//

import Foundation
import XCTest
@testable import AII
import Seam

final class AIIDocumentTests: XCTestCase {

    private func document(_ id: String = "n1", group: String = "standups", tags: [String] = [],
                          entities: [AIIRecord.Entity] = [],
                          partitions: [AIIDocument.Partition] = [.init(text: "Ada leads Joltvault.")],
                          payload: AIIJSONValue? = nil) -> AIIDocument {
        let record = AIIRecord(app: "notes", id: id, kind: .note, title: "Stand-up",
                               group: .init(id: group, label: group.capitalized), tags: tags,
                               rememberedAt: Date(timeIntervalSince1970: 1_760_000_000), payload: payload)
        return AIIDocument(record: record, partitions: partitions, entities: entities)
    }

    func testTagsJoinTheGraphAsPlainConcepts() throws {
        let tagged = try document(tags: ["standup", "Q4 planning", "  ", "STANDUP"]).indexItem()
        XCTAssertEqual(tagged.entities.map(\.name), ["standup", "Q4 planning"], "named as written, once each")
        XCTAssertEqual(tagged.entities.map(\.kind), ["concept", "concept"])

        let declared = try document(tags: ["joltvault", "q4"], entities: [.init(name: "Joltvault", kind: "work")]).indexItem()
        XCTAssertEqual(declared.entities.map(\.name), ["Joltvault", "q4"], "a declared entity of the same name wins")
        XCTAssertEqual(declared.entities.first?.kind, "work")

        XCTAssertTrue(try document().indexItem().entities.isEmpty, "nothing given: Thread extracts")
    }

    func testTheIndexItem() throws {
        let item = try document().indexItem()
        XCTAssertEqual(item.documentID, "notes/note/n1")
        XCTAssertEqual(item.name, "Stand-up")
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.texts, ["Ada leads Joltvault."])
        XCTAssertTrue(item.partitions.isEmpty, "plain text isn't described")
        XCTAssertEqual(AIIRecord.decode(item.metadata), document().record)
        XCTAssertFalse(String(decoding: item.metadata, as: UTF8.self).contains("Joltvault"), "the text isn't in the envelope")

        let described = try document(partitions: [
            .init(text: "Boats at dusk", embedding: [0.1, 0.2]),
            .init(text: "", url: "file:///harbor.png#xywh=pixel:0,0,32,32", embedding: [0.3, 0.4]),
        ]).indexItem()
        XCTAssertEqual(described.texts, ["Boats at dusk", ""])
        XCTAssertEqual(described.partitions.map(\.url), ["", "file:///harbor.png#xywh=pixel:0,0,32,32"])
        XCTAssertEqual(described.partitions.map(\.embedding), [[0.1, 0.2], [0.3, 0.4]])
    }

    func testRequestsGoOnePerGroupAndSplitBySize() throws {
        let documents = [document("a"), document("b", group: "ideas"), document("c")]
        let requests = try AIIDocument.indexRequests(documents, owner: .local)
        XCTAssertEqual(requests.map(\.groupID), ["notes-standups", "notes-ideas"])
        XCTAssertEqual(requests.map { $0.items.map(\.documentID) }, [["notes/note/a", "notes/note/c"], ["notes/note/b"]])
        XCTAssertEqual(requests.map(\.groupLabel), ["Standups", "Ideas"])
        XCTAssertEqual(Set(requests.map(\.ownerID)), ["aii-local"])
        XCTAssertEqual(Set(requests.map(\.scope)), ["personal"])

        let split = try AIIDocument.indexRequests(documents, owner: .app("notes"), maximumBytes: 1)
        XCTAssertEqual(split.map(\.items.count), [1, 1, 1], "an item alone once two don't fit")
        XCTAssertEqual(split.map(\.groupID), ["notes-standups", "notes-standups", "notes-ideas"])
        XCTAssertEqual(Set(split.map(\.ownerID)), ["local-notes"])
    }

    func testWhatCantBeFiledIsRefused() {
        XCTAssertThrowsError(try document(partitions: []).validate()) { XCTAssertEqual($0 as? AIIRecordError, .noPartitions("n1")) }
        XCTAssertThrowsError(try document(partitions: [.init(text: "ok"), .init(text: "  ")]).validate()) {
            XCTAssertEqual($0 as? AIIRecordError, .emptyPartition("n1", index: 1))
        }
        XCTAssertNoThrow(try document(partitions: [.init(text: "", embedding: [0.5])]).validate(), "a vector alone is enough")
        XCTAssertThrowsError(try document(partitions: [.init(text: "x", url: "/My Pictures/a.png")]).validate()) {
            XCTAssertEqual($0 as? AIIRecordError, .invalidURL("n1", url: "/My Pictures/a.png"), "a space is no URL")
        }
        let bulk = AIIJSONValue.object(["body": .string(String(repeating: "x", count: AIIDocument.maximumMetadataBytes))])
        XCTAssertThrowsError(try document(payload: bulk).validate()) {
            guard case .metadataTooLarge("n1", _)? = $0 as? AIIRecordError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AIIDocument.indexRequests([document(), document("b", partitions: [])], owner: .local),
                             "nothing is sent when one document can't be filed")
    }

    func testADocumentReadsBack() throws {
        let original = document(partitions: [
            .init(text: "Boats at dusk", embedding: [0.1]),
            .init(text: "", url: "file:///harbor.png#xywh=pixel:32,0,32,32", embedding: [0.2]),
        ])
        var content = Thread_V1_ThreadDocumentContent()
        content.id = original.documentID
        content.metadata = try original.metadata()
        content.texts = original.partitions.map(\.text)
        content.partitions = [
            // A partition with no url of its own reports where Thread stores the document.
            output(url: "file:///var/thread/documents/\(original.documentID)", embedding: [0.1]),
            output(url: "file:///harbor.png#xywh=pixel:32,0,32,32", embedding: [0.2]),
        ]
        let read = try XCTUnwrap(AIIDocument(content: content))
        XCTAssertEqual(read.record, original.record)
        XCTAssertEqual(read.partitions.map(\.url), [nil, "file:///harbor.png#xywh=pixel:32,0,32,32"])
        XCTAssertEqual(read.partitions.map(\.embedding), [[0.1], [0.2]])
        XCTAssertEqual(read.partitions[1].region, AIIRecord.Region(x: 32, y: 0, width: 32, height: 32))
        XCTAssertNil(read.partitions[0].region)

        content.metadata = Data(#"{"title":"not an envelope"}"#.utf8)
        XCTAssertNil(AIIDocument(content: content))
    }

    private func output(url: String, embedding: [Float]) -> Thread_V1_ThreadPartitionOutput {
        var partition = Thread_V1_ThreadPartitionOutput()
        partition.url = url
        partition.embedding = embedding
        return partition
    }
}
