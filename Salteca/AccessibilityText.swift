import ApplicationServices

/// Чтение выделенного текста в сфокусированном элементе через Accessibility.
///
/// В отличие от Cmd+C, это синхронно, беззвучно и не трогает буфер обмена —
/// поэтому годится для пошагового чтения растущего выделения при поиске границы
/// слова. Возвращает `nil`, если элемент/атрибут недоступны (например, часть
/// Electron-приложений и терминалов не отдаёт AX-текст) — тогда вызывающий код
/// откатывается на чтение через буфер обмена.
nonisolated enum AccessibilityText {

    static func selectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusedStatus == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focused as! AXUIElement

        var selectedRef: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selectedRef)
        guard selectedStatus == .success, let text = selectedRef as? String else {
            return nil
        }
        return text
    }
}
