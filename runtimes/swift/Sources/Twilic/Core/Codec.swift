import Foundation

private let simple8bSlots: [(Int, Int)] = [
    (60, 1), (30, 2), (20, 3), (15, 4), (12, 5), (10, 6), (8, 7), (7, 8),
    (6, 10), (5, 12), (4, 15), (3, 20), (2, 30), (1, 60),
]

private let u64Max = UInt64.max
private let mask60: UInt64 = (1 << 60) - 1

struct AddResult { var value: UInt64; var ok: Bool }
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
        case .deltaBitpack: return try undelta(try decodeI64DirectBitpack(reader))
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
            return try undelta(shifted.map { $0 + minValue })
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
        let length = try reader.readCount()
        var out: [Double] = []
        for _ in 0 ..< length { out.append(try Wire.readF64LE(reader)) }
        return out
    }


    static func encodeU64Plain(_ values: [UInt64], _ out: inout Data) throws {
        Wire.encodeVaruint(UInt64(values.count), &out)
        for value in values { Wire.encodeVaruint(value, &out) }
    }
    static func decodeU64Plain(_ reader: Wire.Reader) throws -> [UInt64] {
        let length = try reader.readCount()
        var result: [UInt64] = []
        for _ in 0..<length { result.append(try reader.readVaruint()) }
        return result
    }
    static func encodeU64Rle(_ values: [UInt64], _ out: inout Data) throws {
        var runs: [Run] = []
        for value in values {
            if let last = runs.last, last.value == value {
                runs[runs.count - 1] = Run(value: value, count: last.count + 1)
            } else {
                runs.append(Run(value: value, count: 1))
            }
        }
        Wire.encodeVaruint(UInt64(runs.count), &out)
        for run in runs {
            Wire.encodeVaruint(run.value, &out)
            Wire.encodeVaruint(run.count, &out)
        }
    }
    static func decodeU64Rle(_ reader: Wire.Reader) throws -> [UInt64] {
        let runsLen = try reader.readCount()
        var out: [UInt64] = []
        for _ in 0..<runsLen {
            let value = try reader.readVaruint()
            let count = try reader.readCount()
            out.append(contentsOf: Array(repeating: value, count: count))
        }
        return out
    }
    static func bitWidth(_ v: UInt64) -> Int {
        if v == 0 { return 1 }
        return 64 - v.leadingZeroBitCount
    }
    static func encodeU64DirectBitpack(_ values: [UInt64], _ out: inout Data) throws {
        Wire.encodeVaruint(UInt64(values.count), &out)
        if values.isEmpty { out.append(0); return }
        var width = 1
        for v in values { width = max(width, bitWidth(v)) }
        out.append(UInt8(width))
        try packU64Values(values, width, &out)
    }
    static func decodeU64DirectBitpack(_ reader: Wire.Reader) throws -> [UInt64] {
        let length = try reader.readCount()
        let width = Int(try reader.readU8())
        if length == 0 { return [] }
        if width == 0 || width > 64 { throw TwilicErrors.invalidData("bitpack width") }
        return try unpackU64Values(reader, length, width)
    }
    static func encodeI64Plain(_ values: [Int64], _ out: inout Data) throws {
        Wire.encodeVaruint(UInt64(values.count), &out)
        for value in values { Wire.encodeVaruint(Wire.encodeZigzag(value), &out) }
    }
    static func decodeI64Plain(_ reader: Wire.Reader) throws -> [Int64] {
        let length = try reader.readCount()
        return try (0..<length).map { _ in Wire.decodeZigzag(try reader.readVaruint()) }
    }
    static func delta(_ values: [Int64]) -> [Int64] {
        var out: [Int64] = []
        var prev: Int64 = 0
        for (i, value) in values.enumerated() {
            out.append(i == 0 ? value : value - prev)
            prev = value
        }
        return out
    }
    static func undelta(_ values: [Int64]) throws -> [Int64] {
        var out: [Int64] = []
        var prev: Int64 = 0
        for (i, value) in values.enumerated() {
            if i == 0 { out.append(value); prev = value; continue }
            let nxt = checkedAddI64(prev, value)
            guard nxt.ok else { throw TwilicErrors.invalidData("delta overflow") }
            out.append(nxt.value)
            prev = nxt.value
        }
        return out
    }

    static func encodeI64Rle(_ values: [Int64], _ out: inout Data) throws {
        var runs: [Run] = []
        for value in values {
            if let last = runs.last, Int64(bitPattern: last.value) == value {
                runs[runs.count - 1] = Run(value: UInt64(bitPattern: value), count: last.count + 1)
            } else {
                runs.append(Run(value: UInt64(bitPattern: value), count: 1))
            }
        }
        Wire.encodeVaruint(UInt64(runs.count), &out)
        for run in runs {
            Wire.encodeVaruint(Wire.encodeZigzag(Int64(bitPattern: run.value)), &out)
            Wire.encodeVaruint(run.count, &out)
        }
    }

    static func decodeI64Rle(_ reader: Wire.Reader) throws -> [Int64] {
        let runsLen = try reader.readCount()
        var out: [Int64] = []
        for _ in 0 ..< runsLen {
            let value = Wire.decodeZigzag(try reader.readVaruint())
            let count = try reader.readCount()
            out.append(contentsOf: Array(repeating: value, count: count))
        }
        return out
    }

    static func encodeI64DirectBitpack(_ values: [Int64], _ out: inout Data) throws {
        Wire.encodeVaruint(UInt64(values.count), &out)
        if values.isEmpty { out.append(0); return }
        let encoded = values.map { Wire.encodeZigzag($0) }
        var width = 1
        for v in encoded { width = max(width, bitWidth(v)) }
        out.append(UInt8(width))
        try packU64Values(encoded, width, &out)
    }

    static func decodeI64DirectBitpack(_ reader: Wire.Reader) throws -> [Int64] {
        let length = try reader.readCount()
        let width = Int(try reader.readU8())
        if length == 0 { return [] }
        if width == 0 || width > 64 { throw TwilicErrors.invalidData("bitpack width") }
        let encoded = try unpackU64Values(reader, length, width)
        return encoded.map { Wire.decodeZigzag($0) }
    }

    static func encodeI64Simple8b(_ values: [Int64], _ out: inout Data) throws {
        let encoded = values.map { Wire.encodeZigzag($0) }
        try encodeU64Simple8bInner(encoded, &out)
    }

    static func decodeI64Simple8b(_ reader: Wire.Reader) throws -> [Int64] {
        let encoded = try decodeU64Simple8bInner(reader)
        return encoded.map { Wire.decodeZigzag($0) }
    }

    static func encodeU64Simple8b(_ values: [UInt64], _ out: inout Data) throws {
        try encodeU64Simple8bInner(values, &out)
    }

    static func decodeU64Simple8b(_ reader: Wire.Reader) throws -> [UInt64] {
        try decodeU64Simple8bInner(reader)
    }

    static func encodeU64Simple8bInner(_ values: [UInt64], _ out: inout Data) throws {
        Wire.encodeVaruint(UInt64(values.count), &out)
        if values.isEmpty { return }
        let maxValue = values.max() ?? 0
        if maxValue > mask60 {
            out.append(0)
            for value in values { Wire.encodeVaruint(value, &out) }
            return
        }
        out.append(1)
        var idx = 0
        while idx < values.count {
            var zeroRun = 0
            while idx + zeroRun < values.count && values[idx + zeroRun] == 0 && zeroRun < 240 {
                zeroRun += 1
            }
            if zeroRun >= 120 {
                let take = zeroRun >= 240 ? 240 : 120
                let word: UInt64 = take == 240 ? 0 : (1 << 60)
                Wire.appendU64LE(&out, word)
                idx += take
                continue
            }
            var packed = false
            for (selectorIdx, slot) in simple8bSlots.enumerated() {
                let count = slot.0
                let slotWidth = slot.1
                if idx + count > values.count { continue }
                let maxEncodable: UInt64 = slotWidth == 64 ? u64Max : ((1 << slotWidth) - 1)
                if values[idx ..< idx + count].contains(where: { $0 > maxEncodable }) { continue }
                let selector = UInt64(selectorIdx + 2)
                var payload: UInt64 = 0
                var shift = 0
                for value in values[idx ..< idx + count] {
                    payload |= value << shift
                    shift += slotWidth
                }
                Wire.appendU64LE(&out, (selector << 60) | payload)
                idx += count
                packed = true
                break
            }
            if !packed {
                let word = (15 << 60) | (values[idx] & mask60)
                Wire.appendU64LE(&out, word)
                idx += 1
            }
        }
    }

    static func decodeU64Simple8bInner(_ reader: Wire.Reader) throws -> [UInt64] {
        let length = try reader.readCount()
        if length == 0 { return [] }
        let mode = try reader.readU8()
        if mode == 0 {
            var out: [UInt64] = []
            for _ in 0 ..< length { out.append(try reader.readVaruint()) }
            return out
        }
        if mode != 1 { throw TwilicErrors.invalidData("simple8b mode") }
        var out: [UInt64] = []
        while out.count < length {
            let packed = try Wire.readU64LE(reader)
            let selector = packed >> 60
            let payload = packed & mask60
            if selector == 0 || selector == 1 {
                let count = selector == 0 ? 240 : 120
                let limit = min(count, length - out.count)
                out.append(contentsOf: Array(repeating: 0, count: limit))
            } else if selector >= 2 && selector <= 15 {
                let count: Int
                let width: Int
                if selector == 15 { count = 1; width = 60 }
                else {
                    let slot = simple8bSlots[Int(selector) - 2]
                    count = slot.0
                    width = slot.1
                }
                let mask: UInt64 = width == 64 ? u64Max : ((1 << width) - 1)
                var shift = 0
                let limit = min(count, length - out.count)
                for _ in 0 ..< limit {
                    out.append((payload >> shift) & mask)
                    shift += width
                }
            } else {
                throw TwilicErrors.invalidData("simple8b selector")
            }
        }
        return out
    }

    static func encodeI64DeltaDelta(_ values: [Int64], _ out: inout Data) throws {
        Wire.encodeVaruint(UInt64(values.count), &out)
        if values.isEmpty { return }
        Wire.encodeVaruint(Wire.encodeZigzag(values[0]), &out)
        if values.count == 1 { return }
        let d1 = values[1] - values[0]
        Wire.encodeVaruint(Wire.encodeZigzag(d1), &out)
        var dd: [Int64] = []
        var prevDelta = d1
        for i in 1 ..< values.count - 1 {
            let d = values[i + 1] - values[i]
            dd.append(d - prevDelta)
            prevDelta = d
        }
        try encodeI64DirectBitpack(dd, &out)
    }

    static func decodeI64DeltaDelta(_ reader: Wire.Reader) throws -> [Int64] {
        let length = try reader.readCount()
        if length == 0 { return [] }
        let first = Wire.decodeZigzag(try reader.readVaruint())
        if length == 1 { return [first] }
        let firstDelta = Wire.decodeZigzag(try reader.readVaruint())
        let dd = try decodeI64DirectBitpack(reader)
        if dd.count != length - 2 { throw TwilicErrors.invalidData("delta-delta length") }
        var out = [first]
        var prev = first
        let second = checkedAddI64(prev, firstDelta)
        guard second.ok else { throw TwilicErrors.invalidData("delta-delta overflow") }
        out.append(second.value)
        prev = second.value
        var prevDelta = firstDelta
        for ddv in dd {
            let d = checkedAddI64(prevDelta, ddv)
            guard d.ok else { throw TwilicErrors.invalidData("delta-delta overflow") }
            let nxt = checkedAddI64(prev, d.value)
            guard nxt.ok else { throw TwilicErrors.invalidData("delta-delta overflow") }
            out.append(nxt.value)
            prev = nxt.value
            prevDelta = d.value
        }
        return out
    }

    static func encodeI64PatchedFor(_ values: [Int64], _ out: inout Data) throws {
        if values.isEmpty {
            Wire.encodeVaruint(0, &out)
            return
        }
        let base = values.min()!
        let shifted = values.map { $0 - base }
        Wire.encodeVaruint(UInt64(shifted.count), &out)
        Wire.encodeVaruint(Wire.encodeZigzag(base), &out)
        let maxValue = shifted.map { UInt64(bitPattern: $0) }.max() ?? 0
        let bw = bitWidth(maxValue)
        let baseWidth = bw > 2 ? bw - 2 : 0
        out.append(UInt8(baseWidth))
        var patchPositions: [(Int, UInt64)] = []
        var mainValues: [UInt64] = []
        for (idx, value) in shifted.enumerated() {
            let uv = UInt64(bitPattern: value)
            if bitWidth(uv) > baseWidth {
                patchPositions.append((idx, uv))
                var main: UInt64 = 0
                if baseWidth > 0 {
                    let mask = (1 << baseWidth) - 1
                    main = uv & UInt64(mask)
                }
                mainValues.append(main)
            } else {
                mainValues.append(uv)
            }
        }
        for value in mainValues { Wire.encodeVaruint(value, &out) }
        Wire.encodeVaruint(UInt64(patchPositions.count), &out)
        for (pos, val) in patchPositions {
            Wire.encodeVaruint(UInt64(pos), &out)
            Wire.encodeVaruint(val, &out)
        }
    }

    static func decodeI64PatchedFor(_ reader: Wire.Reader) throws -> [Int64] {
        let length = try reader.readCount()
        if length == 0 { return [] }
        let base = Wire.decodeZigzag(try reader.readVaruint())
        _ = try reader.readU8()
        var values = try (0 ..< length).map { _ in try reader.readVaruint() }
        let patchCount = try reader.readCount()
        for _ in 0 ..< patchCount {
            let pos = try reader.readIndex()
            let patch = try reader.readVaruint()
            if pos < values.count { values[pos] = patch }
        }
        return values.map { Int64(bitPattern: $0) + base }
    }

    static func leadingZeros64(_ x: UInt64) -> Int {
        x == 0 ? 64 : x.leadingZeroBitCount
    }

    static func trailingZeros64(_ x: UInt64) -> Int {
        x == 0 ? 64 : x.trailingZeroBitCount
    }

    static func encodeXorFloat(_ values: [Double], _ out: inout Data) throws {
        Wire.encodeVaruint(UInt64(values.count), &out)
        if values.isEmpty { return }
        var prev = values[0].bitPattern
        Wire.appendU64LE(&out, prev)
        for i in 1 ..< values.count {
            let bitsValue = values[i].bitPattern
            let x = prev ^ bitsValue
            if x == 0 {
                out.append(0)
            } else {
                out.append(1)
                let leading = leadingZeros64(x)
                let trailing = trailingZeros64(x)
                let width = 64 - (leading + trailing)
                Wire.encodeVaruint(UInt64(leading), &out)
                Wire.encodeVaruint(UInt64(trailing), &out)
                Wire.encodeVaruint(UInt64(width), &out)
                let payload = width == 64 ? x : ((x >> trailing) & ((1 << width) - 1))
                Wire.encodeVaruint(payload, &out)
            }
            prev = bitsValue
        }
    }

    static func decodeXorFloat(_ reader: Wire.Reader) throws -> [Double] {
        let length = try reader.readCount()
        if length == 0 { return [] }
        var prev = try Wire.readU64LE(reader)
        var out = [Double(bitPattern: prev)]
        for _ in 1 ..< length {
            let flag = try reader.readU8()
            var bitsValue = prev
            if flag != 0 {
                let leading = try reader.readVaruint()
                let trailing = try reader.readVaruint()
                let width = try reader.readVaruint()
                let payload = try reader.readVaruint()
                if leading + trailing + width > 64 {
                    throw TwilicErrors.invalidData("xor-float bit widths")
                }
                let x = width == 64 ? payload : (payload << trailing)
                bitsValue = prev ^ x
            }
            out.append(Double(bitPattern: bitsValue))
            prev = bitsValue
        }
        return out
    }
    static func checkedAddU64(_ a: UInt64, _ b: UInt64) -> AddResult {
        let total = a &+ b
        if total < a { return AddResult(value: 0, ok: false) }
        return AddResult(value: total, ok: true)
    }
    static func checkedAddI64(_ a: Int64, _ b: Int64) -> (value: Int64, ok: Bool) {
        let total = a.addingReportingOverflow(b)
        return (total.partialValue, !total.overflow)
    }
    static func packU64Values(_ values: [UInt64], _ width: Int, _ out: inout Data) throws {
        let totalBits = values.count * width
        let byteLen = (totalBits + 7) / 8
        var bytesArr = [UInt8](repeating: 0, count: byteLen)
        var bitPos = 0
        for value in values {
            var written = 0
            while written < width {
                let byteIdx = bitPos / 8
                let bitOff = bitPos % 8
                let room = 8 - bitOff
                let take = min(width - written, room)
                let mask = (1 << take) - 1
                let part = (value >> written) & UInt64(mask)
                bytesArr[byteIdx] |= UInt8(part) << bitOff
                bitPos += take
                written += take
            }
        }
        out.append(contentsOf: bytesArr)
    }
    static func unpackU64Values(_ reader: Wire.Reader, _ length: Int, _ width: Int) throws -> [UInt64] {
        let totalBits = length * width
        let byteLen = (totalBits + 7) / 8
        let raw = try reader.readExact(byteLen)
        var out: [UInt64] = []
        var bitPos = 0
        for _ in 0..<length {
            var value: UInt64 = 0
            var written = 0
            while written < width {
                let byteIdx = bitPos / 8
                if byteIdx >= raw.count { throw TwilicErrors.invalidData("bitpack underflow") }
                let bitOff = bitPos % 8
                let room = 8 - bitOff
                let take = min(width - written, room)
                let mask = (1 << take) - 1
                let part = (UInt64(raw[byteIdx]) >> bitOff) & UInt64(mask)
                value |= part << written
                bitPos += take
                written += take
            }
            out.append(value)
        }
        return out
    }
}
