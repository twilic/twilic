import XCTest
@testable import Twilic

final class V2RoundtripTests: XCTestCase {
    func testScalarRoundtrip() throws {
        let cases: [Value] = [
            newNull(),
            newBool(true),
            newI64(-42),
            newU64(1001),
            newF64(3.14),
            newString("hello"),
        ]
        for value in cases {
            let data = try encode(value)
            let decoded = try decode(data)
            XCTAssertTrue(equal(value, decoded))
        }
    }

    func testShapedArrayRoundtrip() throws {
        let row1 = newMap(entry("id", newU64(1)), entry("name", newString("a")))
        let row2 = newMap(entry("id", newU64(2)), entry("name", newString("b")))
        let value = newArray([row1, row2])
        let data = try encode(value)
        let decoded = try decode(data)
        XCTAssertTrue(equal(value, decoded))
    }

    func testMapRoundtrip() throws {
        let value = newMap(
            entry("id", newU64(1001)),
            entry("name", newString("alice"))
        )
        let data = try encode(value)
        let decoded = try decode(data)
        XCTAssertTrue(equal(value, decoded))
    }
}
