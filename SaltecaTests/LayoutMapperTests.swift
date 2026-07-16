import XCTest
@testable import Salteca

final class LayoutMapperTests: XCTestCase {

    func testRuToEn() {
        XCTAssertEqual(LayoutMapper.ruToEn("ghbdtn"), "привет")
    }

    func testEnToRu() {
        XCTAssertEqual(LayoutMapper.enToRu("привет"), "ghbdtn")
    }

    func testCasePreservation() {
        XCTAssertEqual(LayoutMapper.ruToEn("Ghbdtn"), "Привет")
        XCTAssertEqual(LayoutMapper.enToRu("Привет"), "Ghbdtn")
    }

    func testDigitsAndSpacesUnchanged() {
        XCTAssertEqual(LayoutMapper.ruToEn("ghbdtn 123 vbh"), "привет 123 мир")
        XCTAssertEqual(LayoutMapper.enToRu("привет 123 мир"), "ghbdtn 123 vbh")
    }
}
