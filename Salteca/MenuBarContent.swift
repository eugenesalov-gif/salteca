import SwiftUI

/// Содержимое меню, выпадающего из иконки в строке меню.
///
/// `Toggle` в `.menu`-стиле `MenuBarExtra` рисуется пунктом с галочкой-
/// индикатором текущего состояния — ровно то, что нужно для вкл/выкл режимов.
/// Двусторонняя привязка к `@Published`-свойствам `AppController` сама включает/
/// выключает сервисы (см. их `didSet`).
struct MenuBarContent: View {
    @ObservedObject var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("Авто-режим", isOn: $controller.autoModeEnabled)
        Toggle("Хоткей-режим", isOn: $controller.hotKeyModeEnabled)

        Divider()

        Button("Настройки…") {
            // LSUIElement-приложение не активно по умолчанию — без активации окно
            // настроек откроется за другими окнами.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Button("О программе Salteca") {
            // Стандартная About-панель сама берёт имя, иконку и версию
            // (CFBundleShortVersionString) из бандла — для menu-bar-приложения без
            // строки меню это простой способ показать версию.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Divider()

        Button("Выход") { NSApp.terminate(nil) }
    }
}
