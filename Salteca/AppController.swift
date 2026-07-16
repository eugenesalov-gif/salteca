import Foundation
import SwiftUI
import Combine

/// Единый владелец состояния и сервисов приложения.
///
/// Раньше сервисами владел `AppDelegate`, но menu-bar-меню и окно настроек —
/// это SwiftUI-вьюхи, которым нужен доступ к тому же состоянию и управление им.
/// Поэтому владение переехало сюда: `@Published`-свойства двусторонне связаны с
/// `Toggle`'ами меню и настройками, а их `didSet` применяет эффект (start/stop/
/// перерегистрация хоткея) и сохраняет значение в `UserDefaults`.
///
/// `@MainActor`, т.к. читается/пишется из SwiftUI и `AppDelegate` (главный поток).
/// Сами сервисы `nonisolated`/`Sendable` и работают на своих фоновых потоках —
/// отсюда их только запускают/останавливают.
@MainActor
final class AppController: ObservableObject {

    static let shared = AppController()

    // MARK: - Состояние (связано с UI, персистентно)

    /// Авто-режим (фоновая правка по мере набора).
    @Published var autoModeEnabled: Bool {
        didSet {
            defaults.set(autoModeEnabled, forKey: Keys.autoMode)
            applyAutoMode()
        }
    }

    /// Хоткей-режим (правка выделенного/последнего слова по глобальному хоткею).
    @Published var hotKeyModeEnabled: Bool {
        didSet {
            defaults.set(hotKeyModeEnabled, forKey: Keys.hotKeyMode)
            applyHotKeyMode()
        }
    }

    /// Текущий глобальный хоткей.
    @Published var hotKey: HotKeyConfig {
        didSet {
            persistHotKey()
            hotKeyManager.update(to: hotKey)
        }
    }

    /// Звук в момент подтверждённого переключения раскладки (оба режима).
    @Published var switchSound: SwitchSound {
        didSet {
            defaults.set(switchSound.rawValue, forKey: Keys.switchSound)
            SwitchSoundPlayer.shared.update(switchSound)
        }
    }

    /// Автозапуск при входе в систему. Источник правды — система (`SMAppService`),
    /// а не `UserDefaults`: геттер читает реальный статус, поэтому чекбокс в меню
    /// показывает актуальное состояние (в т.ч. если пользователь поменял его в
    /// Системных настройках) при каждом открытии меню. Поэтому это НЕ
    /// `@Published`-хранилище, а вычисляемое свойство над сервисом.
    var launchAtLoginEnabled: Bool {
        LaunchAtLogin.isEnabled
    }

    /// Включает/выключает автозапуск. Ошибку регистрации гасим (без краша) и
    /// логируем — чекбокс останется в реальном состоянии, т.к. геттер читает
    /// систему. При успехе дёргаем `objectWillChange`, чтобы открытое меню
    /// перерисовало галочку.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            objectWillChange.send()
        } catch {
            print("⚠️ Автозапуск: не удалось \(enabled ? "включить" : "выключить") — \(error.localizedDescription)")
        }
    }

    // MARK: - Персистентность

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let autoMode = "autoModeEnabled"
        static let hotKeyMode = "hotKeyModeEnabled"
        static let hotKey = "hotKeyConfig"
        static let switchSound = SwitchSound.defaultsKey
    }

    // MARK: - Сервисы (владение переехало из AppDelegate)

    private let replacementStore = ReplacementStore()
    private let hotKeyManager: HotKeyManager
    private lazy var textCapture = TextCaptureService(replacementStore: replacementStore)
    private lazy var autoMode = AutoModeService(replacementStore: replacementStore)

    /// Эффекты (start/register) применяются только после `start()`, чтобы `didSet`
    /// при загрузке начальных значений в `init` не дёргал сервисы раньше времени.
    private var started = false

    // MARK: - Инициализация

    private init() {
        // Значения по умолчанию для первого запуска: оба режима включены (как
        // AUTO_MODE = True в прототипе).
        defaults.register(defaults: [Keys.autoMode: true, Keys.hotKeyMode: true])

        let loadedHotKey = Self.loadHotKey(from: defaults) ?? .default
        hotKeyManager = HotKeyManager(config: loadedHotKey)

        let loadedSound = defaults.string(forKey: Keys.switchSound)
            .flatMap(SwitchSound.init(rawValue:)) ?? SwitchSound.defaultValue

        // Присваивание в init не запускает didSet — сервисы здесь не трогаются.
        autoModeEnabled = defaults.bool(forKey: Keys.autoMode)
        hotKeyModeEnabled = defaults.bool(forKey: Keys.hotKeyMode)
        hotKey = loadedHotKey
        switchSound = loadedSound

        // didSet в init не срабатывает — подхватываем выбранный звук в плеер вручную.
        SwitchSoundPlayer.shared.update(loadedSound)
    }

    // MARK: - Жизненный цикл (из AppDelegate)

    /// Поднимает сервисы согласно сохранённому состоянию. Идемпотентно.
    func start() {
        guard !started else { return }
        started = true
        hotKeyManager.onHotKey = { [textCapture] in textCapture.handleHotKey() }
        applyHotKeyMode()
        applyAutoMode()
    }

    func stop() {
        hotKeyManager.unregister()
        autoMode.stop()
    }

    // MARK: - Применение состояния к сервисам

    private func applyAutoMode() {
        guard started else { return }
        if autoModeEnabled { autoMode.start() } else { autoMode.stop() }
    }

    private func applyHotKeyMode() {
        guard started else { return }
        if hotKeyModeEnabled { hotKeyManager.register() } else { hotKeyManager.unregister() }
    }

    // MARK: - Персистентность хоткея (JSON в UserDefaults)

    private func persistHotKey() {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: Keys.hotKey)
        }
    }

    private static func loadHotKey(from defaults: UserDefaults) -> HotKeyConfig? {
        guard let data = defaults.data(forKey: Keys.hotKey) else { return nil }
        return try? JSONDecoder().decode(HotKeyConfig.self, from: data)
    }
}
