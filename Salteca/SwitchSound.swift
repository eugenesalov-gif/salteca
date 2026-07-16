import Foundation
import AppKit

/// Звук, который проигрывается в момент ПОДТВЕРЖДЁННОГО переключения раскладки
/// (и в авто-режиме, и по хоткею). Персистится в `UserDefaults` по `rawValue`.
enum SwitchSound: String, CaseIterable, Identifiable {
    case soft
    case click
    case tripleTap
    case none

    var id: String { rawValue }

    /// Ключ и значение по умолчанию — единая точка правды для плеера и
    /// `AppController` (оба читают одно и то же из `UserDefaults`).
    static let defaultsKey = "switchSound"
    static let defaultValue: SwitchSound = .soft

    /// Человекочитаемое имя для Picker в настройках.
    var displayName: String {
        switch self {
        case .soft:      return "Мягкий клик"
        case .click:     return "Щелчок"
        case .tripleTap: return "Тройной тап"
        case .none:      return "Без звука"
        }
    }

    /// Имя файла-ресурса в бандле (без расширения), либо `nil` для «без звука».
    /// Файлы добавлены в таргет Salteca как `.mp3`.
    var resourceName: String? {
        switch self {
        case .soft:      return "Soft Button Press Sound Effect"
        case .click:     return "Flashlight Button Click"
        case .tripleTap: return "UI Click Triple Tap Sound"
        case .none:      return nil
        }
    }
}

/// Проигрывает выбранный звук переключения раскладки.
///
/// Синглтон: `NSSound` предзагружаются из бандла один раз и переиспользуются.
/// Вызывается из авто-режима (applyQueue / главный поток колбэка уведомления),
/// из хоткей-пути (своя очередь) и из настроек — поэтому потокобезопасен
/// (`@unchecked Sendable` + `NSLock`), а само проигрывание всегда уходит на
/// главный поток (требование AppKit к `NSSound`).
nonisolated final class SwitchSoundPlayer: @unchecked Sendable {

    static let shared = SwitchSoundPlayer()

    private let lock = NSLock()
    private var current: SwitchSound
    private var cache: [SwitchSound: NSSound] = [:]

    private init() {
        let stored = UserDefaults.standard.string(forKey: SwitchSound.defaultsKey)
        current = stored.flatMap(SwitchSound.init(rawValue:)) ?? SwitchSound.defaultValue
    }

    /// Обновляет выбранный звук (вызывает `AppController` при изменении настройки).
    func update(_ sound: SwitchSound) {
        lock.lock()
        current = sound
        lock.unlock()
    }

    /// Проигрывает текущий выбранный звук. No-op для `.none`. Перед стартом
    /// останавливает предыдущее проигрывание того же звука, чтобы частые
    /// последовательные переключения не глушили друг друга на середине.
    func play() {
        lock.lock()
        let sound = current
        lock.unlock()
        play(sound)
    }

    /// Проигрывает конкретный звук (используется для превью в настройках).
    func play(_ sound: SwitchSound) {
        guard sound.resourceName != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let nsSound = self.nsSound(for: sound) else { return }
            nsSound.stop()
            nsSound.play()
        }
    }

    /// Лениво загружает и кэширует `NSSound` по URL ресурса. Загрузка по URL
    /// (а не `NSSound(named:)`) надёжнее для `.mp3` с пробелами в имени.
    private func nsSound(for sound: SwitchSound) -> NSSound? {
        lock.lock()
        if let cached = cache[sound] { lock.unlock(); return cached }
        lock.unlock()

        guard let name = sound.resourceName,
              let url = Bundle.main.url(forResource: name, withExtension: "mp3"),
              let nsSound = NSSound(contentsOf: url, byReference: true) else {
            return nil
        }
        lock.lock()
        cache[sound] = nsSound
        lock.unlock()
        return nsSound
    }
}
