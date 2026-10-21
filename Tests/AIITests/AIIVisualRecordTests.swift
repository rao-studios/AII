//
//  AIIVisualRecordTests.swift
//  AIITests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  The record of a picture: an envelope of media type image carrying the picture, a caption
//  partition, one partition per region addressed by its media fragment, labels in the graph,
//  and a payload that leaves the regions' vectors out.
//

import Foundation
import XCTest
@testable import AII

/// A picture, as Veil describes one: the caption and tiles are filed as partitions, so the
/// payload keeps only the rest.
struct TestPicture: AIIVisualRecordable, Equatable {
    static let kind: AIIRecord.Kind = .image
    static let group = AIIRecord.Group(id: "camera", label: "Camera roll")
    var recordID: String
    var title: String
    var picture: AIIRecord.Image
    var labels: [String]
    var caption: String = ""
    var tiles: [AIIRecord.Region] = []
    var regions: [AIIRecord.Region] { tiles }
    var captionEmbedding: [Float]? { tiles.isEmpty ? nil : [0.9, 0.8] }

    enum CodingKeys: String, CodingKey { case recordID, title, picture, labels }
}

final class AIIVisualRecordTests: XCTestCase {

    private let location = "file:///Users/me/Pictures/harbor.png"

    private func harbor(location: String?) -> TestPicture {
        let picture = AIIRecord.Image(sha256: String(repeating: "c4", count: 32), width: 64, height: 32, mimeType: "image/png",
                                      location: location, capturedAt: Date(timeIntervalSince1970: 1_760_000_000.5))
        return TestPicture(recordID: "img-0123", title: "harbor.png", picture: picture, labels: ["boat", "harbor"],
                           caption: "Boats in a harbor at dusk",
                           tiles: [.init(x: 0, y: 0, width: 32, height: 32, embedding: [0.1, 0.2]),
                                   .init(x: 32, y: 0, width: 32, height: 32, embedding: [0.3, 0.4])])
    }

    func testAPictureIsACaptionAndItsRegions() throws {
        let value = harbor(location: location)
        let document = try value.document(app: "veil", now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(document.documentID, "veil/image/img-0123")
        XCTAssertEqual(document.record.mediaType, .image)
        XCTAssertEqual(document.record.image, value.picture)
        XCTAssertEqual(document.record.image?.capturedAt, Date(timeIntervalSince1970: 1_760_000_000), "to the second")
        XCTAssertEqual(document.record.tags, ["boat", "harbor"])
        XCTAssertEqual(document.graphEntities.map(\.name), ["boat", "harbor"])

        XCTAssertEqual(document.partitions.map(\.text), ["Boats in a harbor at dusk", "", ""])
        XCTAssertEqual(document.partitions.map(\.url), [nil, "\(location)#xywh=pixel:0,0,32,32", "\(location)#xywh=pixel:32,0,32,32"])
        XCTAssertEqual(document.partitions.map(\.embedding), [[0.9, 0.8], [0.1, 0.2], [0.3, 0.4]])
        XCTAssertEqual(document.partitions.compactMap(\.region).map(\.fragment), ["xywh=pixel:0,0,32,32", "xywh=pixel:32,0,32,32"])

        guard case .object(let payload)? = document.record.payload else { return XCTFail("no payload") }
        XCTAssertEqual(Set(payload.keys), ["recordID", "title", "picture", "labels"], "the regions stay out of the envelope")
        let back = try XCTUnwrap(try document.record.value(as: TestPicture.self))
        XCTAssertEqual(back.picture, value.picture)
        XCTAssertEqual(back.labels, value.labels)
    }

    func testARegionIsAddressedByItsDocumentWhenThePictureHasNoLocation() throws {
        let document = try harbor(location: nil).document(app: "veil")
        XCTAssertEqual(document.partitions[1].url, "aii:veil/image/img-0123#xywh=pixel:0,0,32,32")
        XCTAssertEqual(AIIRecord.Region(url: document.partitions[1].url ?? ""), AIIRecord.Region(x: 0, y: 0, width: 32, height: 32))
    }

    func testALocationThatIsntAURLIsEncoded() throws {
        let document = try harbor(location: "/Users/me/My Pictures/harbor.png#old").document(app: "veil")
        XCTAssertEqual(document.partitions[2].url, "/Users/me/My%20Pictures/harbor.png#xywh=pixel:32,0,32,32",
                       "spaces encoded, its own fragment dropped")
        XCTAssertNoThrow(try document.validate())
    }

    func testTheMediaFragment() {
        let region = AIIRecord.Region(x: 32, y: 64, width: 16, height: 8)
        XCTAssertEqual(region.fragment, "xywh=pixel:32,64,16,8")
        XCTAssertEqual(AIIRecord.Region(fragment: region.fragment), region)
        XCTAssertEqual(AIIRecord.Region(fragment: "t=10&xywh=1,2,3,4"), AIIRecord.Region(x: 1, y: 2, width: 3, height: 4),
                       "pixels by default; other parameters ignored")
        XCTAssertNil(AIIRecord.Region(fragment: "xywh=percent:0,0,50,50"), "pixels only")
        XCTAssertNil(AIIRecord.Region(fragment: "xywh=pixel:0,0,0,8"), "an empty rectangle")
        XCTAssertNil(AIIRecord.Region(url: "file:///harbor.png"))
    }
}
