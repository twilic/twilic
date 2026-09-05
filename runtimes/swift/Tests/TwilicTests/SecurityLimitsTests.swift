import XCTest
@testable import Twilic
final class SecurityLimitsTests: XCTestCase {
    func testCumulativeBudgetAndBounds() throws {
        let reader = Wire.Reader(Data([0]))
        try reader.claimOutput(100)
        XCTAssertThrowsError(try reader.claimOutput(100))
        XCTAssertThrowsError(try reader.readExact(-1))
        XCTAssertThrowsError(try reader.readExact(Int.max))
    }
    func testDepth() {
        let bytes = Data(Array(repeating: UInt8(0xa1), count: 70) + [0xc0])
        XCTAssertThrowsError(try decodeV2(bytes))
    }
}
