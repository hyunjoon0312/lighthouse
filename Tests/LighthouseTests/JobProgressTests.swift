import Combine
import Foundation
@testable import Lighthouse
import XCTest

/// 오래 도는 작업의 진행값은 모델에서 떼어 둔다. 모델 값이 바뀌면 모델 전체를 지켜보는 화면이 모두 다시 계산되는데
/// (보정 패널이 열려 있으면 한 번에 약 40ms), 진행값은 파일 한 장·컷 하나마다 바뀌므로 진행 막대와 작업 목록만 지켜보게 한다.
@MainActor
final class JobProgressTests: XCTestCase {
    func testProgressChangesDoNotNotifyWholeModelObservers() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 0)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        var modelChanges = 0
        let watch = model.objectWillChange.sink { _ in modelChanges += 1 }
        defer { watch.cancel() }

        model.operationProgress = 0.5
        model.workflowProgress = 0.5
        model.faceAnalysisTotal = 10
        model.faceAnalysisCompleted += 1
        model.burstAnalysisProgress = 0.5
        XCTAssertEqual(modelChanges, 0, "진행값이 바뀌어도 모델 전체를 지켜보는 화면은 다시 계산되지 않는다")
    }

    /// 가져오는 동안 몇 번째 파일인지 보이던 문구는 끝나면 결과 안내에 자리를 넘긴다. 그동안 모델 전체는 파일마다 알리지 않는다.
    func testImportStepGivesWayToTheSummaryWithoutPerFileModelChanges() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        let folder = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = 30
        for index in 0..<count { try TestSupport.writeJPEG(folder.appendingPathComponent("p\(index).jpg")) }
        var steps = Set<String>()
        let stepWatch = model.jobProgress.$operationStep.sink { if let step = $0 { steps.insert(step) } }
        var modelChanges = 0
        let modelWatch = model.objectWillChange.sink { _ in modelChanges += 1 }
        defer { stepWatch.cancel(); modelWatch.cancel() }

        model.importURLs([folder])
        try await TestSupport.wait("import") { !model.isImporting }
        XCTAssertTrue(steps.contains("가져오는 중 \(count)/\(count)"), "가져오는 동안 몇 번째 파일인지 보인다")
        XCTAssertNil(model.jobProgress.operationStep, "끝나면 결과 안내가 보인다")
        XCTAssertTrue(model.operationMessage?.contains("\(count)장 가져옴") == true, model.operationMessage ?? "")
        XCTAssertLessThan(modelChanges, count, "파일마다 모델 전체에 알리지 않는다")
    }
}
