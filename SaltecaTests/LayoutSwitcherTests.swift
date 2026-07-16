import XCTest
@testable import Salteca

final class LayoutSwitcherTests: XCTestCase {

    // MARK: - Русская раскладка

    func testRussianLayoutMatchesRussian() {
        XCTAssertTrue(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.Russian", name: "Русская", target: .russian))
        XCTAssertTrue(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.RussianWin", name: "Russian – PC", target: .russian))
    }

    func testRussianLayoutIsNotEnglish() {
        // Ловушка: "russian" содержит подстроку "us" — русская раскладка не должна
        // опознаваться как английская ни по id, ни по имени.
        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.Russian", name: "Русская", target: .english))
        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.RussianWin", name: "Russian", target: .english))
    }

    // MARK: - Английская раскладка

    func testEnglishLayoutsMatchEnglish() {
        for id in ["com.apple.keylayout.US",
                   "com.apple.keylayout.ABC",
                   "com.apple.keylayout.British",
                   "com.apple.keylayout.USInternational-PC"] {
            XCTAssertTrue(
                LayoutSwitcher.matchScript(id: id, name: "", target: .english),
                "ожидали английскую для \(id)")
        }
    }

    func testEnglishLayoutIsNotRussian() {
        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.US", name: "U.S.", target: .russian))
        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.ABC", name: "ABC", target: .russian))
    }

    func testEnglishMatchesByLocalizedName() {
        // id без явных маркеров, но имя содержит "English".
        XCTAssertTrue(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.SomeCustom", name: "English (custom)", target: .english))
    }

    // MARK: - Другие раскладки не считаются ни русской, ни английской

    func testUnrelatedLayoutMatchesNeither() {
        // "Belarusian" содержит "us", но не должна попасть в английские (матчинг
        // идёт по префиксу компонента id, а не по подстроке всей строки).
        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.Belarusian", name: "Belarusian", target: .english))
        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.Belarusian", name: "Belarusian", target: .russian))

        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.French", name: "Français", target: .english))
        XCTAssertFalse(LayoutSwitcher.matchScript(
            id: "com.apple.keylayout.French", name: "Français", target: .russian))
    }
}
