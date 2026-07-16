import Foundation

/// Чистое ядро авто-режима: конечный автомат «поток нажатий → правки».
///
/// Никакого I/O, таймеров, event tap или смены раскладки — всё это делает
/// `AutoModeService`. Вынесено ради детерминированных тестов: один и тот же
/// поток `KeyInput` всегда даёт один и тот же список `Correction`.
///
/// Модель: `handle` копит буквы, а на границе слова СРАЗУ возвращает готовую
/// правку (если слово корректируемое). Механизма `extra`/отложенного применения
/// здесь больше нет — «заморозку» документа на время правки обеспечивает
/// подавление ввода в `AutoModeService` (см. его комментарий).
nonisolated final class AutoModeEngine {

    // MARK: - Типы

    enum KeyInput: Equatable {
        case character(Character)   // печатный символ (буква слова или ASCII-граница)
        case space
        case enter
        case tab
        case backspace
        case ignored                // стрелки, модификаторы, функц. клавиши

        /// Символ, попадающий в буфер/слово (nil для backspace/ignored).
        var character: Character? {
            switch self {
            case .character(let c): return c
            case .space: return " "
            case .enter: return "\n"
            case .tab: return "\t"
            case .backspace, .ignored: return nil
            }
        }

        /// Клавиша, влияющая на текст/позицию курсора (её нужно подавлять на время
        /// физической правки). `.ignored` (стрелки, модификаторы) сюда не входит.
        var isTextKey: Bool {
            switch self {
            case .character, .space, .enter, .tab, .backspace: return true
            case .ignored: return false
            }
        }
    }

    /// Граница, завершившая слово (нужна, чтобы вернуть её после правки).
    enum Boundary: Equatable {
        case space
        case enter
        case tab
        case character(Character)
    }

    /// Готовая к применению правка (без `extra` — документ на время правки
    /// заморожен подавлением).
    struct Correction: Equatable {
        let word: String
        let fixed: String
        let direction: LayoutDirection
        let boundary: Boundary
    }

    /// Результат обработки одного нажатия.
    enum Output: Equatable {
        case none                               // символ накоплен / backspace / ignored
        case corrected(Correction)              // граница завершила корректируемое слово
        case raw(word: String, boundary: Boundary)  // граница завершила НЕкорректируемое слово
    }

    // MARK: - Состояние

    private let boundaryChars: Set<Character>
    private var buffer: [Character] = []

    /// '[' ']' ',' '.' ';' сюда НАМЕРЕННО не входят: это ASCII-вид букв х/ъ/б/ю/ж
    /// в EN-раскладке — считать их границей значит рвать слово (урок №1).
    init(boundaryChars: Set<Character> = [" ", "\t", "\n", "!", "?", "(", ")", "{", "}", "\""]) {
        self.boundaryChars = boundaryChars
    }

    /// Нет незавершённого слова в буфере — можно безопасно переключать раскладку.
    var isIdle: Bool { buffer.isEmpty }

    /// Текущий незавершённый «хвост» слова (сырые накопленные символы). Нужен
    /// сервису, чтобы показать его при завершении сессии подавления.
    var bufferedText: String { String(buffer) }

    // MARK: - Обработка

    /// Обрабатывает нажатие. На границе слова возвращает `.corrected` (слово
    /// корректируемое) или `.raw` (нет); иначе `.none` (символ накоплен /
    /// backspace / ignored).
    func handle(_ key: KeyInput) -> Output {
        if case .backspace = key {
            if !buffer.isEmpty { buffer.removeLast() }
            return .none
        }
        guard let ch = key.character else { return .none }  // ignored-клавиши

        if isBoundary(key) {
            let word = String(buffer)
            buffer.removeAll()
            guard !word.isEmpty else { return .none }
            // autoCorrection включает разбор хвостового ,/./; (урок №2) и проверку
            // fixed == word (урок №6).
            if let result = LayoutDetector.autoCorrection(for: word) {
                return .corrected(Correction(word: word, fixed: result.fixed,
                                             direction: result.direction, boundary: boundary(from: key)))
            }
            return .raw(word: word, boundary: boundary(from: key))
        }

        buffer.append(ch)
        return .none
    }

    // MARK: - Внутреннее

    private func isBoundary(_ key: KeyInput) -> Bool {
        switch key {
        case .space, .enter, .tab: return true
        case .character(let c): return boundaryChars.contains(c)
        case .backspace, .ignored: return false
        }
    }

    private func boundary(from key: KeyInput) -> Boundary {
        switch key {
        case .space: return .space
        case .enter: return .enter
        case .tab: return .tab
        case .character(let c): return .character(c)
        case .backspace, .ignored: return .space  // недостижимо: isBoundary отсеял
        }
    }
}
