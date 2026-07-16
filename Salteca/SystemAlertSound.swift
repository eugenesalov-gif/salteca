import Foundation

/// Управление громкостью системного звука предупреждения (alert volume) —
/// чтобы на время захвата/замены заглушить «бип», который приложения издают на
/// стрелках у границы поля и прочих необработанных синтетических нажатиях.
///
/// Публичного нативного API для alert volume нет, поэтому используем скриптовые
/// команды StandardAdditions (`get volume settings` / `set volume alert
/// volume`). Раньше они шли через `NSAppleScript` + `DispatchQueue.main.sync`,
/// но это давало взаимную блокировку: `NSAppleScript` на главном потоке крутит
/// главный run loop, а очередь захвата в это время ждёт главный поток —
/// приложение зависало после первого же срабатывания. Теперь команды исполняет
/// подпроцесс `osascript` прямо на фоновом потоке захвата: главный поток не
/// участвует, заблокировать очередь/run loop физически нечем, а зависший
/// `osascript` снимается по watchdog-таймауту.
nonisolated enum SystemAlertSound {

    /// Ключ, под которым храним громкость, которую нужно вернуть. Наличие ключа =
    /// «мы заглушили звук и ещё не восстановили» — читается при старте, чтобы
    /// вернуть звук, если приложение упало/вышло посреди захвата.
    private static let pendingRestoreKey = "com.eugenesalov.salteca.pendingAlertVolume"

    /// Ограничение на исполнение одной команды — захват не должен ждать вечно.
    private static let commandTimeout: TimeInterval = 2.0

    // MARK: - Захват: заглушить / восстановить

    /// Заглушает alert volume на время захвата и возвращает исходную громкость
    /// для последующего восстановления. `nil`, если глушить не нужно (звук уже
    /// на 0 — тогда его и не трогаем, иначе застряли бы в выключенном состоянии)
    /// или не удалось прочитать/выполнить.
    static func muteForCapture() -> Int? {
        // Читаем и глушим одной командой — экономим один запуск подпроцесса.
        let script = """
        set v to alert volume of (get volume settings)
        if v > 0 then set volume alert volume 0
        return v
        """
        guard let output = runOsascript(script),
              let original = Int(output),
              original > 0 else {
            return nil
        }
        // Персистим намерение восстановить: если приложение умрёт прямо сейчас,
        // вернём звук при следующем запуске (см. restorePendingIfNeeded).
        UserDefaults.standard.set(original, forKey: pendingRestoreKey)
        return original
    }

    /// Восстанавливает громкость после захвата. `nil` — глушить было нечего,
    /// восстанавливать тоже нечего.
    static func restoreAfterCapture(_ saved: Int?) {
        guard let saved else { return }
        setVolume(saved)
        UserDefaults.standard.removeObject(forKey: pendingRestoreKey)
    }

    /// Вызывать один раз при старте приложения: если в прошлый сеанс мы заглушили
    /// звук и не успели вернуть (падение/принудительный выход), восстанавливаем.
    static func restorePendingIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: pendingRestoreKey) != nil else { return }
        let saved = defaults.integer(forKey: pendingRestoreKey)
        defaults.removeObject(forKey: pendingRestoreKey)
        if saved > 0 { setVolume(saved) }
    }

    // MARK: - Низкоуровневые операции

    /// Текущая громкость алерта (0...100), либо `nil`, если получить не удалось.
    static func currentVolume() -> Int? {
        guard let output = runOsascript("alert volume of (get volume settings)"),
              let value = Int(output) else {
            return nil
        }
        return value
    }

    static func setVolume(_ volume: Int) {
        let clamped = max(0, min(100, volume))
        runOsascript("set volume alert volume \(clamped)")
    }

    // MARK: - Исполнение osascript в подпроцессе

    /// Запускает `osascript -e <source>` и возвращает stdout (обрезанный), либо
    /// `nil` при ошибке/таймауте. Блокирует только вызывающий (фоновый) поток —
    /// главный поток не затрагивается.
    @discardableResult
    private static func runOsascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Watchdog: `osascript` не должен виснуть, но если завис — снимаем, чтобы
        // не задерживать захват. Терминирование закроет pipe и разблокирует чтение.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: watchdog)

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
