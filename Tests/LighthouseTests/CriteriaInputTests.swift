import XCTest
@testable import Lighthouse

final class CriteriaInputTests: XCTestCase {
    func testDecimalParserKeepsEmptyAndDraftStatesDistinct() {
        XCTAssertEqual(CriteriaNumberParser.decimal(""), .empty)
        XCTAssertEqual(CriteriaNumberParser.decimal("  \n"), .empty)
        XCTAssertEqual(CriteriaNumberParser.decimal("1."), .valid(1))
        XCTAssertEqual(CriteriaNumberParser.decimal("1e"), .invalid)
        XCTAssertEqual(CriteriaNumberParser.decimal("not a number"), .invalid)
        XCTAssertEqual(CriteriaNumberParser.decimal("-1"), .invalid)
    }

    func testDecimalParserAcceptsFiniteNonnegativeLargeValues() {
        XCTAssertEqual(CriteriaNumberParser.decimal("0"), .valid(0))
        XCTAssertEqual(CriteriaNumberParser.decimal("1e20"), .valid(1e20))
        XCTAssertEqual(CriteriaNumberParser.decimal(String(Double.greatestFiniteMagnitude)),
                       .valid(.greatestFiniteMagnitude))
        XCTAssertEqual(CriteriaNumberParser.decimal(String(Double.infinity)), .invalid)
        XCTAssertEqual(CriteriaNumberParser.decimal(String(-Double.infinity)), .invalid)
        XCTAssertEqual(CriteriaNumberParser.decimal(String(Double.nan)), .invalid)
    }

    func testISOParserRoundsWithoutTrappingAndRejectsOutOfRange() {
        XCTAssertEqual(CriteriaNumberParser.iso(""), .empty)
        XCTAssertEqual(CriteriaNumberParser.iso("1.4"), .valid(1))
        XCTAssertEqual(CriteriaNumberParser.iso("1.5"), .valid(2))
        XCTAssertEqual(CriteriaNumberParser.iso("-0.4"), .invalid)
        XCTAssertEqual(CriteriaNumberParser.iso(String(Int.max)), .valid(Int.max))
        XCTAssertEqual(CriteriaNumberParser.iso("9007199254740993"), .valid(9_007_199_254_740_993))
        XCTAssertEqual(CriteriaNumberParser.iso("9223372036854775808"), .invalid)

        let largestRepresentableInRange = Double(Int.max).nextDown
        let expected = Int(exactly: largestRepresentableInRange.rounded())
        let expectedResult = expected.map { CriteriaNumberParseResult<Int>.valid($0) } ?? .invalid
        XCTAssertEqual(CriteriaNumberParser.iso(String(largestRepresentableInRange)), expectedResult)
        XCTAssertEqual(CriteriaNumberParser.iso(String(Double(Int.max))), .invalid)
        XCTAssertEqual(CriteriaNumberParser.iso("1e100"), .invalid)
        XCTAssertEqual(CriteriaNumberParser.iso(String(Double.infinity)), .invalid)
        XCTAssertEqual(CriteriaNumberParser.iso(String(Double.nan)), .invalid)
    }

    func testISOCurrentMaximumDisplaysWithoutDoubleConversion() {
        XCTAssertEqual(CriteriaNumberParser.isoText(Int.max), String(Int.max))
        XCTAssertEqual(CriteriaNumberParser.isoText(nil), "")
    }
}
