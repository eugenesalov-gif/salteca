import Foundation

/// Таблицы соответствия символов между английской (QWERTY) и русской (ЙЦУКЕН)
/// раскладками клавиатуры по физическому расположению клавиш.
nonisolated enum LayoutMapper {

    /// Английская буква/символ -> русская буква (нижний регистр).
    static let enToRuLowercase: [Character: Character] = [
        "`": "ё",
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е",
        "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з",
        "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п",
        "h": "р", "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и",
        "n": "т", "m": "ь", ",": "б", ".": "ю", "/": "."
    ]

    /// Английская буква/символ -> русская буква (верхний регистр).
    ///
    /// Только для клавиш с настоящей заглавной формой (буквы). Знаки пунктуации
    /// (`[ ] ; ' , . \``) заглавной формы не имеют — `"[".uppercased()` это по-
    /// прежнему `"["`, и без явного пропуска такая запись затирала бы строчный
    /// вариант заглавной русской буквой ('[' -> 'Х' вместо 'х').
    static let enToRuUppercase: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (en, ru) in enToRuLowercase {
            guard let enUpper = en.uppercased().first,
                  let ruUpper = ru.uppercased().first,
                  enUpper != en else { continue }
            map[enUpper] = ruUpper
        }
        return map
    }()

    /// Полная карта EN -> RU (строчные и заглавные символы).
    static let EN_TO_RU_MAP: [Character: Character] = enToRuLowercase.merging(enToRuUppercase) { _, new in new }

    /// Полная карта RU -> EN (строчные и заглавные символы), обратная к EN_TO_RU_MAP.
    static let RU_TO_EN_MAP: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (en, ru) in EN_TO_RU_MAP {
            map[ru] = en
        }
        return map
    }()

    /// Восстанавливает русский текст, набранный по ошибке в английской раскладке
    /// (например "ghbdtn" -> "привет"), посимвольно, сохраняя регистр.
    static func ruToEn(_ text: String) -> String {
        String(text.map { EN_TO_RU_MAP[$0] ?? $0 })
    }

    /// Восстанавливает английский текст, набранный по ошибке в русской раскладке
    /// (например "привет" -> "ghbdtn"), посимвольно, сохраняя регистр.
    static func enToRu(_ text: String) -> String {
        String(text.map { RU_TO_EN_MAP[$0] ?? $0 })
    }
}
