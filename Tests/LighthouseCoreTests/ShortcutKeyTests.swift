import XCTest
@testable import LighthouseCore

final class ShortcutKeyTests: XCTestCase {
    func testKoreanInputFallsBackToKeyPosition() {
        XCTAssertEqual(ShortcutKey.resolve(characters: "p", keyCode: 35), "p")
        XCTAssertEqual(ShortcutKey.resolve(characters: "ㅔ", keyCode: 35), "p", "한글 2벌식의 P 키")
        XCTAssertEqual(ShortcutKey.resolve(characters: "ㅌ", keyCode: 7), "x")
        XCTAssertEqual(ShortcutKey.resolve(characters: "ㅎ", keyCode: 5), "g")
        XCTAssertEqual(ShortcutKey.resolve(characters: "₩", keyCode: 42), "\\", "한글 입력의 백슬래시 자리")
        XCTAssertEqual(ShortcutKey.resolve(characters: "3", keyCode: 20), "3")
        XCTAssertEqual(ShortcutKey.resolve(characters: "3", keyCode: 85), "3", "숫자 키패드")
        XCTAssertEqual(ShortcutKey.resolve(characters: "P", keyCode: 35), "p")
        XCTAssertEqual(ShortcutKey.resolve(characters: "l", keyCode: 35), "l", "영문 배열이 다르면 글자를 따른다")
        XCTAssertNil(ShortcutKey.resolve(characters: "ㅔ", keyCode: 999))
        XCTAssertNil(ShortcutKey.resolve(characters: nil, keyCode: 123), "화살표는 따로 처리한다")
    }
}
