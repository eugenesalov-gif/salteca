import XCTest
import Carbon.HIToolbox
import AppKit
@testable import Salteca

final class HotKeyConfigTests: XCTestCase {

    // MARK: - displayString

    func testDefaultDisplayString() {
        // Порядок символов — по HIG (⌃⌥⇧⌘), поэтому Cmd+Shift это "⇧⌘" (как ⇧⌘S).
        XCTAssertEqual(HotKeyConfig.default.displayString, "⇧⌘X")
    }

    func testDisplayStringModifierOrderAndSymbols() {
        // Порядок по HIG: ⌃⌥⇧⌘, символ клавиши — в конце и заглавный.
        let all = HotKeyConfig(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            displayKey: "a"
        )
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘A")
    }

    func testDisplayStringSingleModifier() {
        let cfg = HotKeyConfig(keyCode: UInt32(kVK_Space),
                               carbonModifiers: UInt32(controlKey), displayKey: "Space")
        XCTAssertEqual(cfg.displayString, "⌃SPACE")
    }

    // MARK: - Codable round-trip (персистентность)

    func testCodableRoundTrip() throws {
        let original = HotKeyConfig(keyCode: 12, carbonModifiers: UInt32(cmdKey | optionKey), displayKey: "Q")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotKeyConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - NSEvent.ModifierFlags -> Carbon

    func testCarbonModifiersFromFlags() {
        XCTAssertEqual(HotKeyConfig.carbonModifiers(from: [.command, .shift]),
                       UInt32(cmdKey | shiftKey))
        XCTAssertEqual(HotKeyConfig.carbonModifiers(from: [.control, .option]),
                       UInt32(controlKey | optionKey))
        // Посторонние флаги (CapsLock) в маску не попадают.
        XCTAssertEqual(HotKeyConfig.carbonModifiers(from: [.command, .capsLock]),
                       UInt32(cmdKey))
    }

    func testCarbonModifiersEmptyForNoModifiers() {
        XCTAssertEqual(HotKeyConfig.carbonModifiers(from: []), 0)
    }
}
