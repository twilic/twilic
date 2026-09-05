#!/usr/bin/env python3
"""Generate Codec.swift from twilic-java Codec.java."""

from __future__ import annotations

from pathlib import Path

JAVA = Path(__file__).resolve().parents[2] / "java/src/main/java/io/twilic/internal/core/Codec.java"
OUT = Path(__file__).resolve().parents[1] / "Sources/Twilic/Core/Codec.swift"

# Hand-maintained Swift port derived from Java Codec.java (same logic as Python codec.py)
SWIFT = r'''import Foundation

private let simple8bSlots: [(Int, Int)] = [
    (60, 1), (30, 2), (20, 3), (15, 4), (12, 5), (10, 6), (8, 7), (7, 8),
    (6, 10), (5, 12), (4, 15), (3, 20), (2, 30), (1, 60),
]

private let u64Max = UInt64.max
private let mask60: UInt64 = (1 << 60) - 1

private struct AddResult { var value: UInt64; var ok: Bool }
private struct Run { var value: UInt64; var count: UInt64 }
private struct Patch { var position: UInt64; var value: UInt64 }

enum Codec {
    static func encodeI64Vector(_ values: [Int64], _ codec: VectorCodec, _ out: inout Data) throws {
        var bos = Data()
        switch codec {
        case .rle:
            try encodeI64Rle(values, &bos)
        case .directBitpack:
            try encodeI64DirectBitpack(values, &bos)
        case .deltaBitpack:
            try encodeI64DirectBitpack(delta(values), &bos)
        case .forBitpack:
            if values.isEmpty {
                Wire.encodeVaruint(0, &bos)
            } else {
                let minValue = values.min()!
                Wire.encodeVaruint(Wire.encodeZigzag(minValue), &bos)
                let shifted = values.map { $0 - minValue }
                try encodeI64DirectBitpack(shifted, &bos)
            }
        case .deltaForBitpack:
            let deltas = delta(values)
            if deltas.isEmpty {
                Wire.encodeVaruint(0, &bos)
            } else {
                let minValue = deltas.min()!
                Wire.encodeVaruint(Wire.encodeZigzag(minValue), &bos)
                let shifted = deltas.map { $0 - minValue }
                try encodeI64DirectBitpack(shifted, &bos)
            }
        case .deltaDeltaBitpack:
            try encodeI64DeltaDelta(values, &bos)
        case .patchedFor:
            try encodeI64PatchedFor(values, &bos)
        case .simple8b:
            try encodeI64Simple8b(values, &bos)
        case .plain, .dictionary, .stringRef, .prefixDelta, .xorFloat:
            try encodeI64Plain(values, &bos)
        }
        out.append(bos)
    }

    static func decodeI64Vector(_ reader: Wire.Reader, _ codec: VectorCodec) throws -> [Int64] {
        switch codec {
        case .rle: return try decodeI64Rle(reader)
        case .directBitpack: return try decodeI64DirectBitpack(reader)
        case .deltaBitpack: return undelta(try decodeI64DirectBitpack(reader))
        case .forBitpack:
            let encodedMin = try reader.readVaruint()
            let minValue = Wire.decodeZigzag(encodedMin)
            if reader.isEOF { return [] }
            let shifted = try decodeI64DirectBitpack(reader)
            return shifted.map { $0 + minValue }
        case .deltaForBitpack:
            let encodedMin = try reader.readVaruint()
            let minValue = Wire.decodeZigzag(encodedMin)
            if reader.isEOF { return [] }
            let shifted = try decodeI64DirectBitpack(reader)
            return undelta(shifted.map { $0 + minValue })
        case .deltaDeltaBitpack: return try decodeI64DeltaDelta(reader)
        case .patchedFor: return try decodeI64PatchedFor(reader)
        case .simple8b: return try decodeI64Simple8b(reader)
        case .plain, .dictionary, .stringRef, .prefixDelta, .xorFloat:
            return try decodeI64Plain(reader)
        }
    }

    static func encodeU64Vector(_ values: [UInt64], _ codec: VectorCodec, _ out: inout Data) throws {
        var bos = Data()
        switch codec {
        case .rle: try encodeU64Rle(values, &bos)
        case .directBitpack: try encodeU64DirectBitpack(values, &bos)
        case .forBitpack:
            if values.isEmpty {
                Wire.encodeVaruint(0, &bos)
            } else {
                let minValue = values.min()!
                Wire.encodeVaruint(minValue, &bos)
                try encodeU64DirectBitpack(values.map { $0 - minValue }, &bos)
            }
        case .plain: try encodeU64Plain(values, &bos)
        case .simple8b: try encodeU64Simple8b(values, &bos)
        default: try encodeU64Plain(values, &bos)
        }
        out.append(bos)
    }

    static func decodeU64Vector(_ reader: Wire.Reader, _ codec: VectorCodec) throws -> [UInt64] {
        switch codec {
        case .rle: return try decodeU64Rle(reader)
        case .directBitpack: return try decodeU64DirectBitpack(reader)
        case .forBitpack:
            let minValue = try reader.readVaruint()
            if reader.isEOF { return [] }
            let shifted = try decodeU64DirectBitpack(reader)
            var out: [UInt64] = []
            for v in shifted {
                let sum = checkedAddU64(v, minValue)
                if !sum.ok { throw TwilicErrors.invalidData("u64 FOR overflow") }
                out.append(sum.value)
            }
            return out
        case .plain: return try decodeU64Plain(reader)
        case .simple8b: return try decodeU64Simple8b(reader)
        default: return try decodeU64Plain(reader)
        }
    }

    static func encodeF64Vector(_ values: [Double], _ codec: VectorCodec, _ out: inout Data) throws {
        var bos = Data()
        if codec == .xorFloat {
            try encodeXorFloat(values, &bos)
        } else {
            Wire.encodeVaruint(UInt64(values.count), &bos)
            for v in values { Wire.appendF64LE(&bos, v) }
        }
        out.append(bos)
    }

    static func decodeF64Vector(_ reader: Wire.Reader, _ codec: VectorCodec) throws -> [Double] {
        if codec == .xorFloat { return try decodeXorFloat(reader) }
        let length = Int(try reader.readVaruint())
        var out: [Double] = []
        for _ in 0 ..< length { out.append(try Wire.readF64LE(reader)) }
        return out
    }

    // ... remaining helpers in second part
}
'''

# Append rest from file if exists
PART2 = Path(__file__).parent / "codec_swift_part2.swift.inc"
if PART2.exists():
    SWIFT = SWIFT.replace("// ... remaining helpers in second part", PART2.read_text())
else:
    SWIFT = SWIFT.replace(
        "// ... remaining helpers in second part",
        "// PART2 missing - run gen_codec_part2.py",
    )

OUT.write_text(SWIFT)
print("wrote", OUT)
