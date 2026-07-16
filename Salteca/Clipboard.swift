import AppKit

/// Тонкая обёртка над `NSPasteboard.general` для строкового буфера обмена.
nonisolated enum Clipboard {
    static func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func write(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
