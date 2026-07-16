import Foundation
import Carbon

/// Переключение системной раскладки клавиатуры на нужный алфавит через Carbon
/// Text Input Sources (TIS) API — порт `layout_switch.py`, но без ctypes:
/// функции и константы TIS доступны из `Carbon.HIToolbox` напрямую.
///
/// После исправления слова мы меняем раскладку под получившийся текст, чтобы
/// пользователь продолжал печатать в правильной раскладке.
nonisolated enum LayoutSwitcher {

    /// Целевой алфавит раскладки, на которую нужно переключиться.
    enum TargetScript {
        case russian
        case english
    }

    // MARK: - Публичный API

    /// Переключает системную раскладку под исправленный текст.
    ///
    /// `direction == .enToRu` значит «печатали по-русски в EN-раскладке» →
    /// результат русский → нужна русская раскладка (и наоборот). Если подходящая
    /// раскладка не установлена или переключение не удалось — тихий no-op, как и
    /// остальной код сервиса (без исключений и без звука).
    static func switchLayout(to direction: LayoutDirection) {
        let target: TargetScript = (direction == .enToRu) ? .russian : .english
        // TIS API (TISCreateInputSourceList / TISGetInputSourceProperty /
        // TISSelectInputSource) обязано вызываться с главного потока — иначе
        // dispatch_assert_queue_fail и краш. Сюда мы приходим с фоновой serial
        // queue TextCaptureService, поэтому весь поиск+переключение выполняем
        // одним хопом на main. (Та же проблема ловилась в Python-версии.)
        runOnMain {
            guard let source = findInputSource(for: target) else { return }
            TISSelectInputSource(source)
        }
    }

    /// Переключает раскладку и БЛОКИРУЕТ вызывающий поток, пока система реально
    /// не сменит её — подтверждение через распределённое уведомление
    /// `kTISNotifySelectedKeyboardInputSourceChanged` (тот же сигнал, что и в
    /// авто-режиме) — или пока не истечёт `timeout`. Возвращает `true` при
    /// подтверждённой смене, `false` по таймауту.
    ///
    /// Нужен хоткей-пути, чтобы сыграть звук ИМЕННО в момент подтверждённого
    /// переключения, а не при отправке команды. Если раскладка уже целевая —
    /// сразу `false` (переключать и озвучивать нечего).
    ///
    /// ВАЖНО: вызывать только с ФОНОВОЙ очереди. Распределённые уведомления
    /// доставляются на главный run loop, поэтому наблюдатель регистрируется на
    /// главном потоке, а блокироваться на семафоре главный поток не должен
    /// (иначе колбэк не придёт — дедлок).
    static func switchLayoutConfirmed(to direction: LayoutDirection,
                                      timeout: TimeInterval) -> Bool {
        if matchesCurrent(direction) { return false }
        let waiter = InputSourceChangeWaiter(target: direction)
        switchLayout(to: direction)
        return waiter.wait(timeout: timeout)
    }

    /// Уже ли активная системная раскладка соответствует `direction` (её целевому
    /// алфавиту)? Нужна авто-режиму, чтобы не гонять переключение и не ждать
    /// подтверждения, когда мы и так в нужной раскладке. TIS-опрос — на главном
    /// потоке (как и переключение).
    static func matchesCurrent(_ direction: LayoutDirection) -> Bool {
        let target: TargetScript = (direction == .enToRu) ? .russian : .english
        var result = false
        runOnMain {
            guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
            let id = stringProperty(current, kTISPropertyInputSourceID) ?? ""
            let name = stringProperty(current, kTISPropertyLocalizedName) ?? ""
            result = matchScript(id: id, name: name, target: target)
        }
        return result
    }

    /// Выполняет TIS-работу на главном потоке. `main.sync` здесь безопасен: в
    /// отличие от NSAppleScript, TIS-вызовы быстрые и не прокручивают run loop,
    /// так что взаимной блокировки с главным потоком не возникает. Если нас всё
    /// же вызвали уже с главного потока — выполняем напрямую, иначе `main.sync`
    /// на самого себя был бы дедлоком.
    private static func runOnMain(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    // MARK: - Чистая логика сопоставления (покрыта тестами)

    /// Подходит ли источник ввода (по его `id` и локализованному имени) под
    /// целевой алфавит.
    ///
    /// Ловушка: подстрока `"us"` встречается внутри `"russian"`, поэтому наивное
    /// `id.contains("us")` пометило бы русскую раскладку как английскую. Мы
    /// сначала определяем «русскость» и для английского берём её как стоп-фактор,
    /// а сам матчинг ведём по компоненту-идентификатору раскладки (часть id после
    /// последней точки: `com.apple.keylayout.US` → `us`), а не по всей строке —
    /// иначе `Belarusian` тоже поймался бы на `"us"`.
    static func matchScript(id: String, name: String, target: TargetScript) -> Bool {
        let idLower = id.lowercased()
        let nameLower = name.lowercased()
        let layoutID = idLower.split(separator: ".").last.map(String.init) ?? idLower

        let isRussian = layoutID.hasPrefix("russian")
            || nameLower.contains("русск")
            || nameLower.contains("russian")

        switch target {
        case .russian:
            return isRussian
        case .english:
            // Русская раскладка никогда не считается английской (ловушка "us").
            guard !isRussian else { return false }
            return isEnglishLayout(layoutID: layoutID, name: nameLower)
        }
    }

    private static let englishLayoutPrefixes = [
        "us", "abc", "british", "english", "australian", "canadian", "irish",
    ]

    private static func isEnglishLayout(layoutID: String, name: String) -> Bool {
        if englishLayoutPrefixes.contains(where: { layoutID.hasPrefix($0) }) { return true }
        return name.contains("english") || name.contains("англ")
    }

    // MARK: - Обход установленных раскладок (TIS)

    private static func findInputSource(for target: TargetScript) -> TISInputSource? {
        // `false` — только включённые у пользователя источники (не все установленные
        // в системе). Список retained — им владеем мы, освободит ARC.
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue(),
              let sources = list as? [TISInputSource] else {
            return nil
        }

        for source in sources {
            guard isSelectableKeyboard(source) else { continue }
            let id = stringProperty(source, kTISPropertyInputSourceID) ?? ""
            let name = stringProperty(source, kTISPropertyLocalizedName) ?? ""
            if matchScript(id: id, name: name, target: target) {
                return source
            }
        }
        return nil
    }

    /// Только клавиатурные раскладки, на которые действительно можно переключиться
    /// (отсекает палитры символов, эмодзи и т.п.).
    private static func isSelectableKeyboard(_ source: TISInputSource) -> Bool {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) {
            let category = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
            if !CFEqual(category, kTISCategoryKeyboardInputSource) { return false }
        }
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) {
            let selectable = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
            if !CFBooleanGetValue(selectable) { return false }
        }
        return true
    }

    /// Читает строковое свойство источника. Значение unretained — принадлежит
    /// источнику, освобождать его нельзя.
    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

/// Одноразовый ожидатель подтверждения смены раскладки через распределённое
/// уведомление `kTISNotifySelectedKeyboardInputSourceChanged`.
///
/// Наблюдатель регистрируется на ГЛАВНОМ потоке (туда доставляются
/// распределённые уведомления) и сигналит семафор, когда активной стала
/// целевая раскладка. Вызывающая фоновая очередь блокируется на `wait`, пока
/// не придёт подтверждение или не истечёт таймаут; наблюдатель снимается там же.
private final class InputSourceChangeWaiter {
    private let target: LayoutDirection
    private let semaphore = DispatchSemaphore(value: 0)

    init(target: LayoutDirection) {
        self.target = target
        let observer = Unmanaged.passUnretained(self).toOpaque()
        DispatchQueue.main.sync {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDistributedCenter(),
                observer,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let waiter = Unmanaged<InputSourceChangeWaiter>
                        .fromOpaque(observer).takeUnretainedValue()
                    // Чужие переключения (напр. Cmd+Space пользователем)
                    // игнорируем — сигналим только при смене на нашу цель.
                    if LayoutSwitcher.matchesCurrent(waiter.target) {
                        waiter.semaphore.signal()
                    }
                },
                kTISNotifySelectedKeyboardInputSourceChanged,
                nil,
                .deliverImmediately)
        }
    }

    /// Ждёт подтверждения до `timeout` и снимает наблюдатель. `true` —
    /// подтверждено, `false` — таймаут.
    func wait(timeout: TimeInterval) -> Bool {
        let result = semaphore.wait(timeout: .now() + timeout)
        let observer = Unmanaged.passUnretained(self).toOpaque()
        DispatchQueue.main.sync {
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDistributedCenter(), observer)
        }
        return result == .success
    }
}
