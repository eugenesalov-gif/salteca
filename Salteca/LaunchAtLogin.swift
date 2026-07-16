import Foundation
import ServiceManagement

/// Автозапуск приложения при входе в систему (Login Item) поверх современного
/// `SMAppService` (macOS 13+). Устаревший `SMLoginItemSetEnabled` не используем.
///
/// Источник правды — сама система (`SMAppService.mainApp.status`), а НЕ
/// `UserDefaults`: пользователь мог включить/выключить автозапуск в Системных
/// настройках, и наш чекбокс должен отражать реальный статус, а не то, что мы
/// когда-то запомнили.
enum LaunchAtLogin {

    /// Реальный текущий статус автозапуска (читается у системы при каждом опросе).
    /// Активным считаем только `.enabled`; `.requiresApproval`/`.notRegistered`/
    /// `.notFound` — это «выключено» с точки зрения пользователя.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Включает/выключает автозапуск. Бросает ошибку `SMAppService`, если
    /// регистрация не удалась — вызывающий её ловит и оставляет чекбокс в
    /// прежнем (реальном) состоянии. No-op, если система уже в нужном состоянии.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
