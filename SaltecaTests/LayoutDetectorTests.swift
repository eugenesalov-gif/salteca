import XCTest
@testable import Salteca

final class LayoutDetectorTests: XCTestCase {

    // MARK: - guessDirection

    func testEmptyAndNonLetterReturnsNil() {
        XCTAssertNil(LayoutDetector.guessDirection(""))
        XCTAssertNil(LayoutDetector.guessDirection("123 !?"))
    }

    func testRealWordsAreLeftAlone() {
        XCTAssertNil(LayoutDetector.guessDirection("hello"))
        XCTAssertNil(LayoutDetector.guessDirection("привет"))
    }

    func testWrongLayoutIsDetected() {
        // "привет", набранное в английской раскладке.
        XCTAssertEqual(LayoutDetector.guessDirection("ghbdtn"), .enToRu)
        // "hello", набранное в русской раскладке.
        XCTAssertEqual(LayoutDetector.guessDirection("руддщ"), .ruToEn)
    }

    func testMixedScriptReturnsNil() {
        XCTAssertNil(LayoutDetector.guessDirection("XcVзаметил"))
    }

    func testNativeTypoLeftAlone() {
        // Опечатки в родном языке — НЕ ошибка раскладки: оба варианта «не слово».
        // "Хлеь" (опечатка "Хлеб") конвертировалась бы в мусор "Хktm".
        XCTAssertNil(LayoutDetector.guessDirection("Хлеь"))
        XCTAssertNil(LayoutDetector.guessDirection("хлеь"))
        // "булое" (опечатка "булок") -> мусор "ekjt".
        XCTAssertNil(LayoutDetector.guessDirection("булое"))
        // Через autoCorrection (авто-режим) — тоже не трогаем.
        XCTAssertNil(LayoutDetector.autoCorrection(for: "Хлеь"))
        XCTAssertNil(LayoutDetector.autoCorrection(for: "булое"))
    }

    func testRealLayoutErrorStillFixedAfterTypoGuard() {
        // Проверяем, что консервативность не сломала настоящие ошибки раскладки:
        // у них результат конверсии — реальное слово другого языка.
        XCTAssertEqual(LayoutDetector.guessDirection("руддщ"), .ruToEn)   // -> hello
        XCTAssertEqual(LayoutDetector.guessDirection("ghbdtn"), .enToRu)  // -> привет
    }

    // MARK: - dominantDirection (принудительное направление)

    func testDominantDirectionForcesConversion() {
        // "xcv" — валидное на вид английское, guessDirection его не тронет,
        // но dominantDirection обязан выбрать направление (латиница преобладает).
        XCTAssertNil(LayoutDetector.guessDirection("xcv"))
        XCTAssertEqual(LayoutDetector.dominantDirection("xcv"), .enToRu)
        // Преобладает кириллица.
        XCTAssertEqual(LayoutDetector.dominantDirection("привет"), .ruToEn)
        // Нет букв — направление не определить.
        XCTAssertNil(LayoutDetector.dominantDirection("123 !?"))
    }

    func testOpposite() {
        XCTAssertEqual(LayoutDirection.enToRu.opposite, .ruToEn)
        XCTAssertEqual(LayoutDirection.ruToEn.opposite, .enToRu)
    }

    // MARK: - LayoutDirection.apply

    func testApplyProducesCorrectText() {
        XCTAssertEqual(LayoutDirection.enToRu.apply(to: "ghbdtn"), "привет")
        XCTAssertEqual(LayoutDirection.ruToEn.apply(to: "руддщ"), "hello")
    }

    // MARK: - Специальные марки как русские буквы

    func testBracketMarksTreatedAsLetters() {
        // "хлеб", набранное в EN-раскладке: '[' -> х, kt -> ле, ; -> ж... проверяем,
        // что '[' надёжно опознаётся как буква и слово исправляется в русскую сторону.
        XCTAssertEqual(LayoutDetector.guessDirection("[kt,"), .enToRu)
        XCTAssertEqual(LayoutDirection.enToRu.apply(to: "[kt,"), "хлеб")
    }

    // MARK: - autoCorrection (решение авто-режима, включая хвостовой знак)

    func testAutoCorrectionSimpleWord() {
        // Без хвостового знака — как guessDirection + apply.
        let result = LayoutDetector.autoCorrection(for: "ghbdtn")
        XCTAssertEqual(result?.direction, .enToRu)
        XCTAssertEqual(result?.fixed, "привет")
    }

    func testAutoCorrectionLeavesRealWords() {
        XCTAssertNil(LayoutDetector.autoCorrection(for: "привет"))
        XCTAssertNil(LayoutDetector.autoCorrection(for: "hello"))
        // Одиночный знак — трогать нечего.
        XCTAssertNil(LayoutDetector.autoCorrection(for: ","))
    }

    func testTrailingMarkTreatedAsPunctuation() {
        // "привет," с настоящей запятой: "ghbdtn" + ",". Ядро "ghbdtn" -> реальное
        // слово "привет", значит запятая — пунктуация, а не буква 'б'.
        let comma = LayoutDetector.autoCorrection(for: "ghbdtn,")
        XCTAssertEqual(comma?.direction, .enToRu)
        XCTAssertEqual(comma?.fixed, "привет,")

        // То же с точкой ('.' в EN-раскладке = буква 'ю').
        let period = LayoutDetector.autoCorrection(for: "ghbdtn.")
        XCTAssertEqual(period?.direction, .enToRu)
        XCTAssertEqual(period?.fixed, "привет.")
    }

    func testTrailingMarkTreatedAsLetter() {
        // "хлеб" целиком в EN-раскладке = "[kt,", где ',' это буква 'б'. Ядро
        // "[kt" -> "хле" не слово, поэтому ',' остаётся буквой, а не пунктуацией.
        let result = LayoutDetector.autoCorrection(for: "[kt,")
        XCTAssertEqual(result?.direction, .enToRu)
        XCTAssertEqual(result?.fixed, "хлеб")
    }
}
