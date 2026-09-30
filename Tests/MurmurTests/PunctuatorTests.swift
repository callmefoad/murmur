import XCTest
@testable import Murmur

/// The rebuild half of `Punctuator` is pure: these feed it hand-written
/// labels, so they run without the model.
final class PunctuatorTests: XCTestCase {
    private typealias Label = Punctuator.WordLabel

    /// Labels by word: a trailing mark after the word means "punctuation
    /// here", a leading "^" means "the model capitalizes it".
    private func labels(_ spec: String) -> [Label] {
        spec.split(separator: " ").map { raw in
            var word = Substring(raw)
            let capital = word.first == "^"
            if capital { word = word.dropFirst() }
            let mark = word.last.flatMap { ".,?".contains($0) ? $0 : nil }
            return Label(punctuation: mark, capitalized: capital)
        }
    }

    private func run(_ text: String, _ spec: String) -> String {
        Punctuator.repunctuate(text) { words in
            let result = labels(spec)
            XCTAssertEqual(words.count, result.count, "label count for \(words)")
            return result
        }
    }

    func testPausePeriodsBecomeGrammar() {
        XCTAssertEqual(
            run("I think we should wait. Until Monday. Because the files aren't here.",
                "^i think we should wait until ^monday because the files aren't here."),
            "I think we should wait until Monday because the files aren't here.")
    }

    func testCommaReplacesPausePeriod() {
        XCTAssertEqual(
            run("The battery is fine but. We should check it.",
                "^the battery is fine, but we should check it."),
            "The battery is fine, but we should check it.")
    }

    func testRecognizerQuestionMarkIsKept() {
        XCTAssertEqual(
            run("Are you coming? I'll wait.", "^are you coming. ^i'll wait."),
            "Are you coming? I'll wait.")
    }

    func testNamesAndInteriorCapitalsSurvive() {
        XCTAssertEqual(
            run("She has an iPhone. And Sarah has a MacBook.",
                "^she has an iphone and sarah has a macbook."),
            "She has an iPhone and Sarah has a MacBook.")
    }

    func testFunctionWordNeverCapitalizedMidSentence() {
        XCTAssertEqual(
            run("She said. The battery is fine.",
                "^she said ^the battery is fine."),
            "She said the battery is fine.")
    }

    func testFirstPersonStaysCapital() {
        XCTAssertEqual(
            run("So. I think it works.", "^so i think it works."),
            "So I think it works.")
    }

    func testDottedAbbreviationKeepsItsDots() {
        XCTAssertEqual(
            run("Meet at 5 p.m. On Tuesday.", "^meet at 5 pm on ^tuesday."),
            "Meet at 5 p.m. on Tuesday.")
        XCTAssertEqual(
            run("Meet at 5 p.m. See you.", "^meet at 5 pm. ^see you."),
            "Meet at 5 p.m. See you.")
    }

    func testNoFinalPeriodWhenInputHadNone() {
        // Auto-period off: the formatter left the end bare. Keep it bare.
        XCTAssertEqual(run("sounds good", "sounds good."), "Sounds good")
    }

    func testNewlinesAreKept() {
        XCTAssertEqual(
            run("First thing. Is milk\nSecond thing is eggs.",
                "^first thing is milk. ^second thing is eggs."),
            "First thing is milk.\nSecond thing is eggs.")
    }

    func testSymbolsPassThrough() {
        XCTAssertEqual(
            run("Cost is $5 - maybe more.", "^cost is 5 maybe more."),
            "Cost is $5 - maybe more.")
    }

    func testHyphenatedWordIsOneChunk() {
        XCTAssertEqual(
            run("I talk in run-on sentences. A lot.", "^i talk in run on sentences a lot."),
            "I talk in run-on sentences a lot.")
    }

    func testWrongLabelCountLeavesTextAlone() {
        let text = "Hello there. Friend."
        XCTAssertEqual(Punctuator.repunctuate(text) { _ in [] }, text)
        XCTAssertEqual(Punctuator.repunctuate(text) { _ in nil }, text)
    }

    func testModelWords() {
        XCTAssertEqual(Punctuator.modelWords("Don't run-on 100%, p.m."),
                       ["don't", "run", "on", "100", "p", "m"])
        XCTAssertEqual(Punctuator.modelWords("it’s"), ["it's"])
    }

    // MARK: - Tokenizer, against SentencePiece's own output

    func testTokenizerMatchesSentencePiece() throws {
        guard let data = try? Data(contentsOf: PunctuationModelFiles.tokenizerURL) else {
            throw XCTSkip("punctuation model not installed")
        }
        let tokenizer = try SentencePieceTokenizer(modelData: data)
        func encode(_ text: String) -> [Int32] {
            text.split(separator: " ").flatMap { tokenizer.encode(word: String($0)) }
        }
        XCTAssertEqual(encode("hello world"), [8015, 140])
        XCTAssertEqual(encode("i think we should probably wait until monday"),
                       [19, 118, 25, 135, 752, 1170, 284, 335])
        XCTAssertEqual(encode("don't you're macbook gmail"),
                       [107, 13, 31, 35, 13, 81, 18013, 27956])
        XCTAssertEqual(tokenizer.piece(5), "▁the")
    }
}
