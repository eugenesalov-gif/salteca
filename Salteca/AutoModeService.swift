import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// Автоматический режим (без хоткея): следит за вводом в фоне и, когда слово
/// завершено (пробел/Enter/пунктуация), исправляет неверную раскладку на лету.
///
/// Тонкий адаптер вокруг чистого `AutoModeEngine`: здесь только внешние эффекты
/// и планирование.
///
/// # Модель «документ заморожен на время правки»
/// Backspace/paste физически меняют документ ~0.3с. Всё это время реальные
/// нажатия пользователя нельзя пускать в документ — иначе они смешиваются с
/// правкой (лишние/потерянные символы, неверная сегментация). Поэтому с момента,
/// как движок вернул правку, tap ПОДАВЛЯЕТ текстовый ввод (`isApplying`) и
/// складывает его в `swallowedKeys`, а «сессия правки» на applyQueue:
/// 1. применяет правку (backspace слова+границы, paste, ретайп границы);
/// 2. затем по одному «дотипливает» отложенные нажатия (в правильную позицию,
///    после исправленного слова) и прогоняет через движок — если среди них снова
///    завершается корректируемое слово, применяет каскадную правку тут же;
/// 3. снимает подавление, только когда очередь отложенного ввода пуста.
/// Так документ и модель движка всегда совпадают, а сегментация слов не зависит
/// от таймингов. Механизма `extra` больше нет.
///
/// Свои синтетические события отсекаются меткой `SyntheticKeyboard`.
nonisolated final class AutoModeService: @unchecked Sendable {

    // MARK: - Зависимости

    private let replacementStore: ReplacementStore
    private let engine = AutoModeEngine()

    init(replacementStore: ReplacementStore) {
        self.replacementStore = replacementStore
    }

    // MARK: - Инфраструктура event tap

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    // MARK: - Очереди

    private let logicQueue = DispatchQueue(label: "com.eugenesalov.salteca.auto.logic")
    private let applyQueue = DispatchQueue(label: "com.eugenesalov.salteca.auto.apply")

    // MARK: - Переключение раскладки внутри окна подавления

    /// Раскладку переключаем СРАЗУ после каждого исправленного слова — внутри той
    /// же подавляемой секции, что и правка текста (`isApplying`), — и держим
    /// подавление, пока система реально не сменит раскладку. «Реально сменила» —
    /// это распределённое уведомление `kTISNotifySelectedKeyboardInputSourceChanged`
    /// (а не таймер): нажатия пользователя не попадают в неоднозначный момент
    /// незавершённого переключения, из-за которого tap мисчитал символы. Раньше
    /// здесь ждали 0.5с тишины — теперь ждать паузу не нужно.
    ///
    /// `layoutSwitchTarget`/`Semaphore` пишутся с applyQueue и читаются из колбэка
    /// уведомления (главный поток) — под `applyLock`.
    private var layoutSwitchTarget: LayoutDirection?
    private var layoutSwitchSemaphore: DispatchSemaphore?
    /// Потолок ожидания подтверждения смены раскладки (failsafe, если уведомление
    /// не пришло) — короткий, т.к. подавление всё это время держит ввод.
    private let layoutSwitchConfirmTimeout: TimeInterval = 0.3

    // MARK: - Подавление ввода на время правки

    /// `isApplying`/`swallowedKeys`/`applyWatchdog` читаются из потока tap'а и
    /// пишутся с applyQueue/logicQueue — под общим локом.
    private let applyLock = NSLock()
    private var isApplying = false
    private var swallowedKeys: [AutoModeEngine.KeyInput] = []
    private var applyWatchdog: DispatchWorkItem?

    // MARK: - Тайминги

    /// Небольшая пауза перед backspace — дать границе/слову «осесть» в целевом
    /// приложении (сокращённый settle: конкуренцию с вводом держит подавление).
    private let correctionDelay: TimeInterval = 0.05
    private let afterBackspaceSettle: TimeInterval = 0.03
    private let copySettle: TimeInterval = 0.05
    private let pasteSettle: TimeInterval = 0.1
    /// Тишина, после которой сессия показывает «хвост» текущего слова и
    /// завершается. Достаточно велика, чтобы не срабатывать между нажатиями при
    /// непрерывном наборе.
    private let sessionIdleDelay: TimeInterval = 0.1
    /// Жёсткий потолок на ОДНУ операцию сессии (перезаводится на каждом шаге).
    /// Срабатывает только при реальном зависании — снимает подавление, чтобы
    /// клавиатура не «залипла». Легитимно долгая сессия его не достигает.
    private let applyWatchdogTimeout: TimeInterval = 2.0

    // MARK: - Запуск / остановка

    func start() {
        guard tapThread == nil else { return }
        registerLayoutObserver()
        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = "com.eugenesalov.salteca.auto.tap"
        tapThread = thread
        thread.start()
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let tapRunLoop { CFRunLoopStop(tapRunLoop) }
        unregisterLayoutObserver()
        cancelWatchdog()
        forceReleaseSuppression()
        tapThread = nil
    }

    deinit { stop() }

    // MARK: - Event tap

    private func runTapLoop() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<AutoModeService>.fromOpaque(userInfo).takeUnretainedValue()
            return service.handleTapEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Активный tap: на время правки нужно ПОДАВЛЯТЬ ввод (возвращать nil).
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Авто-режим: не удалось создать CGEventTap (нет доступа Accessibility?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        tapRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("✅ Авто-режим: слушаю ввод, исправляю раскладку по мере набора")

        CFRunLoopRun()
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // Свои синтетические события — пропускаем (урок №4).
        if SyntheticKeyboard.isSynthetic(event) { return Unmanaged.passUnretained(event) }

        // Cmd/Control — шорткаты, не текст: не берём и не подавляем.
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return Unmanaged.passUnretained(event)
        }

        let key = classify(event: event)

        // Идёт правка — подавляем текстовый ввод и запоминаем для реплея.
        if key.isTextKey {
            applyLock.lock()
            if isApplying {
                swallowedKeys.append(key)
                applyLock.unlock()
                return nil
            }
            applyLock.unlock()
        }

        logicQueue.async { [weak self] in self?.handleKey(key) }
        return Unmanaged.passUnretained(event)
    }

    private func classify(event: CGEvent) -> AutoModeEngine.KeyInput {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Space: return .space
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Tab: return .tab
        case kVK_Delete: return .backspace
        default: break
        }

        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        guard length > 0 else { return .ignored }
        let produced = String(utf16CodeUnits: buffer, count: length)
        guard let ch = produced.first, let scalar = ch.unicodeScalars.first else { return .ignored }

        if (0xF700...0xF8FF).contains(scalar.value) { return .ignored }  // функц. клавиши
        if scalar.value < 0x20 { return .ignored }                       // упр. символы
        return .character(ch)
    }

    // MARK: - Логика (logicQueue)

    /// Штатный путь (вне сессии подавления): прогоняем через движок; если
    /// завершилось корректируемое слово — включаем подавление и запускаем сессию.
    private func handleKey(_ key: AutoModeEngine.KeyInput) {
        switch engine.handle(key) {
        case .corrected(let correction):
            beginSuppressing()
            applyQueue.async { [weak self] in self?.runSession(correction) }
        case .raw, .none:
            // Слово уже в документе как набрал пользователь — трогать не нужно;
            // раскладку переключаем только по факту исправления (в сессии).
            break
        }
    }

    // MARK: - Переключение раскладки, подтверждаемое уведомлением (applyQueue)

    /// Переключает раскладку под `direction` и БЛОКИРУЕТ (на applyQueue), пока
    /// система реально не сменит её (уведомление) или не истечёт короткий таймаут.
    /// Всё это время подавление ввода держится — нажатия пользователя копятся в
    /// `swallowedKeys` и не попадают в неоднозначный момент переключения.
    /// No-op, если текущая раскладка уже целевая (не гоняем впустую и не ждём).
    private func switchLayoutSuppressed(_ direction: LayoutDirection) {
        if LayoutSwitcher.matchesCurrent(direction) { return }

        let semaphore = DispatchSemaphore(value: 0)
        applyLock.lock()
        layoutSwitchTarget = direction
        layoutSwitchSemaphore = semaphore
        applyLock.unlock()

        LayoutSwitcher.switchLayout(to: direction)
        _ = semaphore.wait(timeout: .now() + layoutSwitchConfirmTimeout)

        applyLock.lock()
        layoutSwitchTarget = nil
        layoutSwitchSemaphore = nil
        applyLock.unlock()
    }

    /// Колбэк распределённого уведомления о смене выбранного источника ввода
    /// (главный поток). Сигналим ожидающую сессию, только если сменилось на нашу
    /// цель — чужие переключения (Cmd+Space пользователем) игнорируем.
    private func handleInputSourceChanged() {
        applyLock.lock()
        let target = layoutSwitchTarget
        let semaphore = layoutSwitchSemaphore
        applyLock.unlock()
        guard let target else { return }
        if LayoutSwitcher.matchesCurrent(target) {
            semaphore?.signal()
            // Подтверждённое переключение на нашу цель — тот же момент, где мы
            // снимаем подавление. Озвучиваем именно здесь (не при отправке
            // команды). No-op-случай (раскладка уже была целевой) сюда не
            // доходит: там `layoutSwitchTarget` не выставляется.
            SwitchSoundPlayer.shared.play()
        }
    }

    private func registerLayoutObserver() {
        let center = CFNotificationCenterGetDistributedCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let service = Unmanaged<AutoModeService>.fromOpaque(observer).takeUnretainedValue()
            service.handleInputSourceChanged()
        }, kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
    }

    private func unregisterLayoutObserver() {
        let center = CFNotificationCenterGetDistributedCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(center, observer)
    }

    // MARK: - Сессия правки (applyQueue)

    /// Применяет исходную правку, затем «проигрывает» подавленный ввод.
    ///
    /// Ключевой инвариант: физический `backspace` делается ТОЛЬКО по тексту,
    /// который реально «осел» в документе (слово, набранное пользователем, или
    /// «хвост», показанный ранее после паузы). Корректируемое слово во время
    /// сессии сырьём НЕ печатается — сразу вставляется исправленный вариант.
    /// Так исключена гонка «впрыснуть сырьё → мгновенно стереть» (терялись
    /// события → пропадали пробелы/буквы).
    ///
    /// `flushedLen` — сколько сырых символов ТЕКУЩЕГО (ещё не завершённого) слова
    /// уже показано в документе (при завершении сессии по паузе). Обнуляется,
    /// когда слово завершено.
    ///
    /// Надёжность сброса `isApplying`: (1) watchdog на каждом шаге; (2) defer;
    /// (3) штатно по опустошению очереди. Клавиатура «залипнуть» не может.
    private func runSession(_ initial: AutoModeEngine.Correction) {
        defer {
            cancelWatchdog()
            forceReleaseSuppression()  // failsafe
        }

        armWatchdog()
        // Исходное слово набрано пользователем и целиком в документе (слово+граница).
        applyCorrectedWord(initial, rawInDocLen: initial.word.count, boundaryInDoc: true)
        switchLayoutSuppressed(initial.direction)

        var flushedLen = 0
        while true {
            armWatchdog()

            applyLock.lock()
            if swallowedKeys.isEmpty {
                applyLock.unlock()
                // Пользователь мог остановиться — ждём и, если тишина сохранилась,
                // показываем «хвост» текущего слова сырьём и завершаем сессию.
                Thread.sleep(forTimeInterval: sessionIdleDelay)
                applyLock.lock()
                if swallowedKeys.isEmpty {
                    applyLock.unlock()
                    flushedLen = flushTail(alreadyShown: flushedLen)
                    applyLock.lock()
                    if swallowedKeys.isEmpty {
                        isApplying = false
                        applyLock.unlock()
                        return
                    }
                    applyLock.unlock()
                    continue  // ввод появился во время показа «хвоста» — продолжаем
                }
                applyLock.unlock()
                continue
            }
            let key = swallowedKeys.removeFirst()
            applyLock.unlock()

            switch syncHandle(key) {
            case .corrected(let c):
                // Сырьё этого слова в документе — только то, что уже показано
                // (flushedLen); границы в документе нет (её ставим сами).
                applyCorrectedWord(c, rawInDocLen: flushedLen, boundaryInDoc: false)
                switchLayoutSuppressed(c.direction)
                flushedLen = 0
            case .raw(let word, let boundary):
                // Некорректируемое слово: показываем непоказанный «хвост» + границу.
                if flushedLen < word.count {
                    SyntheticKeyboard.type(String(Array(word)[flushedLen...]))
                }
                typeBoundary(boundary)
                flushedLen = 0
            case .none:
                break  // символ накоплен в движке, покажется при flush/завершении слова
            }
        }
    }

    /// Показывает ещё не показанный «хвост» текущего слова (сырьём) и возвращает
    /// новое число показанных символов.
    private func flushTail(alreadyShown: Int) -> Int {
        let buffered = bufferedText()
        guard alreadyShown < buffered.count else { return alreadyShown }
        SyntheticKeyboard.type(String(Array(buffered)[alreadyShown...]))
        return buffered.count
    }

    /// Прогоняет подавленное нажатие через движок на logicQueue (синхронно, в
    /// порядке). Переключение раскладки инициирует сама сессия по факту правки
    /// (`switchLayoutSuppressed`), поэтому здесь только вызов движка.
    private func syncHandle(_ key: AutoModeEngine.KeyInput) -> AutoModeEngine.Output {
        var output: AutoModeEngine.Output = .none
        logicQueue.sync {
            output = engine.handle(key)
        }
        return output
    }

    private func bufferedText() -> String {
        var text = ""
        logicQueue.sync { text = engine.bufferedText }
        return text
    }

    /// Вставляет исправленный вариант слова. Стирает `rawInDocLen` уже показанных
    /// сырых символов (+границу, если она в документе) — ВСЕГДА по «осевшему»
    /// тексту, — затем вставляет `fixed` и печатает границу.
    private func applyCorrectedWord(_ c: AutoModeEngine.Correction, rawInDocLen: Int, boundaryInDoc: Bool) {
        Thread.sleep(forTimeInterval: correctionDelay)  // дать тексту «осесть»

        let deleteCount = rawInDocLen + (boundaryInDoc ? 1 : 0)
        if deleteCount > 0 {
            for _ in 0..<deleteCount { SyntheticKeyboard.backspace() }
            Thread.sleep(forTimeInterval: afterBackspaceSettle)
        }

        // Вставляем исправление через буфер, сохраняя буфер пользователя (урок №5).
        // Восстановление гарантируем через defer, симметрично хоткей-пути в
        // TextCaptureService: настоящий (текстовый) буфер пользователя вернётся,
        // что бы ни случилось. Не-текстовое/пустое содержимое восстановить нечем
        // (readString даёт nil) — там останется наш временный текст, как и в
        // хоткей-пути; это осознанное ограничение.
        let clipboardBackup = Clipboard.readString()
        defer { if let clipboardBackup { Clipboard.write(clipboardBackup) } }
        Clipboard.write(c.fixed)
        Thread.sleep(forTimeInterval: copySettle)
        // Границей корректируемого слова мог быть знак, набираемый с Shift ('?' =
        // Shift+/, '!' = Shift+1). Если пользователь ещё удерживает Shift в момент
        // Cmd+V, система видит Cmd+Shift+V ("Вставить и согласовать стиль" / no-op)
        // и вставка ломается — итоговый текст выходит не тем. Ждём отпускания
        // модификаторов, как и в хоткей-пути перед Cmd+C.
        SyntheticKeyboard.waitForModifiersReleased()
        SyntheticKeyboard.commandV()
        Thread.sleep(forTimeInterval: pasteSettle)

        typeBoundary(c.boundary)

        replacementStore.record(original: c.word, fixed: c.fixed, direction: c.direction)
        #if DEBUG
        print("[auto] \(c.word) -> \(c.fixed)")
        #endif
    }

    private func typeBoundary(_ boundary: AutoModeEngine.Boundary) {
        switch boundary {
        case .space: SyntheticKeyboard.tap(kVK_Space)
        case .enter: SyntheticKeyboard.tap(kVK_Return)
        case .tab: SyntheticKeyboard.tap(kVK_Tab)
        case .character(let ch): SyntheticKeyboard.type(String(ch))
        }
    }

    // MARK: - Управление подавлением

    private func beginSuppressing() {
        applyLock.lock()
        isApplying = true
        applyLock.unlock()
        armWatchdog()  // покрывает и зазор до старта сессии на applyQueue
    }

    private func currentlyApplying() -> Bool {
        applyLock.lock(); defer { applyLock.unlock() }
        return isApplying
    }

    private func armWatchdog() {
        let watchdog = DispatchWorkItem { [weak self] in self?.forceReleaseSuppression() }
        applyLock.lock()
        applyWatchdog?.cancel()
        applyWatchdog = watchdog
        applyLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + applyWatchdogTimeout, execute: watchdog)
    }

    private func cancelWatchdog() {
        applyLock.lock()
        applyWatchdog?.cancel()
        applyWatchdog = nil
        applyLock.unlock()
    }

    /// Жёсткий сброс подавления (watchdog / failsafe в defer / stop). Отложенный
    /// ввод при форс-сбросе отбрасываем — приоритет в том, чтобы клавиатура не
    /// залипла. Идемпотентно.
    private func forceReleaseSuppression() {
        applyLock.lock()
        isApplying = false
        swallowedKeys.removeAll()
        // Разблокируем сессию, если она сейчас ждёт подтверждения смены раскладки
        // (иначе при stop() applyQueue провисел бы до таймаута).
        layoutSwitchSemaphore?.signal()
        applyLock.unlock()
    }
}
