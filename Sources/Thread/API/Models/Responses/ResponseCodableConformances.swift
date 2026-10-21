//
//  ResponseCodableConformances.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

// Hummingbird ResponseCodable conformances for all shared response types.
// Keeps model files framework-agnostic while wiring up automatic JSON encoding
// via context.responseEncoder (JSONEncoder with ISO-8601 dates).
import Hummingbird

// MARK: - Search
extension SearchResponse: ResponseCodable {}

// MARK: - Graph
extension GraphResponse: ResponseCodable {}

// MARK: - Embeddings
extension EmbeddingResponse: ResponseCodable {}
extension EmbeddingBatchResponse: ResponseCodable {}
