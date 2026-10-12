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
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 20)
        try await TestSupport.wait("idle") { !model.hasConflictingWorkflow }
        // 보정 패널 자체를 다시 배치하는 비용은 빼고 가운데 열만 본다.
        UserDefaults.standard.set(true, forKey: "showsSidebar")
        UserDefaults.standard.set(false, forKey: "showsInspector")
        addTeardownBlock {
            for key in ["showsSidebar", "showsInspector"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: AnyView(WorkspaceView().environmentObject(model)))
        addTeardownBlock { @MainActor in window.contentView = nil }
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // 10ms마다 깨어나는 박동이 빠진 만큼을 메인 스레드가 바빴던 시간으로 본다.
        var beats = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in beats += 1 }
        RunLoop.main.add(timer, forMode: .common)
        let changes = 30
        let start = CFAbsoluteTimeGetCurrent()
        for change in 0..<changes {
            model.burstAnalysisProgress = Double(change) / Double(changes)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        timer.invalidate()
        let perChange = max(0, elapsed - Double(beats) * 0.01) / Double(changes) * 1000
        XCTAssertLessThan(perChange, 60, "값 하나가 바뀔 때 다시 배치하는 데 약 \(Int(perChange))ms")
    }
}
