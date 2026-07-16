import XCTest
@testable import Salteca

final class AutoModeEngineTests: XCTestCase {

    /// Прогоняет поток нажатий через движок, собирая только `.corrected`-правки.
    private func run(_ keys: [AutoModeEngine.KeyInput],
                     engine: AutoModeEngine = AutoModeEngine()) -> [AutoModeEngine.Correction] {
        var corrections: [AutoModeEngine.Correction] = []
        for key in keys {
            if case .corrected(let correction) = engine.handle(key) { corrections.append(correction) }
        }
        return corrections
    }

    private func typing(_ text: String) -> [AutoModeEngine.KeyInput] {
        text.map { .character($0) }
    }

    // MARK: - Базовая правка

    func testSingleWordCorrection() {
        let result = run(typing("ghbdtn") + [.space])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.word, "ghbdtn")
        XCTAssertEqual(result.first?.fixed, "привет")
        XCTAssertEqual(result.first?.direction, .enToRu)
        XCTAssertEqual(result.first?.boundary, .space)
    }

    func testNoCorrectionUntilBoundary() {
        // Без границы слово не завершено — правки нет.
        XCTAssertTrue(run(typing("ghbdtn")).isEmpty)
    }

    func testRealWordProducesNoCorrection() {
        XCTAssertTrue(run(typing("hello") + [.space]).isEmpty)
    }

    func testNativeTypoProducesNoCorrection() {
        // «булое» — опечатка в русском, не ошибка раскладки.
        XCTAssertTrue(run(typing("булое") + [.space]).isEmpty)
    }

    func testPunctuationBoundary() {
        // Небуквенная граница (например '!') тоже завершает слово.
        let result = run(typing("ghbdtn") + [.character("!")])
        XCTAssertEqual(result.first?.fixed, "привет")
        XCTAssertEqual(result.first?.boundary, .character("!"))
    }

    // MARK: - Однобуквенные слова (баг из отчёта: "j?" -> "о?")

    /// "j" + '?': 'j' -> 'о' (реальное рус. однобукв. слово), граница '?' сохранена.
    /// Теперь ДЕТЕРМИНИРОВАННО (по спискам LayoutDetector, минуя спелчекер).
    func testSingleLetterJWithQuestionMark() {
        let result = run(typing("j") + [.character("?")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.word, "j")
        XCTAssertEqual(result.first?.fixed, "о")
        XCTAssertEqual(result.first?.direction, .enToRu)
        XCTAssertEqual(result.first?.boundary, .character("?"))
    }

    /// Знак-граница не влияет на решение по однобуквенному слову: '?', '!', пробел
    /// дают один и тот же fixed. (Класс проблемы — слово, а не граничный символ.)
    func testSingleLetterBoundaryCharDoesNotChangeOutcome() {
        XCTAssertEqual(run(typing("j") + [.space]).map(\.fixed), ["о"])
        XCTAssertEqual(run(typing("j") + [.character("!")]).map(\.fixed), ["о"])
        XCTAssertEqual(run(typing("j") + [.character("?")]).map(\.fixed), ["о"])
    }

    /// 'a'/'i' — реальные английские однобуквенные слова: не трогаем, даже хотя
    /// раскладочно они дали бы 'ф'/'ш'.
    func testSingleLetterRealEnglishWordsUntouched() {
        XCTAssertTrue(run(typing("a") + [.space]).isEmpty)
        XCTAssertTrue(run(typing("i") + [.space]).isEmpty)
    }

    /// Детерминизм: один и тот же однобуквенный ввод даёт один результат при
    /// повторных прогонах (раньше зависел от вердикта NSSpellChecker).
    func testSingleLetterIsDeterministic() {
        let keys = typing("j") + [.character("?")]
        XCTAssertEqual(run(keys), run(keys))
    }

    func testNonCorrectableWordReturnsRaw() {
        // Реальное слово на границе — .raw (сырьё + граница), не .corrected.
        let engine = AutoModeEngine()
        for ch in "hello" { _ = engine.handle(.character(ch)) }
        XCTAssertEqual(engine.handle(.space), .raw(word: "hello", boundary: .space))
    }

    func testBufferedTextExposesTail() {
        let engine = AutoModeEngine()
        for ch in "ghb" { _ = engine.handle(.character(ch)) }
        XCTAssertEqual(engine.bufferedText, "ghb")
        _ = engine.handle(.space)  // граница очищает буфер
        XCTAssertEqual(engine.bufferedText, "")
    }

    // MARK: - Детерминизм (логика отдельно от петли раскладки/таймингов)

    func testDeterministicAcrossFreshEngines() {
        let keys = typing("ghbdtn") + [.space] + typing("руддщ") + [.space]
        XCTAssertEqual(run(keys), run(keys))
    }

    func testDeterministicOnReusedEngine() {
        let engine = AutoModeEngine()
        let keys = typing("ghbdtn") + [.space]
        let first = run(keys, engine: engine)
        let second = run(keys, engine: engine)  // состояние не «утекает» между прогонами
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.fixed, "привет")
    }

    func testMultipleWords() {
        let keys = typing("ghbdtn") + [.space] + typing("руддщ") + [.space]
        XCTAssertEqual(run(keys).map(\.fixed), ["привет", "hello"])
    }

    // MARK: - Не-текстовые клавиши и backspace

    func testIgnoredKeysDoNotBreakWord() {
        let result = run(typing("ghb") + [.ignored] + typing("dtn") + [.space])
        XCTAssertEqual(result.first?.fixed, "привет")
    }

    func testBackspaceEditsBufferBeforeBoundary() {
        // «ghbdtx» с исправлением опечатки backspace'ом на «n» -> «ghbdtn».
        let result = run(typing("ghbdtx") + [.backspace] + typing("n") + [.space])
        XCTAssertEqual(result.first?.word, "ghbdtn")
        XCTAssertEqual(result.first?.fixed, "привет")
    }

    // MARK: - isIdle (гейт для отложенного переключения раскладки)

    func testIsIdleReflectsBufferState() {
        let engine = AutoModeEngine()
        XCTAssertTrue(engine.isIdle)              // пусто
        _ = engine.handle(.character("g"))
        XCTAssertFalse(engine.isIdle)             // в середине слова
        for ch in "hbdtn" { _ = engine.handle(.character(ch)) }
        _ = engine.handle(.space)                 // граница очищает буфер
        XCTAssertTrue(engine.isIdle)
    }
}
