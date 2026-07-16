import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// Эмуляция нажатий клавиш через CGEvent — по физическим кодам клавиш
/// (`kVK_*`), поэтому независимо от активной раскладки. Требует, чтобы
/// приложение было доверено в Accessibility (иначе `.post` тихо ничего не
/// делает).
nonisolated enum SyntheticKeyboard {

    /// Метка, которой помечены ВСЕ наши синтетические события. Проставляется на
    /// уровне источника (`userData`), поэтому каждое посланное из него событие
    /// несёт её в поле `.eventSourceUserData`. Авто-режимный event tap по этой
    /// метке отличает наши нажатия от настоящего ввода пользователя и молча их
    /// пропускает — точная защита от самозацикливания (урок №4 из Python), без
    /// хрупких временных окон. Значение произвольное, лишь бы не 0.
    static let syntheticEventMarker: Int64 = 0x5A17_ECA0

    private static let source: CGEventSource? = {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.userData = syntheticEventMarker
        return src
    }()

    /// Сгенерировано ли событие нами (а не пользователем)?
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    /// Нажать+отпустить одну клавишу с заданными модификаторами.
    static func tap(_ keyCode: Int, flags: CGEventFlags = []) {
        let vk = CGKeyCode(keyCode)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func commandC() { tap(kVK_ANSI_C, flags: .maskCommand) }
    static func commandV() { tap(kVK_ANSI_V, flags: .maskCommand) }
    static func left() { tap(kVK_LeftArrow) }
    static func right() { tap(kVK_RightArrow) }
    static func shiftLeft() { tap(kVK_LeftArrow, flags: .maskShift) }
    static func shiftRight() { tap(kVK_RightArrow, flags: .maskShift) }
    static func optionShiftLeft() { tap(kVK_LeftArrow, flags: [.maskAlternate, .maskShift]) }
    static func backspace() { tap(kVK_Delete) }

    /// Печатает произвольный текст посимвольно через юникод-события — не зависит
    /// от активной раскладки (в отличие от `tap` по keyCode). Нужен для ретайпа
    /// граничного символа и «хвоста» (extra), набранного пользователем во время
    /// settle-окна авто-режима.
    static func type(_ text: String) {
        for ch in text { typeUnicode(String(ch)) }
    }

    /// Одно нажатие, вставляющее заданный юникод-фрагмент (обычно один символ).
    private static func typeUnicode(_ string: String) {
        let utf16 = Array(string.utf16)
        guard !utf16.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Ждёт, пока пользователь физически отпустит Cmd/Shift/Option, либо пока
    /// не истечёт таймаут. Нужно потому, что хоткей Cmd+Shift+X ещё зажат в
    /// момент срабатывания: если сразу послать Cmd+C, система увидит
    /// Cmd+Shift+C, и «Копировать» не сработает (в Python это лечили серией из
    /// 10 повторных попыток — здесь достаточно дождаться отпускания).
    static func waitForModifiersReleased(timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        let watched: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(watched).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
