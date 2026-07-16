//
//  SaltecaApp.swift
//  Salteca
//
//  Created by Eugene Salov on 09/07/2026.
//

import SwiftUI

@main
struct SaltecaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Единый источник состояния/сервисов — им же владеет `AppDelegate` (через
    /// синглтон), поэтому меню, настройки и жизненный цикл смотрят в одно место.
    @ObservedObject private var controller = AppController.shared

    var body: some Scene {
        // Иконка в строке меню (Dock-иконки нет — LSUIElement в build settings).
        MenuBarExtra("Salteca", systemImage: "character.cursor.ibeam") {
            MenuBarContent(controller: controller)
        }

        // Окно настроек: открывается по «Настройки…» из меню и по ⌘, .
        Settings {
            SettingsView(controller: controller)
        }
    }
}

/// Тонкий адаптер жизненного цикла NSApplication: разовые задачи запуска и
/// корректное завершение. Вся логика/состояние — в `AppController`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-приложение без Dock-иконки. Задаём политику в рантайме, а не
        // только через INFOPLIST_KEY_LSUIElement: текущий генератор Info.plist в
        // Xcode этот ключ в plist не переносит, поэтому надёжнее .accessory здесь.
        NSApp.setActivationPolicy(.accessory)

        // Запрашиваем Accessibility заранее: без доверия синтетические Cmd+C/
        // Cmd+V не дойдут до других приложений.
        if !AccessibilityAuthorization.promptIfNeeded() {
            print("⚠️ Accessibility ещё не выдан — захват/замена текста не будут работать, пока не разрешить в System Settings.")
        }

        // Страховка: если в прошлый сеанс мы заглушили alert volume и не успели
        // вернуть (падение/выход посреди захвата) — восстанавливаем сейчас.
        DispatchQueue.global().async {
            SystemAlertSound.restorePendingIfNeeded()
        }

        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }
}
