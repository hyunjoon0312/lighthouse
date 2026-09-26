import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 흰색 기준 찍기: 사진 보기로 바꾸고, 누른 곳을 회색으로 맞추고, 한 번에 되돌린다.
@MainActor
final class WhiteBalancePickTests: XCTestCase {
    func testPickingNeutralizesAndUndoes() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let photo = try XCTUnwrap(model.visiblePhotos.first)
        model.select(photo)
        model.beginWhiteBalancePick()
        XCTAssertTrue(model.isPickingWhiteBalance)
        XCTAssertEqual(model.mode, .edit, "사진 보기에서 찍는다")
        model.pickWhiteBalance(at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(model.isPickingWhiteBalance, "한 번 누르면 끝난다")
        try await TestSupport.wait("white balance") { !model.isAutoAdjusting }
        // 만든 사진은 파란 기가 도는 색(40, 120, 160)이라 따뜻한 쪽으로 옮긴다.
        XCTAssertGreaterThan(model.selection?.edits.temperatureShift ?? 0, 0)
        XCTAssertTrue(model.operationMessage?.contains("회색으로 맞췄습니다") == true, model.operationMessage ?? "")
        model.undo()
        XCTAssertEqual(model.selection?.edits.temperatureShift, 0)
        XCTAssertEqual(model.selection?.edits.tintShift, 0)

        model.beginWhiteBalancePick()
        model.setMode(.grid)
        XCTAssertFalse(model.isPickingWhiteBalance, "보기를 바꾸면 취소된다")
    }
}
