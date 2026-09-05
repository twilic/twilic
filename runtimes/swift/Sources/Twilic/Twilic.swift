import Foundation

public let twilicVersion = "3.0.0"

/// Encodes a value with the Twilic v2 wire profile (stateless; per-message interning).
public func encode(_ value: Value) throws -> Data {
    try encodeV2(value)
}

/// Decodes a value encoded with the Twilic v2 wire profile.
public func decode(_ data: Data) throws -> Value {
    try decodeV2(data)
}

// encodeWithSchema, encodeBatch, SessionEncoder — available once Protocol.swift is fully ported.
