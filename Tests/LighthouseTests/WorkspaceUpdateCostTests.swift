import AppKit
import SwiftUI
@testable import Lighthouse
import XCTest

/// 모델 값이 하나 바뀔 때 작업 화면을 다시 배치하는 비용. 사이드바가 있을 때 가운데 열의 너비가 정해지지 않으면
/// 가로 줄이 가운데 열 전체(위쪽 막대·고르기 막대의 AppKit 컨트롤까지)를 여러 번 재 보느라 한 번에 130ms 넘게 걸렸고,
/// 베스트 컷 분석처럼 결과를 자주 알리는 작업 동안 메인 스레드가 거의 쉬지 못해 진행 막대가 멈춘 듯 보였다.
@MainActor
final class WorkspaceUpdateCostTests: XCTestCase {
    func testOneModelChangeDoesNotRemeasureTheWholeCenterColumn() async throws {
        // 보정 패널 자체를 다시 배치하는 비용은 빼고 가운데 열만 본다. 가운데 열 아래 상태 줄의 안내를 바꾼다.
        let perChange = try await costPerChange(inspector: false) { model, value in model.operationMessage = "안내 \(value)" }
        XCTAssertLessThan(perChange, 60, "값 하나가 바뀔 때 다시 배치하는 데 약 \(Int(perChange))ms")
    }

    /// 진행값은 모델에서 떼어 두어(`JobProgress`) 바뀌어도 진행 막대만 다시 그린다. 모델에 있을 때는 두 패널을 모두 켜면
    /// 한 번에 debug 150ms 넘게, release 약 58ms가 들었다.
    func testProgressChangeDoesNotRecomputeTheWorkspace() async throws {
        let perChange = try await costPerChange(inspector: true) { model, value in model.burstAnalysisProgress = value }
        XCTAssertLessThan(perChange, 10, "진행값 하나가 바뀔 때 약 \(Int(perChange))ms")
    }

    /// 모델은 화면이 실제로 읽은 값이 바뀔 때만 그 화면을 다시 계산한다(`@Observable`). 모델 전체를 지켜볼 때는
    /// 보정 패널이 읽지 않는 값이 바뀌어도 두 패널을 모두 켜면 한 번에 debug 150ms 넘게 들었다.
    func testUnrelatedModelChangeDoesNotRecomputeTheWorkspace() async throws {
        let perChange = try await costPerChange(inspector: true) { model, value in model.burstMessage = "\(value)" }
        XCTAssertLessThan(perChange, 10, "보정 패널이 읽지 않는 값 하나가 바뀔 때 약 \(Int(perChange))ms")
    }

    /// 사진 20장인 작업 화면을 1400×900 창에 띄우고 0.1초마다 30번 `change`를 부른다.
    /// 10ms마다 깨어나는 박동이 빠진 만큼을 메인 스레드가 바빴던 시간으로 보고 한 번당 ms로 돌려준다.
    private func costPerChange(inspector: Bool, _ change: (LibraryModel, Double) -> Void) async throws -> Double {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 20)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        UserDefaults.standard.set(true, forKey: "showsSidebar")
        UserDefaults.standard.set(inspector, forKey: "showsInspector")
        addTeardownBlock {
            for key in ["showsSidebar", "showsInspector"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: AnyView(WorkspaceView().environment(model)))
        addTeardownBlock { @MainActor in window.contentView = nil }
        try await Task.sleep(nanoseconds: 2_000_000_000)

        var beats = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in beats += 1 }
        RunLoop.main.add(timer, forMode: .common)
        let changes = 30
        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<changes {
            change(model, Double(index) / Double(changes))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        timer.invalidate()
        return max(0, elapsed - Double(beats) * 0.01) / Double(changes) * 1000
    }
}
