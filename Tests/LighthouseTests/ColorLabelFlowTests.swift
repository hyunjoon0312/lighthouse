import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 6–9 키로 라벨 붙이기·떼기, 실행 취소, 라벨로 거르기.
@MainActor
final class ColorLabelFlowTests: XCTestCase {
    func testKeyTogglesLabelUndoAndFilter() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let photos = model.photos
        model.focusPhoto(photos[0])
        model.markFromKeyboard(toggleLabel: PhotoColorLabel.forKey("6"))
        XCTAssertEqual(model.photo(withID: photos[0].id)?.colorLabel, .red)
        model.markFromKeyboard(toggleLabel: .red)
        XCTAssertNil(model.photo(withID: photos[0].id)?.colorLabel, "같은 키를 다시 누르면 뗀다")
        model.undo()
        XCTAssertEqual(model.photo(withID: photos[0].id)?.colorLabel, .red, "떼기도 한 단계로 되돌린다")

        model.autoAdvance = true
        model.focusPhoto(photos[1])
        model.markFromKeyboard(toggleLabel: .blue)
        XCTAssertEqual(model.selectedID, photos[2].id, "표시 후 다음 사진이 켜져 있으면 넘어간다")
        model.criteria.colorLabel = .blue
        XCTAssertEqual(model.visiblePhotos.map(\.id), [photos[1].id])
        model.criteria.colorLabel = .red
        model.focusPhoto(photos[0])
        model.setColorLabel(.purple)
        XCTAssertTrue(model.visiblePhotos.isEmpty, "라벨을 바꾸면 조건에서 빠진다")
    }
}
