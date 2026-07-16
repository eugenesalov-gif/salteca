import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Направление исправления раскладки для слова, набранного по ошибке не в той
/// раскладке.
nonisolated enum LayoutDirection {
    /// Слово набрано в английской раскладке, хотя имелась в виду русская
    /// ("ghbdtn" -> "привет"). Результат исправления — русский текст.
    case enToRu
    /// Слово набрано в русской раскладке, хотя имелась в виду английская
    /// ("руддщ" -> "hello"). Результат исправления — английский текст.
    case ruToEn

    /// Применяет исправление к слову.
    ///
    /// Внимание: имена функций в `LayoutMapper` инвертированы относительно
    /// семантики этого enum'а — русский текст производит `LayoutMapper.ruToEn`,
    /// а английский — `LayoutMapper.enToRu` (так закреплено тестами маппера).
    /// Здесь эта инверсия инкапсулирована, чтобы вызывающий код о ней не думал.
    func apply(to word: String) -> String {
        switch self {
        case .enToRu: return LayoutMapper.ruToEn(word) // -> русский
        case .ruToEn: return LayoutMapper.enToRu(word) // -> английский
        }
    }

    /// Противоположное направление — для отката (toggle) уже применённой замены.
    var opposite: LayoutDirection {
        switch self {
        case .enToRu: return .ruToEn
        case .ruToEn: return .enToRu
        }
    }

    /// Набор гласных целевого (после исправления) алфавита — для проверки, что
    /// результат сам не превратился в бессмыслицу.
    fileprivate var targetVowels: Set<Character> {
        switch self {
        case .enToRu: return LayoutDetector.vowelsRU
        case .ruToEn: return LayoutDetector.vowelsEN
        }
    }

    /// Язык словарной проверки для результата исправления: `.enToRu` производит
    /// русский текст → "ru" (и наоборот).
    fileprivate var targetLanguage: String {
        switch self {
        case .enToRu: return "ru"
        case .ruToEn: return "en"
        }
    }
}

/// Определяет, нужно ли исправлять раскладку слова и в какую сторону.
nonisolated enum LayoutDetector {

    // MARK: - Константы

    static let vowelsEN: Set<Character> = Set("aeiouy")
    static let vowelsRU: Set<Character> = Set("аеёиоуыэюя")

    /// Буквы 'э,ё,х,ъ,ж,б,ю' при наборе в EN-раскладке дают ASCII-пунктуацию,
    /// а не букву: их нужно учитывать как полноценные буквы при подсчёте длины.
    static let latinMarkToRuLetter: [Character: Character] = [
        "'": "э", "`": "ё", "[": "х", "]": "ъ", ";": "ж", ",": "б", ".": "ю",
    ]

    /// '`' '[' ']' почти никогда не встречаются как настоящая пунктуация внутри
    /// слова (в отличие от ',' '.' ';' и "'") — надёжный сигнал «это буква».
    static let alwaysLetterMarks: Set<Character> = ["`", "[", "]"]

    /// ',' '.' ';' — самая частая настоящая пунктуация. Когда одна из них
    /// оказывается последним символом готового слова, нельзя сразу считать её
    /// буквой (х/ъ/… в EN-раскладке): это может быть и пунктуация после целого
    /// слова. Различаем в `autoCorrection(for:)`.
    static let ambiguousBoundaryMarks: Set<Character> = [",", ".", ";"]

    /// Порог длины серии согласных в результате, после которого исправление
    /// считается сделавшим слово бессмыслицей и откатывается.
    static let gibberishRunThreshold = 6

    /// Реальные ОДНОБУКВЕННЫЕ слова каждого языка. Нужны отдельно, потому что
    /// `NSSpellChecker` почти любую одиночную букву объявляет корректным словом
    /// (см. `isKnownWord`), из-за чего обычная словарная ветка на словах длины 1
    /// недетерминирована — её вердикт зависит от окружения. Для длины 1 решаем по
    /// этим спискам: детерминированно и переносимо (строчные формы).
    static let singleLetterWordsEN: Set<Character> = ["a", "i"]
    static let singleLetterWordsRU: Set<Character> = ["а", "и", "о", "у", "я", "в", "к", "с"]

    // MARK: - Публичный API

    /// Возвращает направление исправления, либо `nil`, если слово трогать не надо.
    static func guessDirection(_ word: String) -> LayoutDirection? {
        let letters = word.filter { $0.isLetter || latinMarkToRuLetter[$0] != nil }
        guard !letters.isEmpty else { return nil }

        // Смешанное кириллица+латиница в одном слове ("XcVзаметил") — конвертация
        // однонаправленная и тронет только «свою» половину, результат
        // гарантированно бессмыслица. Лучше не трогать, особенно в авто-режиме.
        if hasMixedScript(word) { return nil }

        // Однобуквенные слова решаем детерминированно, минуя ненадёжный на длине 1
        // спелчекер (урок про 'j': NSSpellChecker считает одиночную 'j' валидным
        // английским словом, из-за чего вердикт «трогать/не трогать» зависел от
        // окружения — тест и реальное приложение расходились).
        let alphaOnly = word.filter { $0.isLetter }
        if alphaOnly.count == 1, let ch = alphaOnly.lowercased().first {
            return singleLetterDirection(ch)
        }

        let enCount = letters.filter { LayoutMapper.EN_TO_RU_MAP[$0] != nil }.count
        let ruCount = letters.filter { LayoutMapper.RU_TO_EN_MAP[$0] != nil }.count

        // Только буквы (без марок-пунктуации) — то, что скармливаем чекеру
        // орфографии: 'э,ё,х,…' пунктуацию словарь всё равно не поймёт.
        let alphaCore = String(word.filter { $0.isLetter })

        let direction: LayoutDirection?
        if enCount >= ruCount {
            direction = directionForEnglishDominant(word: word, alphaCore: alphaCore)
        } else {
            direction = directionForRussianDominant(word: word, alphaCore: alphaCore)
        }

        guard let direction else { return nil }

        // Подстраховка: если результат сам выглядит как каша (длинная серия
        // согласных в целевом алфавите) — эвристика ошиблась направлением
        // ("асскладка" -> "fccrkflrf"). Лучше не трогать, чем заменить другой
        // бессмыслицей.
        let fixed = direction.apply(to: word)
        if maxConsonantRun(fixed, vowels: direction.targetVowels) >= gibberishRunThreshold {
            return nil
        }

        return direction
    }

    /// Направление ПРИНУДИТЕЛЬНО, по преобладающему алфавиту, без права сказать
    /// «не трогать». Для ручного выделения: пользователь сам выделил текст и
    /// явно просит конвертацию, поэтому словарная/gibberish-подстраховка не
    /// применяется (аналог `dominant_script_direction` в Python-версии).
    /// `nil` только если в слове вообще нет букв.
    static func dominantDirection(_ word: String) -> LayoutDirection? {
        let letters = word.filter { $0.isLetter || latinMarkToRuLetter[$0] != nil }
        guard !letters.isEmpty else { return nil }

        let enCount = letters.filter { LayoutMapper.EN_TO_RU_MAP[$0] != nil }.count
        let ruCount = letters.filter { LayoutMapper.RU_TO_EN_MAP[$0] != nil }.count
        return enCount >= ruCount ? .enToRu : .ruToEn
    }

    /// Итоговое решение авто-режима по завершённому слову: что и в какую сторону
    /// исправлять, либо `nil`, если трогать не надо (порт `handle_auto_boundary`
    /// без части планирования правки).
    ///
    /// Сверх `guessDirection` разбирает случай, когда слово оканчивается на
    /// неоднозначный знак ',' '.' ';' — он мог попасть туда двумя путями: как
    /// настоящая пунктуация после целого слова ("привет," → "ghbdtn,"), либо как
    /// истинная последняя буква слова, которая в EN-раскладке выглядит знаком
    /// ("хлеб" → "[kt,", где ',' это буква 'б'). Различаем по словарю: если
    /// «слово-без-знака» после исправления — реальное слово, знак это пунктуация;
    /// иначе он часть слова.
    static func autoCorrection(for word: String) -> (direction: LayoutDirection, fixed: String)? {
        // Гипотеза «знак — часть слова»: слово целиком.
        var direction = guessDirection(word)
        var fixed = direction?.apply(to: word)

        if let trailing = word.last, ambiguousBoundaryMarks.contains(trailing) {
            let core = String(word.dropLast())
            if let coreDirection = guessDirection(core) {
                let coreFixed = coreDirection.apply(to: core)
                // Разбор нужен, только если «слово-без-знака» само просит правки.
                if coreFixed != core {
                    if direction == nil || fixed == word {
                        // Целиком (знак как буква) правки не даёт — знак пунктуация.
                        direction = coreDirection
                        fixed = coreFixed + String(trailing)
                    } else if let fixedWhole = fixed, let wholeDirection = direction {
                        // Обе гипотезы дают правку — решаем словарём (с резервом
                        // по серии согласных, если словарь недоступен).
                        let preferCore: Bool
                        if let coreKnown = isKnownWord(coreFixed, language: coreDirection.targetLanguage) {
                            preferCore = coreKnown
                        } else {
                            let runCore = maxConsonantRun(coreFixed, vowels: coreDirection.targetVowels)
                            let runWhole = maxConsonantRun(fixedWhole, vowels: wholeDirection.targetVowels)
                            preferCore = runCore < runWhole
                        }
                        if preferCore {
                            direction = coreDirection
                            fixed = coreFixed + String(trailing)
                        }
                        // иначе оставляем гипотезу «целиком» (fixed уже со знаком)
                    }
                }
            }
        }

        // Менять нечего, либо конверсия — no-op: не гоняем backspace/paste впустую.
        guard let direction, let fixed, fixed != word else { return nil }
        return (direction, fixed)
    }

    /// Детерминированное решение для слова из одной буквы (`ch` — строчная).
    /// Симметрично общей эвристике `convertedIsKnownWord`, но по явным спискам
    /// однобуквенных слов вместо спелчекера: букву трогаем, только если она сама
    /// НЕ реальное однобуквенное слово в своём языке, а её раскладочная пара —
    /// реальное однобуквенное слово в другом ("j" -> "о", но "a"/"i" не трогаем).
    private static func singleLetterDirection(_ ch: Character) -> LayoutDirection? {
        if LayoutMapper.EN_TO_RU_MAP[ch] != nil {
            if singleLetterWordsEN.contains(ch) { return nil }  // реальное англ. слово ('a','i')
            let ru = LayoutDirection.enToRu.apply(to: String(ch))
            let isRuWord = ru.lowercased().first.map(singleLetterWordsRU.contains) ?? false
            return isRuWord ? .enToRu : nil
        }
        if LayoutMapper.RU_TO_EN_MAP[ch] != nil {
            if singleLetterWordsRU.contains(ch) { return nil }  // реальное рус. слово
            let en = LayoutDirection.ruToEn.apply(to: String(ch))
            let isEnWord = en.lowercased().first.map(singleLetterWordsEN.contains) ?? false
            return isEnWord ? .ruToEn : nil
        }
        return nil
    }

    // MARK: - Ветки по преобладающему алфавиту

    private static func directionForEnglishDominant(word: String, alphaCore: String) -> LayoutDirection? {
        // Символы "`"/"["/"]" (или "'" в начале слова) почти никогда не бывают
        // у настоящего английского текста — надёжный сигнал «это буква».
        let trustAsLetters = word.first == "'" || word.contains(where: { alwaysLetterMarks.contains($0) })
        if trustAsLetters { return .enToRu }

        switch isKnownWord(alphaCore, language: "en") {
        case .some(true):
            // Реальное английское слово — трогать не надо.
            return nil
        case .some(false):
            // Не английское слово — это либо русский, набранный в EN-раскладке
            // (тогда конверсия даст реальное русское слово), либо просто опечатка
            // в английском (тогда конверсия — кириллический мусор). Конвертируем
            // ТОЛЬКО если результат сам — известное русское слово; иначе не трогаем:
            // опечатку в родном языке эвристика портить не должна.
            return convertedIsKnownWord(word, direction: .enToRu, language: "ru") ? .enToRu : nil
        case .none:
            // Чекер недоступен — без надёжного сигнала слово не трогаем.
            return nil
        }
    }

    private static func directionForRussianDominant(word: String, alphaCore: String) -> LayoutDirection? {
        switch isKnownWord(alphaCore, language: "ru") {
        case .some(true):
            // Реальное русское слово — трогать не надо.
            return nil
        case .some(false):
            // Симметрично английской ветке: конвертируем, только если результат —
            // известное английское слово (настоящая ошибка раскладки, "руддщ" ->
            // "hello"); иначе это опечатка в русском ("булое"), а не раскладка —
            // не трогаем.
            return convertedIsKnownWord(word, direction: .ruToEn, language: "en") ? .ruToEn : nil
        case .none:
            return nil
        }
    }

    /// Является ли результат исправления `word` в заданном направлении реальным
    /// словом целевого языка (проверяем по буквенному ядру — пунктуацию словарь
    /// не поймёт). Если словарь недоступен или это не слово — `false`
    /// (консервативно: без подтверждения раскладку не трогаем).
    private static func convertedIsKnownWord(_ word: String, direction: LayoutDirection, language: String) -> Bool {
        let fixed = direction.apply(to: word)
        let core = String(fixed.filter { $0.isLetter })
        return isKnownWord(core, language: language) == true
    }

    // MARK: - Вспомогательные функции

    /// Слово содержит буквы обоих алфавитов сразу?
    private static func hasMixedScript(_ word: String) -> Bool {
        let hasRU = word.contains { LayoutMapper.RU_TO_EN_MAP[$0] != nil }
        let hasEN = word.contains { LayoutMapper.EN_TO_RU_MAP[$0] != nil }
        return hasRU && hasEN
    }

    /// Максимальная длина непрерывной серии согласных (небуквы серию обрывают).
    private static func maxConsonantRun(_ word: String, vowels: Set<Character>) -> Int {
        var maxRun = 0
        var run = 0
        for ch in word.lowercased() {
            if ch.isLetter && !vowels.contains(ch) {
                run += 1
                maxRun = max(maxRun, run)
            } else {
                run = 0
            }
        }
        return maxRun
    }

    /// Проверяет слово по системному словарю орфографии.
    ///
    /// Возвращает `nil`, если сигнал недоступен (нет AppKit / пустое слово) —
    /// вызывающий код трактует это как «нет данных», а не как `false`.
    private static func isKnownWord(_ word: String, language: String) -> Bool? {
        guard !word.isEmpty else { return nil }
        #if canImport(AppKit)
        let checker = NSSpellChecker.shared
        // Обязательно: иначе чекер сам гадает язык и на коротких ASCII-фрагментах
        // вроде "creifq" даёт неверные результаты.
        checker.automaticallyIdentifiesLanguages = false
        checker.setLanguage(language)
        let range = checker.checkSpelling(of: word, startingAt: 0)
        return range.length == 0
        #else
        return nil
        #endif
    }
}
