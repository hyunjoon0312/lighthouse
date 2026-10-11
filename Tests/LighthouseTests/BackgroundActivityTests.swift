import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 얼굴 분석을 붙잡아 두는 분석기. 분석이 시작되면 알리고 `resume`까지 기다린다.
private final class HeldFaceAnalyzer: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    func analyze(_ url: URL) throws -> [DetectedFace] {
        started.signal()
        gate.wait()
        return []
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.started.wait()
                continuation.resume()
            }
        }
    }

    func resume(_ count: Int) {
        for _ in 0..<count { gate.signal() }
    }
}

/// 뒤에서 도는 작업 표시: 모델 상태로 작업 목록(이름·진행·중지 가능)을 만들고, 목록의 중지는 그 작업을 멈춘다.
@MainActor
final class BackgroundActivityTests: XCTestCase {
    /// 다 열린 라이브러리에는 보일 작업이 없다. 열 때 잠깐 읽는 LUT 목록은 작업으로 치지 않는다.
    func testIdleLibraryShowsNothing() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        XCTAssertEqual(model.backgroundActivities, [])
    }

    /// 얼굴 찾기는 몇 장째인지 보이고, 목록의 중지로 멈춘다.
    func testFaceSearchShowsCountAndStopsFromTheList() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let analyzer = HeldFaceAnalyzer()
        model.faceAnalyzeOverride = analyzer.analyze
        model.startFaceAnalysis(selectedOnly: false)
        await analyzer.waitUntilStarted()

        let activity = try XCTUnwrap(model.backgroundActivities.first { $0.kind == .faces })
        XCTAssertEqual(activity.title, "얼굴 찾기")
        XCTAssertEqual(activity.detail, "0/2장")
        XCTAssertEqual(activity.progress, 0)
        XCTAssertTrue(activity.canCancel)
        XCTAssertFalse(activity.isCancelling)

        model.cancelBackgroundActivity(.faces)
        XCTAssertEqual(model.backgroundActivities.first { $0.kind == .faces }?.isCancelling, true, "멈추는 중으로 보인다")
        analyzer.resume(2)
        try await TestSupport.wait("faces stopped") { !model.isAnalyzingFaces }
        XCTAssertNil(model.backgroundActivities.first { $0.kind == .faces })
    }

    /// 여러 장에 하는 작업은 무엇을 하는지 이름으로 보인다.
    func testWorkflowIsNamedAfterWhatItDoes() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }

        model.createSmartPreviews(for: Set(model.photos.map(\.id)))
        let previews = try XCTUnwrap(model.backgroundActivities.first { $0.kind == .workflow })
        XCTAssertEqual(previews.title, "스마트 미리보기 만들기")
        XCTAssertEqual(previews.progress, 0, "진행을 알리는 작업은 진행 막대를 쓴다")
        XCTAssertTrue(previews.canCancel)
        try await TestSupport.wait("previews") { !model.isRunningWorkflow }
        XCTAssertNil(model.backgroundActivities.first { $0.kind == .workflow })

        model.findSimilarPhotos()
        XCTAssertEqual(model.backgroundActivities.first { $0.kind == .workflow }?.title, "중복·유사 사진 찾기")
        try await TestSupport.wait("similar") { !model.isRunningWorkflow }
    }

    /// XMP 사이드카는 쓰는 동안 장수를 보이고 다 쓰면 사라진다. 쓰는 도중에는 멈출 수 없다.
    func testSidecarWritesShowUntilWritten() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        // 사이드카는 원본을 읽지 않으므로 RAW 항목은 이름만 있어도 된다.
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        model.photos += ["a.RW2", "b.RW2"].map { PhotoAsset(url: folder.appendingPathComponent($0)) }
        let gate = DispatchSemaphore(value: 0)
        model.sidecarQueue.async { gate.wait() }
        model.writesXMPSidecars = true
        defer { model.writesXMPSidecars = false }

        let activity = try XCTUnwrap(model.backgroundActivities.first { $0.kind == .sidecars })
        XCTAssertEqual(activity.title, "XMP 사이드카 쓰기")
        XCTAssertEqual(activity.detail, "2장")
        XCTAssertNil(activity.progress)
        XCTAssertFalse(activity.canCancel)
        gate.signal()
        try await TestSupport.wait("sidecars written") { model.backgroundActivities.isEmpty }
    }

    /// 가져오기는 진행 비율을 보이고, 중지할 수 있을 때만 중지 단추를 둔다.
    func testImportShowsProgress() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let folder = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestSupport.writeJPEG(folder.appendingPathComponent("one.jpg"))
        model.importURLs([folder])

        let activity = try XCTUnwrap(model.backgroundActivities.first { $0.kind == .importing })
        XCTAssertEqual(activity.title, "가져오기")
        XCTAssertEqual(activity.progress, 0)
        XCTAssertEqual(activity.canCancel, model.canCancelImport)
        try await TestSupport.wait("import") { !model.isImporting }
        XCTAssertNil(model.backgroundActivities.first { $0.kind == .importing })
    }

    /// 끝을 모르는 분석은 진행 막대 없이 돌고, 목록의 중지로 멈춘다.
    func testFlickerAnalysisStopsFromTheList() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        model.select(model.visiblePhotos[0])
        model.analyzeFlicker()

        let activity = try XCTUnwrap(model.backgroundActivities.first { $0.kind == .flicker })
        XCTAssertEqual(activity.title, "LED 띠 분석")
        XCTAssertNil(activity.progress)
        XCTAssertTrue(activity.canCancel)
        model.cancelBackgroundActivity(.flicker)
        XCTAssertNil(model.backgroundActivities.first { $0.kind == .flicker })
        XCTAssertEqual(model.flickerAnalysisMessage, "띠 분석을 취소했습니다.")
    }

    /// 베스트 컷 분석은 진행 비율을 보인다.
    func testBurstAnalysisShowsPercent() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 0)
        model.isAnalyzingBursts = true
        model.burstAnalysisProgress = 0.5
        defer { model.isAnalyzingBursts = false }

        let activity = try XCTUnwrap(model.backgroundActivities.first { $0.kind == .bursts })
        XCTAssertEqual(activity.title, "베스트 컷 분석")
        XCTAssertEqual(activity.detail, "50%")
        XCTAssertEqual(activity.progress, 0.5)
        XCTAssertTrue(activity.canCancel)
    }

    /// 베스트 컷 분석은 지금 분석 중인 한 장을 끝내야 멈추므로, 그동안 멈추는 중으로 보인다.
    func testStoppedBurstAnalysisShowsStoppingUntilItEnds() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 0)
        model.isAnalyzingBursts = true
        model.burstCancellation = CancellationFlag()
        defer { model.isAnalyzingBursts = false; model.burstCancellation = nil }
        XCTAssertEqual(model.backgroundActivities.first { $0.kind == .bursts }?.isCancelling, false)

        model.cancelBackgroundActivity(.bursts)
        XCTAssertTrue(model.isCancellingBursts)
        XCTAssertEqual(model.backgroundActivities.first { $0.kind == .bursts }?.isCancelling, true, "멈추는 중으로 보인다")
    }

    /// 여러 장에 하는 작업도 하던 한 장을 끝내야 멈춘다. 멈추는 동안 그렇게 보이고, 다음 작업은 처음부터 멈추지 않은 상태다.
    func testStoppedWorkflowShowsStoppingUntilItEnds() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        let gate = DispatchSemaphore(value: 0)
        model.batchQueue.async { gate.wait() }

        model.createSmartPreviews(for: Set(model.photos.map(\.id)))
        XCTAssertEqual(model.backgroundActivities.first { $0.kind == .workflow }?.isCancelling, false)
        model.cancelBackgroundActivity(.workflow)
        XCTAssertTrue(model.isCancellingWorkflow)
        XCTAssertEqual(model.backgroundActivities.first { $0.kind == .workflow }?.isCancelling, true, "멈추는 중으로 보인다")

        gate.signal()
        try await TestSupport.wait("previews stopped") { !model.isRunningWorkflow }
        XCTAssertFalse(model.isCancellingWorkflow)
        model.findSimilarPhotos()
        XCTAssertEqual(model.backgroundActivities.first { $0.kind == .workflow }?.isCancelling, false)
        try await TestSupport.wait("similar") { !model.isRunningWorkflow }
    }
}
