import ApplicationServices

/// Проверка и запрос разрешения Accessibility. Оно нужно для того, чтобы
/// синтетические события (Cmd+C/Cmd+V, стрелки) реально доходили до других
/// приложений — без доверия `CGEvent.post` тихо игнорируется системой.
///
/// Отдельного ключа в Info.plist для Accessibility нет (в отличие от
/// камеры/микрофона): доверие выдаёт пользователь вручную в
/// System Settings → Privacy & Security → Accessibility. Приложение может лишь
/// показать системный запрос через `AXIsProcessTrustedWithOptions`.
nonisolated enum AccessibilityAuthorization {

    /// Доверено ли приложение прямо сейчас.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Проверяет доверие и, если его нет, показывает системный запрос
    /// (открывает нужную панель настроек). Возвращает текущий статус доверия.
    @discardableResult
    static func promptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
