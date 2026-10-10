@testable import Lighthouse
import XCTest

/// 고르기 막대 오른쪽 안내: 무엇에 붙는지 알린다.
@MainActor
final class CullingBarTests: XCTestCase {
    func testStatusSaysWhatTheMarksApplyTo() {
        XCTAssertEqual(CullingBar.status(targets: 0, selected: 0, mixed: false), "사진을 고르면 별점·표시·라벨을 붙입니다")
        XCTAssertEqual(CullingBar.status(targets: 1, selected: 1, mixed: false), "P 채택 · X 제외 · U 해제 · 1–5 별점 · 6–9 라벨")
        XCTAssertEqual(CullingBar.status(targets: 3, selected: 3, mixed: false), "고른 3장에 함께 붙입니다")
        XCTAssertEqual(CullingBar.status(targets: 2, selected: 2, mixed: true), "고른 2장에 함께 붙입니다 · 값이 서로 다름")
        // 그리드가 아닌 보기에서는 여러 장을 골라도 보고 있는 한 장에만 붙는다.
        XCTAssertEqual(CullingBar.status(targets: 1, selected: 3, mixed: false), "현재 사진에만 붙습니다 · P·X·U·1–5·6–9 키와 같음")
    }
}
