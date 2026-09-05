import Foundation

public struct EncodedDictionaryBlock: Sendable {
    public var block: Data?
    public var ok: Bool
}

enum DictionaryCore {
    static func decodeTrainedDictionaryPayload(_ payload: Data) throws -> [String] {
        let reader = Wire.newReader(payload)
        let n = try reader.readVaruint()
        var values: [String] = []
        for _ in 0 ..< Int(n) {
            values.append(try reader.readString())
        }
        if !reader.isEOF {
            throw TwilicErrors.invalidData("trained dictionary payload trailing bytes")
        }
        return values
    }

    static func encodeTrainedDictionaryBlock(
        _ values: [String],
        _ dictionary: [String]
    ) throws -> EncodedDictionaryBlock {
        if values.isEmpty {
            var out = Data()
            out.append(0)
            Wire.encodeVaruint(0, &out)
            return EncodedDictionaryBlock(block: out, ok: true)
        }
        var byValue: [String: UInt64] = [:]
        for (idx, value) in dictionary.enumerated() {
            byValue[value] = UInt64(idx)
        }
        var ids: [UInt64] = []
        for value in values {
            guard let refID = byValue[value] else {
                return EncodedDictionaryBlock(block: nil, ok: false)
            }
            ids.append(refID)
        }
        var raw = Data()
        raw.append(0)
        Wire.encodeVaruint(UInt64(ids.count), &raw)
        for refID in ids {
            Wire.encodeVaruint(refID, &raw)
        }
        let maxID = ids.max() ?? 0
        let bitWidth = maxID == 0 ? 0 : (64 - maxID.leadingZeroBitCount)
        var packed = Data()
        try packFixedWidthU64(ids, bitWidth, &packed) // swiftlint:disable
        var bitpacked = Data()
        bitpacked.append(1)
        Wire.encodeVaruint(UInt64(ids.count), &bitpacked)
        bitpacked.append(UInt8(bitWidth))
        bitpacked.append(packed)
        if bitpacked.count < raw.count {
            return EncodedDictionaryBlock(block: bitpacked, ok: true)
        }
        return EncodedDictionaryBlock(block: raw, ok: true)
    }

    static func decodeTrainedDictionaryBlock(_ block: Data, _ dictionary: [String]) throws -> [String] {
        let reader = Wire.newReader(block)
        let mode = try reader.readU8()
        let n = try reader.readCount()
        let ids: [UInt64]
        if mode == 0 {
            ids = try (0 ..< n).map { _ in try reader.readVaruint() }
        } else if mode == 1 {
            let bitWidth = Int(try reader.readU8())
            let remaining = block.count - reader.position
            let packed = try reader.readExact(remaining)
            ids = try unpackFixedWidthU64(packed, n, bitWidth)
        } else {
            throw TwilicErrors.invalidData("trained dictionary block mode")
        }
        if !reader.isEOF {
            throw TwilicErrors.invalidData("trained dictionary block trailing bytes")
        }
        var out: [String] = []
        for refID in ids {
            guard refID < UInt64(dictionary.count) else {
                throw TwilicErrors.invalidData("trained dictionary block id")
            }
            out.append(dictionary[Int(refID)])
        }
        return out
    }

    private struct WideU128 {
        var lo: UInt64
        var hi: UInt64

        static func fromU64(_ v: UInt64) -> WideU128 { WideU128(lo: v, hi: 0) }

        static func mask(_ width: Int) -> WideU128 {
            if width == 64 { return WideU128(lo: UInt64.max, hi: UInt64.max) }
            if width == 0 { return WideU128(lo: 0, hi: 0) }
            if width <= 64 { return WideU128(lo: (1 << width) &- 1, hi: 0) }
            return WideU128(lo: UInt64.max, hi: (1 << (width - 64)) &- 1)
        }

        func isZero() -> Bool { lo == 0 && hi == 0 }

        func and(_ other: WideU128) -> WideU128 {
            WideU128(lo: lo & other.lo, hi: hi & other.hi)
        }

        func or(_ other: WideU128) -> WideU128 {
            WideU128(lo: lo | other.lo, hi: hi | other.hi)
        }

        func shl(_ n: Int) -> WideU128 {
            if n == 0 { return self }
            if n >= 128 { return WideU128(lo: 0, hi: 0) }
            if n < 64 {
                let newHi = (hi << n) | (lo >> (64 - n))
                let newLo = lo << n
                return WideU128(lo: newLo, hi: newHi)
            }
            return WideU128(lo: 0, hi: lo << (n - 64))
        }

        func shr(_ n: Int) -> WideU128 {
            if n == 0 { return self }
            if n >= 128 { return WideU128(lo: 0, hi: 0) }
            if n < 64 {
                let newLo = (lo >> n) | (hi << (64 - n))
                let newHi = hi >> n
                return WideU128(lo: newLo, hi: newHi)
            }
            return WideU128(lo: hi >> (n - 64), hi: 0)
        }
    }

    private static func packFixedWidthU64(_ values: [UInt64], _ width: Int, _ out: inout Data) throws {
        if width > 64 { throw TwilicErrors.invalidData("fixed-width u64 bit width") }
        if width == 0 {
            for value in values where value != 0 {
                throw TwilicErrors.invalidData("fixed-width u64 value overflow")
            }
            return
        }
        var acc = WideU128(lo: 0, hi: 0)
        var accBits = 0
        for value in values {
            if width < 64 && value >> width != 0 {
                throw TwilicErrors.invalidData("fixed-width u64 value overflow")
            }
            acc = acc.or(WideU128.fromU64(value).shl(accBits))
            accBits += width
            while accBits >= 8 {
                out.append(UInt8(acc.lo & 0xFF))
                acc = acc.shr(8)
                accBits -= 8
            }
        }
        if accBits > 0 {
            out.append(UInt8(acc.lo & 0xFF))
        }
    }

    private static func unpackFixedWidthU64(_ data: Data, _ count: Int, _ width: Int) throws -> [UInt64] {
        if width > 64 { throw TwilicErrors.invalidData("fixed-width u64 bit width") }
        if width == 0 {
            for b in data where b != 0 {
                throw TwilicErrors.invalidData("fixed-width u64 trailing bytes")
            }
            return Array(repeating: 0, count: count)
        }
        var out: [UInt64] = []
        var acc = WideU128(lo: 0, hi: 0)
        var accBits = 0
        var idx = 0
        let mask = WideU128.mask(width)
        for _ in 0 ..< count {
            while accBits < width {
                guard idx < data.count else {
                    throw TwilicErrors.invalidData("fixed-width u64 underflow")
                }
                acc = acc.or(WideU128.fromU64(UInt64(data[idx])).shl(accBits))
                idx += 1
                accBits += 8
            }
            out.append(acc.and(mask).lo)
            acc = acc.shr(width)
            accBits -= width
        }
        if !acc.isZero() {
            throw TwilicErrors.invalidData("fixed-width u64 trailing bytes")
        }
        for j in idx ..< data.count where data[j] != 0 {
            throw TwilicErrors.invalidData("fixed-width u64 trailing bytes")
        }
        return out
    }

    static func applyDictionaryReferences(_ state: SessionState, _ columns: [Column]) {
        for column in columns {
            guard column.values.kind == .string else { continue }
            let values = column.values.strings
            if values.count < 16 { continue }
            let unique = Set(values)
            if Double(unique.count) / Double(values.count) > 0.5 { continue }
            guard column.codec == .dictionary || column.codec == .stringRef else { continue }
            let dictID = allocateDictionaryID(state)
            var payload = Data()
            let keys = unique.sorted()
            Wire.encodeVaruint(UInt64(keys.count), &payload)
            for item in keys {
                Wire.encodeString(item, &payload)
            }
            var profile = DictionaryProfile(
                version: 1,
                hash: dictionaryPayloadHash(payload),
                expiresAt: 0,
                fallback: .failFast
            )
            if state.options.unknownReferencePolicy == .statelessRetry {
                profile.fallback = .statelessRetry
            }
            state.dictionaries[dictID] = payload
            state.dictionaryProfiles[dictID] = profile
            var col = column
            col.dictionaryID = dictID
        }
    }

    static func dictionaryPayloadHash(_ payload: Data) -> UInt64 {
        fnv1a64(payload)
    }

    static func fnv1a64(_ payload: Data) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for b in payload {
            h ^= UInt64(b)
            h = h &* 0x100000001B3
        }
        return h
    }
}

public func decodeTrainedDictionaryPayload(_ payload: Data) throws -> [String] {
    try DictionaryCore.decodeTrainedDictionaryPayload(payload)
}

public func encodeTrainedDictionaryBlock(
    _ values: [String],
    _ dictionary: [String]
) throws -> EncodedDictionaryBlock {
    try DictionaryCore.encodeTrainedDictionaryBlock(values, dictionary)
}

public func decodeTrainedDictionaryBlock(_ block: Data, _ dictionary: [String]) throws -> [String] {
    try DictionaryCore.decodeTrainedDictionaryBlock(block, dictionary)
}

public func applyDictionaryReferences(_ state: SessionState, _ columns: [Column]) {
    DictionaryCore.applyDictionaryReferences(state, columns)
}

public func dictionaryPayloadHash(_ payload: Data) -> UInt64 {
    DictionaryCore.dictionaryPayloadHash(payload)
}
