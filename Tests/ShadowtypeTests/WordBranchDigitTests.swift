// TabSwallowTap.digitForKeycode — the pure gate for "auto show word alternatives" digit
// acceptance (FlowIn port): a digit is swallowed ONLY while the visible menu has that many rows.
// Out-of-range digits and any modifier-held key are ordinary typing and must pass through.
import XCTest
@testable import Shadowtype

final class WordBranchDigitTests: XCTestCase {

    // ANSI keycodes: 1=18, 2=19, 3=20, 4=21, 5=23.
    func testDigitsMapToRows() {
        XCTAssertEqual(TabSwallowTap.digitForKeycode(18, menuRows: 3, hasModifier: false), 1)
        XCTAssertEqual(TabSwallowTap.digitForKeycode(19, menuRows: 3, hasModifier: false), 2)
        XCTAssertEqual(TabSwallowTap.digitForKeycode(20, menuRows: 3, hasModifier: false), 3)
    }

    func testOutOfRangeDigitPassesThrough() {
        // Only 2 rows visible: "3" and "4" are the user typing numbers, not selecting rows.
        XCTAssertNil(TabSwallowTap.digitForKeycode(20, menuRows: 2, hasModifier: false))
        XCTAssertNil(TabSwallowTap.digitForKeycode(21, menuRows: 2, hasModifier: false))
    }

    func testFiveRowsExposeAllFiveDigits() {
        XCTAssertEqual(TabSwallowTap.digitForKeycode(21, menuRows: 5, hasModifier: false), 4)
        XCTAssertEqual(TabSwallowTap.digitForKeycode(23, menuRows: 5, hasModifier: false), 5)
    }

    func testNoMenuMeansNoSwallowing() {
        XCTAssertNil(TabSwallowTap.digitForKeycode(18, menuRows: 0, hasModifier: false))
    }

    func testModifiersAlwaysPassThrough() {
        // ⌘1 / ⌥1 / ⇧1 / ⌃1 are app shortcuts and shifted symbols — never a menu pick.
        XCTAssertNil(TabSwallowTap.digitForKeycode(18, menuRows: 5, hasModifier: true))
    }

    func testNonDigitKeycodesPassThrough() {
        XCTAssertNil(TabSwallowTap.digitForKeycode(48, menuRows: 5, hasModifier: false))   // Tab
        XCTAssertNil(TabSwallowTap.digitForKeycode(29, menuRows: 5, hasModifier: false))   // 0 — no row 0
        XCTAssertNil(TabSwallowTap.digitForKeycode(124, menuRows: 5, hasModifier: false))  // right arrow
    }
}
