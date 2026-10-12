import Combine
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 베스트 컷 분석은 결과를 컷마다 알리지 않고 모아서 알린다. 알릴 때마다 작업 화면 전체를 다시 계산하므로(보정 패널이
/// 열려 있으면 한 번에 약 40ms), 빨리 끝나는 컷이 많으면 화면이 분석 결과를 받느라 버벅였다.
@MainActor
final class BurstProgressBatchingTests: XCTestCase {
    func testResultsArriveInBatchesNotOncePerShot() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        // 없는 파일이라 컷마다 바로 실패로 끝난다. 0.1초 간격으로 찍은 한 묶음이다.
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let shots = 120
        model.photos += (0..<shots).map { index in
            PhotoAsset(url: folder.appendingPathComponent(String(format: "missing-%03d.jpg", index)),
                       metadata: PhotoMetadata(camera: "DC-S9", capturedAt: start.addingTimeInterval(Double(index) * 0.1)))
        }
        XCTAssertEqual(model.burstIndex.groups.count, 1)

        var reports = 0
        let watch = model.jobProgress.$bursts.dropFirst().sink { _ in reports += 1 }
        defer { watch.cancel() }
        let began = Date()
        model.analyzeBursts()
        try await TestSupport.wait("analysis") { !model.isAnalyzingBursts }
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertEqual(model.burstFailedIDs.count, shots, "모은 결과도 빠짐없이 들어온다")
        XCTAssertEqual(model.burstAnalysisProgress, 1)
        // 시작할 때 0으로 한 번, 0.25초마다 한 번, 첫 컷과 마지막에 한 번씩.
        XCTAssertLessThanOrEqual(reports, Int(elapsed / 0.25) + 3, "\(shots)컷을 \(String(format: "%.2f", elapsed))초에 \(reports)번 알림")
    }
}
