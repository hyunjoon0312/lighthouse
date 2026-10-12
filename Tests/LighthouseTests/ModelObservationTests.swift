import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 모델은 `@Observable`이라 화면이 읽은 값이 바뀔 때만 그 화면을 다시 계산한다. 캐시에서 꺼내는 값, 중지 깃발,
/// 썸네일 캐시처럼 추적되지 않는 곳에서 읽는 값도 바뀌면 읽은 화면이 알아야 한다.
@MainActor
final class ModelObservationTests: XCTestCase {
    /// 캐시가 맞은 뒤에도 필터·사진이 바뀌면 목록·개수·폴더를 읽는 화면이 다시 계산된다.
    func testCachedLibraryValuesFollowTheirInputs() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 3)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        _ = (model.visiblePhotos, model.counts, model.folders)
        let grid = ObservationCounter { _ = model.visiblePhotos }
        let sidebar = ObservationCounter { _ = model.counts }
        let folders = ObservationCounter { _ = model.folders }

        model.search = "photo-01"
        XCTAssertEqual(model.visiblePhotos.count, 1)
        XCTAssertGreaterThan(grid.count, 0, "검색이 바뀌면 목록이 다시 계산된다")

        try await Task.sleep(nanoseconds: 50_000_000)
        let elsewhere = root.appendingPathComponent("elsewhere/new.jpg")
        model.photos.append(PhotoAsset(url: elsewhere))
        XCTAssertGreaterThan(sidebar.count, 0, "사진이 바뀌면 개수가 다시 계산된다")
        XCTAssertGreaterThan(folders.count, 0, "사진이 바뀌면 폴더 목록이 다시 계산된다")
        XCTAssertTrue(model.folders.contains(elsewhere.deletingLastPathComponent().path))
    }

    /// 아직 없는 사진을 찾던 화면도 그 사진이 생기면 다시 계산된다.
    func testLookingUpAMissingPhotoFollowsLaterArrivals() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 1)
        let id = UUID()
        XCTAssertNil(model.photo(withID: id))
        let lookup = ObservationCounter { _ = model.photo(withID: id) }
        model.photos.append(PhotoAsset(id: id, url: root.appendingPathComponent("photos/late.jpg")))
        XCTAssertGreaterThan(lookup.count, 0)
        XCTAssertNotNil(model.photo(withID: id))
    }

    /// 추천을 한 번 계산한 뒤에도 분석 결과가 바뀌면 배지를 읽는 화면이 다시 계산된다.
    func testBurstRecommendationsFollowNewResults() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 0)
        _ = model.burstRecommendations
        let badges = ObservationCounter { _ = model.burstRecommendations }
        model.burstFailedIDs.insert(UUID())
        XCTAssertGreaterThan(badges.count, 0)
    }

    /// 중지 깃발은 추적되지 않지만, 중지를 누르면 "중지하는 중" 표시가 바로 바뀐다.
    func testStoppingStateFollowsTheStopButton() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 0)
        model.isAnalyzingBursts = true
        model.burstCancellation = CancellationFlag()
        model.isRunningWorkflow = true
        model.workflowCancellation = CancellationFlag()
        defer {
            model.isAnalyzingBursts = false
            model.burstCancellation = nil
            model.isRunningWorkflow = false
            model.workflowCancellation = nil
        }
        let bursts = ObservationCounter { _ = model.isCancellingBursts }
        let workflow = ObservationCounter { _ = model.isCancellingWorkflow }
        model.cancelBurstAnalysis()
        model.cancelWorkflow()
        XCTAssertTrue(model.isCancellingBursts)
        XCTAssertTrue(model.isCancellingWorkflow)
        XCTAssertGreaterThan(bursts.count, 0)
        XCTAssertGreaterThan(workflow.count, 0)
    }

    /// 썸네일 캐시는 추적되지 않지만, 썸네일이 들어오면 그 칸이 다시 계산된다.
    func testThumbnailCellsFollowArrivingThumbnails() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let photo = model.photos[0]
        try await TestSupport.wait("thumbnail") {
            model.requestThumbnail(for: photo)
            return model.thumbnail(for: photo) != nil
        }
        model.invalidateWorkflowRenderCaches()
        XCTAssertNil(model.thumbnail(for: photo))
        let cell = ObservationCounter { _ = model.thumbnail(for: photo) }
        model.requestThumbnail(for: photo)
        try await TestSupport.wait("refill") { model.thumbnail(for: photo) != nil }
        XCTAssertGreaterThan(cell.count, 0)
    }
}
