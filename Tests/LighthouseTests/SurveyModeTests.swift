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

    func testSurveyKeepsSiblingSuccessShowsFailureAndRetryRecovers() async throws {
        let (model, _, urls) = try await TestSupport.startedModel(self, photos: 2)
        let photos = model.photos
        let missingBytes = try Data(contentsOf: urls[1])
        try FileManager.default.removeItem(at: urls[1])
        model.select(photos[0])
        model.handleTileClick(photos[1], clickCount: 1, modifiers: .command)
        model.setMode(.survey)

        try await TestSupport.wait("survey success and error") {
            model.surveyImages[photos[0].id] != nil && model.surveyErrors[photos[1].id] != nil &&
                model.surveyLoadingIDs.isEmpty
        }
        let successfulSibling = model.surveyImages[photos[0].id]
        model.requestSurveyImages()
        XCTAssertEqual(Set(model.surveyErrors.keys), [photos[1].id], "실패를 자동으로 무한 재시도하지 않는다")

        try missingBytes.write(to: urls[1])
        model.retrySurveyImage(photos[1].id)
        try await TestSupport.wait("survey retry") {
            model.surveyImages[photos[1].id] != nil && model.surveyErrors[photos[1].id] == nil &&
                !model.surveyLoadingIDs.contains(photos[1].id)
        }
        XCTAssertTrue(model.surveyImages[photos[0].id] === successfulSibling, "성공한 형제 사진은 그대로 둔다")

        model.setMode(.grid)
        XCTAssertTrue(model.surveyImages.isEmpty)
        XCTAssertTrue(model.surveyErrors.isEmpty)
        XCTAssertTrue(model.surveyLoadingIDs.isEmpty)
    }

    func testSurveyDiscardsQueuedResultsAfterEditAndLeavingMode() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let photos = model.photos
        model.select(photos[0])
        model.handleTileClick(photos[1], clickCount: 1, modifiers: .command)
        model.surveyQueue.suspend()
        var queueSuspended = true
        defer { if queueSuspended { model.surveyQueue.resume() } }
        model.setMode(.survey)
        XCTAssertEqual(model.surveyLoadingIDs.count, 2)
        var edits = photos[0].edits
        edits.exposure = 0.75
        model.focusPhoto(photos[0])
        model.updateEdits(edits)
        model.setMode(.grid)
        XCTAssertTrue(model.surveyLoadingIDs.isEmpty)
        XCTAssertTrue(model.surveyImages.isEmpty)

        let drained = expectation(description: "stale survey queue drained")
        model.surveyQueue.async { drained.fulfill() }
        model.surveyQueue.resume()
        queueSuspended = false
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertTrue(model.surveyImages.isEmpty, "떠난 뒤의 늦은 결과는 반영하지 않는다")
        XCTAssertTrue(model.surveyErrors.isEmpty)

        model.setMode(.survey)
        try await TestSupport.wait("fresh survey generation") {
            model.surveyImages.count == 2 && model.surveyRenderedEdits[photos[0].id] == edits &&
                model.surveyLoadingIDs.isEmpty
        }
    }
}
