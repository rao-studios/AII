//
//  AIIJSONValue.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Any JSON value, as a Sendable, Equatable Swift value: what an aii-record/1
//        envelope carries as its payload (an app's own record type, encoded) and what
//        Sewn's attribution arrives as.
//  OUT:  `init(encoding:)` from any Encodable, `decode(as:)` back to it, and Codable.
//  PIN:  Encoded the way the envelope is (sorted keys, ISO-8601 dates), so a payload
//        round-trips to the same bytes. Integers are kept apart from other numbers, so
//        an Int field reads back as an Int.
//

import Foundation

public enum AIIJSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([AIIJSONValue])
    case object([String: AIIJSONValue])

    /// `value`, as the JSON it encodes to.
    public init(encoding value: some Encodable) throws {
        let data = try Self.encoder.encode(value)
        self = try Self.decoder.decode(AIIJSONValue.self, from: data)
    }

    /// The value this JSON encodes, as `type`.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try Self.decoder.decode(T.self, from: try Self.encoder.encode(self))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension AIIJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AIIJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AIIJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
