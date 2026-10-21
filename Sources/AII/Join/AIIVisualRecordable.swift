//
//  AIIVisualRecordable.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The record of a picture: what it is (its identity, size and place), what it shows
//        in words (the caption, searched by text), and its regions (each searched by its own
//        vector). Veil's images and their tiles are one; a screenshot with a described
//        region is another.
//  IN:   The app's type: `struct Picture: AIIVisualRecordable { var picture: AIIRecord.Image … }`.
//  OUT:  Through AIIRecordable: an envelope of media type `image` carrying the picture, and
//        a document whose partitions are the caption, then one per region.
//  PIN:  A region is a partition, not an envelope field: its url ends in the W3C media
//        fragment `#xywh=pixel:x,y,w,h` (AIIRecord.Region), so a hit, a Documents read or
//        an export says which region it is. Region vectors, like a caption vector, must
//        come from the index's own embedder (AIIModels.embedding); Thread refuses another
//        size. A region's text is usually empty: it is found by its vector. The labels are
//        the record's tags, filed as concept entities next to its own entities.
//

import Foundation

public protocol AIIVisualRecordable: AIIRecordable {
    /// The picture this record describes.
    var picture: AIIRecord.Image { get }
    /// What the picture shows, in words: the first partition, searched by text.
    var caption: String { get }
    /// A vector for the caption from the index's embedder, or nil for Thread to embed it.
    var captionEmbedding: [Float]? { get }
    /// Rectangles of the picture, each its own partition. Default: none.
    var regions: [AIIRecord.Region] { get }
    /// Words for what the picture shows (an ontology's labels). Default: none.
    var labels: [String] { get }
}

extension AIIVisualRecordable {
    public var captionEmbedding: [Float]? { nil }
    public var regions: [AIIRecord.Region] { [] }
    public var labels: [String] { [] }

    public var text: String { caption }
    public var mediaType: AIIRecord.MediaType { .image }
    public var tags: [String] { labels }
    public var image: AIIRecord.Image? { picture }

    /// The caption, then one partition per region; each region's url is filled in by
    /// `document(app:now:)` from the picture's location.
    public var partitions: [AIIDocument.Partition] {
        [AIIDocument.Partition(text: caption, embedding: captionEmbedding)]
            + regions.map { AIIDocument.Partition(text: $0.text, embedding: $0.embedding, region: $0) }
    }
}
