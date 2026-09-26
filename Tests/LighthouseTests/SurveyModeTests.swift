import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 여러 장 보기(N).
@MainActor
final class SurveyModeTests: XCTestCase {
    func testSurveyShowsSelectionKeepsMarksInsideAndRerendersEdits() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 5)
        let photos = model.photos
        model.select(photos[0])
        model.handleTileClick(photos[2], clickCount: 1, modifiers: .command)
        model.handleTileClick(photos[4], clickCount: 1, modifiers: .command)
        model.setMode(.survey)
        XCTAssertEqual(model.surveyPhotos.map(\.id), [photos[0].id, photos[2].id, photos[4].id], "선택한 사진을 목록 순서로")
        XCTAssertFalse(model.showsSingleImage)
        try await TestSupport.wait("survey images") { model.surveyImages.count == 3 }
        XCTAssertNil(model.rendered, "한 장 렌더는 하지 않는다")

        model.focusPhoto(photos[4])
        model.moveInSurvey(1)
        XCTAssertEqual(model.selectedID, photos[0].id, "놓인 사진 안에서 돈다")
        model.autoAdvance = true
        model.markFromKeyboard(flag: .pick)
        XCTAssertEqual(model.selectedID, photos[2].id, "다음 사진도 놓인 사진 안에서")
        XCTAssertEqual(model.selectedPhotoIDs.count, 3, "표시해도 선택이 풀리지 않는다")

        let before = model.surveyImages[photos[2].id]
        var edits = photos[2].edits
        edits.exposure = 1
        model.updateEdits(edits)
        try await TestSupport.wait("rerender edited") {
            model.surveyImages[photos[2].id] !== before && model.surveyRenderedEdits[photos[2].id] == edits
        }

        model.togglePhotoSelection(photos[4])
        XCTAssertEqual(model.surveyPhotos.map(\.id), [photos[0].id, photos[2].id], "×로 비교에서 뺀다")
        model.toggleFocusView()
        XCTAssertEqual(model.mode, .edit, "여러 장 보기에서 F는 사진 보기로 들어간다")
        model.isFocusView = false
        XCTAssertTrue(model.surveyImages.isEmpty, "여러 장 보기를 떠나면 그림을 버린다")
    }
}
