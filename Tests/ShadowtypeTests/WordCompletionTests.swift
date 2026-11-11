// Unit tests for WordCompletion — the pure "auto show word alternatives" core (FlowIn-style).
import XCTest
@testable import Shadowtype

final class WordCompletionTests: XCTestCase {

    // MARK: - stem extraction

    func testStemMidWord() {
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "Thanks for your mess"), "mess")
    }

    func testStemAtDocumentStartNoWhitespace() {
        // First word of an empty document must still complete (regression guard).
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "Tha"), "Tha")
    }

    func testStemTooShortRejected() {
        XCTAssertNil(WordCompletion.stem(beforeCaret: "hello t"))     // 1 letter
        XCTAssertNil(WordCompletion.stem(beforeCaret: "hello "))      // empty
    }

    func testStemTrimsLeadingPunctuation() {
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "said — we"), "we")
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "(\"Tha"), "Tha")
    }

    func testStemKeepsInternalApostrophe() {
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "I don't real"), "real")
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "I don'"), "don'")
    }

    func testStemRejectsShortcodesAndSnippets() {
        XCTAssertNil(WordCompletion.stem(beforeCaret: "send :smil"))
        XCTAssertNil(WordCompletion.stem(beforeCaret: "drop ;sig"))
    }

    func testStemRejectsURLishAndPureNumbers() {
        XCTAssertNil(WordCompletion.stem(beforeCaret: "see https://github.co"))
        XCTAssertNil(WordCompletion.stem(beforeCaret: "total 4521"))
    }

    func testStemUnicodeAware() {
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "muchas graci"), "graci")
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "obrigad"), "obrigad")   // PT
        XCTAssertEqual(WordCompletion.stem(beforeCaret: "مرحبا شك"), "شك")          // AR
    }

    // MARK: - branch menu

    private func c(_ r: String, _ p: Float) -> WordCompletion.Candidate {
        WordCompletion.Candidate(remainder: r, probability: p)
    }

    func testMenuBuildsFullWordsInProbabilityOrder() {
        let menu = WordCompletion.branchMenu(
            candidates: [c("age", 0.5), c("es", 0.3), c("atory", 0.1)], stem: "mess")
        XCTAssertEqual(menu, ["message", "messages", "messatory"])
    }

    func testMenuCutsAtFirstWhitespaceOneWordOnly() {
        // Model continues past the word boundary; the menu completes exactly one word.
        let menu = WordCompletion.branchMenu(candidates: [c("s and more", 0.4)], stem: "thank")
        XCTAssertEqual(menu, ["thanks"])
    }

    func testMenuDropsEmptyRemainder() {
        // Top choice == the typed stem itself → not an alternative.
        let menu = WordCompletion.branchMenu(candidates: [c("", 0.6), c("y", 0.2)], stem: "ma")
        XCTAssertEqual(menu, ["may"])
    }

    func testMenuDedupesKeepingFirstOccurrence() {
        let menu = WordCompletion.branchMenu(
            candidates: [c("s", 0.5), c("s", 0.2), c("ing", 0.3)], stem: "thin")
        XCTAssertEqual(menu, ["things", "thinking"])
    }

    func testMenuCapsAtMaxBranches() {
        let many = (0..<10).map { c("x\($0)", Float(10 - $0)) }
        XCTAssertEqual(WordCompletion.branchMenu(candidates: many, stem: "a").count,
                       WordCompletion.maxBranches)
    }

    func testMenuKeepsTrailingPunctuationCompletions() {
        // "tion," may be the grammatically right completion of "insti" — only whitespace cuts.
        let menu = WordCompletion.branchMenu(candidates: [c("tion,", 0.4)], stem: "insti")
        XCTAssertEqual(menu, ["institution,"])
    }

    func testMenuCaseSensitiveDistinct() {
        let menu = WordCompletion.branchMenu(
            candidates: [c("land", 0.5), c("Land", 0.2)], stem: "eng")
        XCTAssertEqual(menu, ["england", "engLand"])   // dedupe is case-sensitive by design
    }

    // MARK: - digit acceptance (FlowIn: type 1, 2, 3… to insert that row)

    func testSelectMapsDigitsToVisibleRows() {
        let menu = ["message", "messages", "messenger"]
        XCTAssertEqual(WordCompletion.select(menu: menu, digit: 1), "message")
        XCTAssertEqual(WordCompletion.select(menu: menu, digit: 3), "messenger")
    }

    func testSelectRejectsOutOfRangeDigits() {
        let menu = ["message", "messages"]
        XCTAssertNil(WordCompletion.select(menu: menu, digit: 0))     // no row 0
        XCTAssertNil(WordCompletion.select(menu: menu, digit: 3))     // only 2 rows visible
        XCTAssertNil(WordCompletion.select(menu: menu, digit: 9))     // ordinary typing
        XCTAssertNil(WordCompletion.select(menu: [], digit: 1))       // no menu shown
    }
}
