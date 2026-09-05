import Foundation

enum Wire {
    static func encodeVaruint(_ value: UInt64, _ out: inout Data) {
        var v = value
        if v < 0x80 {
            out.append(UInt8(v))
            return
        }
        while true {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
            if v == 0 { break }
        }
    }

    static func encodeZigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    static func decodeZigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: (value >> 1) ^ UInt64(bitPattern: -(Int64(value & 1))))
    }

    static func encodeBytes(_ bytes: Data, _ out: inout Data) {
        encodeVaruint(UInt64(bytes.count), &out)
        out.append(bytes)
    }

    static func encodeString(_ value: String, _ out: inout Data) {
        encodeBytes(Data(value.utf8), &out)
    }

    static func encodeBitmap(_ bits: [Bool], _ out: inout Data) {
        encodeVaruint(UInt64(bits.count), &out)
        var current: UInt8 = 0
        for (i, bit) in bits.enumerated() {
            if bit { current |= 1 << (i % 8) }
            if i % 8 == 7 {
                out.append(current)
                current = 0
            }
        }
        if !bits.isEmpty && bits.count % 8 != 0 {
            out.append(current)
        }
    }

    final class Reader {
        private let input: Data
        private(set) var offset: Int = 0
        private var depth = 0
        private var budget: Int

        init(_ input: Data) {
            self.input = input
            self.budget = min(input.count, 1024) * 1024
        }

        func claimOutput(_ count: Int) throws {
            guard count >= 0, count <= 1 << 20 else { throw TwilicErrors.invalidData("decode count limit exceeded") }
            guard count <= budget / 8 else { throw TwilicErrors.invalidData("decode output ratio exceeded") }
            budget -= count * 8
        }
        func readIndex() throws -> Int {
            guard let n = Int(exactly: try readVaruint()) else { throw TwilicErrors.invalidData("decode length overflow") }
            return n
        }
        func readCount(_ maximum: Int = 1 << 20) throws -> Int {
            let count = try readIndex()
            guard count <= maximum else { throw TwilicErrors.invalidData("decode count limit exceeded") }
            try claimOutput(count)
            return count
        }
        func enterDepth() throws {
            guard depth < 64 else { throw TwilicErrors.invalidData("decode depth limit exceeded") }
            depth += 1
        }
        func leaveDepth() { depth -= 1 }

        var position: Int { offset }
        var isEOF: Bool { offset >= input.count }

        func readU8() throws -> UInt8 {
            guard offset < input.count else { throw TwilicErrors.unexpectedEOF() }
            let b = input[offset]
            offset += 1
            return b
        }

        func readExact(_ n: Int) throws -> Data {
            guard n >= 0, n <= input.count - offset else { throw TwilicErrors.unexpectedEOF() }
            let end = offset + n
            let slice = input.subdata(in: offset ..< end)
            offset = end
            return slice
        }

        func readVaruint() throws -> UInt64 {
            var shift = 0
            var result: UInt64 = 0
            while true {
                if shift >= 64 { throw TwilicErrors.invalidData("varuint too large") }
                let b = try readU8()
                if shift == 63 && b & 0x7E != 0 { throw TwilicErrors.invalidData("varuint too large") }
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }

        func readI64Zigzag() throws -> Int64 {
            decodeZigzag(try readVaruint())
        }

        func readBytes() throws -> Data {
            let n = try readIndex()
            return try readExact(n)
        }

        func readString() throws -> String {
            let data = try readBytes()
            guard let s = String(data: data, encoding: .utf8) else {
                throw TwilicErrors.utf8Error()
            }
            return s
        }

        func readBitmap() throws -> [Bool] {
            let bitCount = try readCount()
            let byteCount = (bitCount + 7) / 8
            let raw = try readExact(byteCount)
            var bits = [Bool](repeating: false, count: bitCount)
            for i in 0 ..< bitCount {
                bits[i] = ((raw[i / 8] >> (i % 8)) & 1) == 1
            }
            return bits
        }
    }

    static func newReader(_ input: Data) -> Reader { Reader(input) }

    static func u64FromLEBytes(_ b: Data) -> UInt64 {
        precondition(b.count >= 8)
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value |= UInt64(b[i]) << (8 * i)
        }
        return value
    }

    static func readU64LE(_ reader: Reader) throws -> UInt64 {
        let b = try reader.readExact(8)
        return u64FromLEBytes(b)
    }

    static func readF64LE(_ reader: Reader) throws -> Double {
        Double(bitPattern: try readU64LE(reader))
    }

    static func appendU64LE(_ out: inout Data, _ v: UInt64) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 32) & 0xFF))
        out.append(UInt8((v >> 40) & 0xFF))
        out.append(UInt8((v >> 48) & 0xFF))
        out.append(UInt8((v >> 56) & 0xFF))
    }

    static func appendF64LE(_ out: inout Data, _ v: Double) {
        appendU64LE(&out, v.bitPattern)
    }
}
