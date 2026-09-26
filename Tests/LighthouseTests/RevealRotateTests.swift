import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// Finder에서 원본 보기와 왼쪽·오른쪽 회전.
@MainActor
final class RevealRotateTests: XCTestCase {
    func testRevealSelectedOriginalsAndRotateBothWays() async throws {
        let (model, root, urls) = try await TestSupport.startedModel(self, photos: 3)
        var revealed: [[URL]] = []
        model.revealInFinder = { revealed.append($0) }
        let photos = model.visiblePhotos
        model.select(photos[0])
        model.createVirtualCopy()
        model.select(photos[0])
        model.handleTileClick(try XCTUnwrap(model.visiblePhotos.first(where: \.isVirtualCopy)), clickCount: 1, modifiers: .command)
        model.handleTileClick(photos[1], clickCount: 1, modifiers: .command)
        model.revealOriginals()
        XCTAssertEqual(revealed.last?.map(\.lastPathComponent), [urls[0].lastPathComponent, urls[1].lastPathComponent],
                       "가상 사본은 원본 한 파일로 모은다")

        try FileManager.default.moveItem(at: urls[2], to: root.appendingPathComponent("moved.jpg"))
        model.refreshMissingOriginals()
        try await TestSupport.wait("missing") { model.isMissing(photos[2]) }
        model.select(photos[2])
        let before = revealed.count
        model.revealOriginals()
        XCTAssertEqual(revealed.count, before, "원본이 없으면 Finder를 열지 않는다")
        XCTAssertTrue(model.operationMessage?.contains("찾을 수 없습니다") == true)
        model.presentCrop()
        XCTAssertNil(model.cropSource, "원본이 없으면 크롭 창을 열지 않는다")
        model.beginWhiteBalancePick()
        XCTAssertFalse(model.isPickingWhiteBalance, "원본이 없으면 회색 찍기를 시작하지 않는다")

        model.select(photos[1])
        model.rotate(clockwise: false)
        XCTAssertEqual(model.selection?.edits.rotationQuarterTurns, 3)
        model.rotate(clockwise: true)
        model.rotate(clockwise: true)
        XCTAssertEqual(model.selection?.edits.rotationQuarterTurns, 1)
        model.undo()
        XCTAssertEqual(model.selection?.edits.rotationQuarterTurns, 0)
    }
}
