import Foundation

/// Захват слова у курсора (или активного выделения) и замена его на исправленный
/// вариант — порт `capture_last_word` / `select_word_by_whitespace` /
/// `get_active_selection` из Python-версии.
///
/// Вся работа идёт на отдельной последовательной очереди: последовательность
/// состоит из синтетических событий с паузами между ними (нужны, чтобы целевое
/// приложение успело обработать копирование/вставку), и блокировать ими главный
/// поток / run loop нельзя.
nonisolated final class TextCaptureService: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.eugenesalov.salteca.textcapture")

    // Состояние последней замены — общий store с авто-режимом (toggle: повторный
    // хоткей на уже исправленном слове возвращает исходный вариант; так же
    // хоткеем можно откатить и авто-правку).
    private let replacementStore: ReplacementStore

    init(replacementStore: ReplacementStore = ReplacementStore()) {
        self.replacementStore = replacementStore
    }

    // Читать ли выделение через буфер обмена вместо Accessibility. Взводится на
    // время одного захвата, если AX-текст в сфокусированном приложении недоступен.
    // Безопасно как обычное поле: captureAndReplace() всегда идёт последовательно
    // на `queue`.
    private var useClipboardFallback = false

    // MARK: - Константы

    private let whitespace: Set<Character> = [" ", "\t", "\n", "\r"]
    private let maxExtendSteps = 50
    private let copyRetryAttempts = 10
    /// Пауза после синтетической стрелки — чтобы приложение успело применить
    /// новое выделение до того, как мы его прочитаем (через AX или буфер).
    private let selectionSettle: TimeInterval = 0.02
    /// Пауза вокруг операций с буфером обмена (Cmd+C/Cmd+V).
    private let copySettle: TimeInterval = 0.05
    private let pasteSettle: TimeInterval = 0.1
    /// Потолок ожидания подтверждения смены раскладки (уведомление kTISNotify)
    /// перед проигрыванием звука — короткий failsafe, как в авто-режиме.
    private let layoutSwitchConfirmTimeout: TimeInterval = 0.3

    // MARK: - Точка входа (из хоткея)

    /// Вызывается из обработчика хоткея. Не блокирует вызывающий поток.
    func handleHotKey() {
        queue.async { [weak self] in
            self?.captureAndReplace()
        }
    }

    // MARK: - Основной сценарий

    private func captureAndReplace() {
        useClipboardFallback = false

        // Хоткей Cmd+Shift+X ещё зажат — дожидаемся отпускания, иначе Cmd+C
        // превратится в Cmd+Shift+C.
        SyntheticKeyboard.waitForModifiersReleased()

        // Глушим системный «бип» на время всей операции (стрелки у границы поля
        // и прочие необработанные синтетические нажатия). Работает через
        // подпроцесс osascript на этом же фоновом потоке — без main.sync и
        // NSAppleScript, поэтому не блокирует ни очередь захвата, ни главный run
        // loop. Восстановление гарантируем через defer.
        let savedAlertVolume = SystemAlertSound.muteForCapture()
        defer { SystemAlertSound.restoreAfterCapture(savedAlertVolume) }

        // Настоящий буфер обмена пользователя (пароли и т.п.) — сохраняем сейчас
        // и гарантированно возвращаем на выходе, что бы ни случилось.
        let originalClipboard = Clipboard.readString()
        defer {
            // Возвращаем пользователю его буфер, только если там был текст —
            // не затираем пустотой (не-текстовое содержимое всё равно потеряно
            // ещё на этапе записи sentinel; это ограничение и в Python-версии).
            if let originalClipboard { Clipboard.write(originalClipboard) }
        }

        let word: String
        let direction: LayoutDirection
        let fixed: String

        if let manual = getActiveSelection() {
            // Ручное выделение — конвертируем принудительно по преобладающему
            // алфавиту, без права «не трогать».
            guard let dir = LayoutDetector.dominantDirection(manual) else { return }
            word = manual
            direction = dir
            fixed = dir.apply(to: manual)
        } else {
            let selected = selectWordByWhitespace()
            guard !selected.isEmpty else { return }
            word = selected

            if let toggled = replacementStore.toggle(for: selected) {
                direction = toggled.direction
                fixed = toggled.fixed
            } else if let dir = LayoutDetector.guessDirection(selected) {
                direction = dir
                fixed = dir.apply(to: selected)
            } else {
                return
            }
        }

        replaceSelection(with: fixed)

        // Переключаем системную раскладку под исправленный текст и озвучиваем
        // ИМЕННО подтверждённое переключение (по уведомлению kTISNotify), а не
        // отправку команды — так же, как в авто-режиме. Ждём на этой фоновой
        // очереди (не на главном потоке). Уже целевая раскладка → тихий no-op.
        if LayoutSwitcher.switchLayoutConfirmed(to: direction, timeout: layoutSwitchConfirmTimeout) {
            SwitchSoundPlayer.shared.play()
        }

        replacementStore.record(original: word, fixed: fixed, direction: direction)
        print("\(word) -> \(fixed)")
    }

    // MARK: - Определение активного выделения

    /// Возвращает текст выделения, сделанного пользователем, либо `nil`, если
    /// выделения нет. На macOS Cmd+C без выделения — no-op, поэтому кладём в
    /// буфер уникальный «маячок» (sentinel): если после Cmd+C он остался на
    /// месте — копировать было нечего.
    private func getActiveSelection() -> String? {
        let sentinel = "__saltecla_sentinel_\(UUID().uuidString)__"
        Clipboard.write(sentinel)
        Thread.sleep(forTimeInterval: copySettle)

        var result = sentinel
        for _ in 0..<copyRetryAttempts {
            result = copySelection()
            if result != sentinel { break }
        }
        return result == sentinel ? nil : result
    }

    /// Читает текущее выделение при пошаговом поиске границы слова: сначала через
    /// Accessibility (беззвучно, мгновенно, без буфера обмена), с откатом на
    /// Cmd+C для приложений, которые AX-текст не отдают. Решение об откате
    /// принимается один раз за захват и дальше не меняется.
    private func readSelection() -> String {
        if !useClipboardFallback, let text = AccessibilityText.selectedText() {
            return text
        }
        useClipboardFallback = true
        return copySelection()
    }

    /// Cmd+C и чтение результата из буфера обмена.
    private func copySelection() -> String {
        SyntheticKeyboard.commandC()
        Thread.sleep(forTimeInterval: copySettle)
        return Clipboard.readString() ?? ""
    }

    // MARK: - Поиск «последнего слова» по пробельным границам

    /// Выделяет слово слева от курсора строго по пробельным границам. macOS
    /// считает границей слова любую пунктуацию (включая символы, попавшие в
    /// слово из-за неправильной раскладки), поэтому Option+Shift+Left мало —
    /// расширяем выделение и затем отдаём лишнее назад через Shift+Right.
    private func selectWordByWhitespace() -> String {
        skipLeadingWhitespace()

        var selected = ""
        for _ in 0..<maxExtendSteps {
            SyntheticKeyboard.optionShiftLeft()
            Thread.sleep(forTimeInterval: selectionSettle)

            let newSelected = readSelection()
            if newSelected == selected { break }  // упёрлись в начало поля
            selected = newSelected

            let core = selected.trimmingTrailing(whitespace)
            if !core.isEmpty && core.contains(where: { whitespace.contains($0) }) {
                break  // в выделение попал пробел — слово точно целиком внутри
            }
        }

        // Оставляем только последнее слово: лишние символы слева отдаём назад.
        let core = selected.trimmingTrailing(whitespace)
        let trimmed = core.split(whereSeparator: { whitespace.contains($0) }).last.map(String.init) ?? ""
        let extra = selected.count - trimmed.count
        if extra > 0 {
            for _ in 0..<extra { SyntheticKeyboard.shiftRight() }
            Thread.sleep(forTimeInterval: selectionSettle)
        }
        return trimmed
    }

    /// Пропускает пробел(ы) слева от курсора, сдвигая будущий якорь выделения за
    /// них — иначе Shift+Right в конце вместо пробела выкинул бы первую букву.
    private func skipLeadingWhitespace() {
        for _ in 0..<maxExtendSteps {
            SyntheticKeyboard.shiftLeft()
            Thread.sleep(forTimeInterval: selectionSettle)

            let ch = readSelection()
            if ch.count == 1, let c = ch.first, whitespace.contains(c) {
                // Это пробел — схлопываем выделение в левый край (якорь уходит
                // за пробел) и продолжаем.
                SyntheticKeyboard.left()
                Thread.sleep(forTimeInterval: selectionSettle)
                continue
            }
            // Не пробел (или начало поля) — возвращаем курсор на место.
            SyntheticKeyboard.right()
            Thread.sleep(forTimeInterval: selectionSettle)
            break
        }
    }

    // MARK: - Замена текста

    /// Выделение (ручное или собранное нами) всё ещё активно — печатаем поверх
    /// через буфер обмена (надёжнее прямого ввода для кириллицы/спецсимволов).
    /// Восстановление настоящего буфера пользователя делает `defer` в
    /// `captureAndReplace()`.
    private func replaceSelection(with fixed: String) {
        Clipboard.write(fixed)
        Thread.sleep(forTimeInterval: copySettle)
        SyntheticKeyboard.commandV()
        Thread.sleep(forTimeInterval: pasteSettle)
    }

}

private extension String {
    /// Отбрасывает хвостовые символы из набора (аналог `str.rstrip(chars)`).
    nonisolated func trimmingTrailing(_ chars: Set<Character>) -> String {
        var result = self
        while let last = result.last, chars.contains(last) {
            result.removeLast()
        }
        return result
    }
}
