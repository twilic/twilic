import XCTest
@testable import Twilic

final class CodecSpecVectorsTests: XCTestCase {
    func testSimple8bI64RoundtripSmallValues() throws {
        let values: [Int64] = [1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5]
        var out = Data()
        try Codec.encodeI64Vector(values, .simple8b, &out)
        let reader = Wire.newReader(out)
        let decoded = try Codec.decodeI64Vector(reader, .simple8b)
        XCTAssertEqual(decoded, values)
    }

    func testSimple8bU64RoundtripWithLongZeroRuns() throws {
        var values = Array(repeating: UInt64(0), count: 130)
        values += [1, 2, 3, 4, 5]
        values += Array(repeating: UInt64(0), count: 250)
        var out = Data()
        try Codec.encodeU64Vector(values, .simple8b, &out)
        let reader = Wire.newReader(out)
        let decoded = try Codec.decodeU64Vector(reader, .simple8b)
        XCTAssertEqual(decoded, values)
    }

    func testSimple8bU64FallsBackForLargeValues() throws {
        let values: [UInt64] = [1 << 61, (1 << 61) + 7, (1 << 61) + 99]
        var out = Data()
        try Codec.encodeU64Vector(values, .simple8b, &out)
        let reader = Wire.newReader(out)
        let decoded = try Codec.decodeU64Vector(reader, .simple8b)
        XCTAssertEqual(decoded, values)
    }

    func testXorFloatRoundtripSmoothSeries() throws {
        let values: [Double] = [1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5]
        var out = Data()
        try Codec.encodeF64Vector(values, .xorFloat, &out)
        let reader = Wire.newReader(out)
        let decoded = try Codec.decodeF64Vector(reader, .xorFloat)
        XCTAssertEqual(decoded, values)
    }

    func testForU64OverflowIsRejected() throws {
        var out = Data()
        Wire.encodeVaruint(UInt64.max, &out)
        Wire.encodeVaruint(1, &out)
        out.append(1)
        out.append(0x01)
        let reader = Wire.newReader(out)
        do {
            _ = try Codec.decodeU64Vector(reader, .forBitpack)
            XCTFail("expected decode error")
        } catch let err as TwilicError {
            XCTAssertEqual(err.kind, .errInvalidData)
            XCTAssertEqual(err.msg, "u64 FOR overflow")
        }
    }

    func testDirectBitpackInvalidWidthIsRejected() throws {
        var out = Data()
        Wire.encodeVaruint(1, &out)
        out.append(0)
        let reader = Wire.newReader(out)
        do {
            _ = try Codec.decodeI64Vector(reader, .directBitpack)
            XCTFail("expected decode error")
        } catch let err as TwilicError {
            XCTAssertEqual(err.kind, .errInvalidData)
            XCTAssertEqual(err.msg, "bitpack width")
        }
    }
}
