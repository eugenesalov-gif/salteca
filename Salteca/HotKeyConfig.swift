import Foundation
import Carbon.HIToolbox
#if canImport(AppKit)
import AppKit
#endif

/// Конфигурация глобального хоткея: физический код клавиши + модификаторы.
///
/// `keyCode` — физический `kVK_*`, не зависящий от активной раскладки (как и в
/// `HotKeyManager`): это то, чем оперирует `RegisterEventHotKey`. `displayKey`
/// хранится отдельно — захваченный при записи символ («X»), чтобы показывать
/// хоткей пользователю, не ведя таблицу keyCode→имя (она зависит от раскладки).
struct HotKeyConfig: Codable, Equatable {

    /// Физический код клавиши (`kVK_ANSI_X` и т.п.).
    var keyCode: UInt32
    /// Carbon-маска модификаторов (`cmdKey | shiftKey | …`) для `RegisterEventHotKey`.
    var carbonModifiers: UInt32
    /// Символ клавиши для отображения в UI (заглавный, напр. "X").
    var displayKey: String

    /// Cmd+Shift+X — исходный зашитый хоткей прототипа.
    static let `default` = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_X),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayKey: "X"
    )

    /// Человекочитаемое представление вида «⌘⇧X» (порядок символов — по HIG:
    /// Control, Option, Shift, Command).
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { result += "⌘" }
        result += displayKey.uppercased()
        return result
    }

    #if canImport(AppKit)
    /// Переводит модификаторы события `NSEvent` в Carbon-маску. Учитываются только
    /// Cmd/Shift/Option/Control — остальные (Fn, CapsLock) для хоткея не нужны.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// Собирает конфиг из перехваченного `NSEvent` (keyDown). `nil`, если нет ни
    /// одного модификатора — «голые» клавиши хоткеем быть не должны (иначе хоткей
    /// перехватывал бы обычный набор).
    static func from(event: NSEvent) -> HotKeyConfig? {
        let mods = carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else { return nil }
        let display = (event.charactersIgnoringModifiers ?? "").uppercased()
        return HotKeyConfig(keyCode: UInt32(event.keyCode),
                            carbonModifiers: mods,
                            displayKey: display.isEmpty ? "?" : display)
    }
    #endif
}
