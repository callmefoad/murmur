import XCTest
@testable import Murmur

final class SmokeTests: XCTestCase {
    func testTrivialFormat() {
        let formatter = TextFormatter(dictionary: [:])
        let result = formatter.format("hello world", autoPeriod: false)
        XCTAssertEqual(result, "Hello world")
    }
}
