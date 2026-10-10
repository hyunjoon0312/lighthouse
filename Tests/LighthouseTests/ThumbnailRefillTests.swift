import AppKit
import SwiftUI
@testable import Lighthouse
import XCTest

/// 화면에 보이는 칸의 썸네일이 메모리에서 지워져도 스크롤하지 않고 다시 채워진다.
/// 지우는 경우는 둘이다: 메모리가 모자라 시스템이 캐시를 비울 때, 스마트 미리보기를 만들거나 원본이 돌아와 앱이 비울 때.
@MainActor
final class ThumbnailRefillTests: XCTestCase {
    /// 창 밖 화면은 다시 그리는 때가 들쭉날쭉하므로, 기다리는 동안 배치를 직접 돌려 칸의 변화 감지를 바로 일으킨다.
    private func hostedModel(mode: WorkspaceMode) async throws -> (LibraryModel, NSHostingView<AnyView>) {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 4)
        if mode != .grid {
            model.focusPhoto(model.photos[0])
            model.setMode(mode)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(WorkspaceView().environmentObject(model)))
        window.contentView = host
        addTeardownBlock { @MainActor in window.contentView = nil }
        try await TestSupport.wait("first thumbnails", timeout: 20) { Self.shown(host, model) == 4 }
        return (model, host)
    }

    private static func shown(_ host: NSView, _ model: LibraryModel) -> Int {
        host.layoutSubtreeIfNeeded()
        return model.photos.filter { model.thumbnail(for: $0) != nil }.count
    }

    func testGridRefillsAfterTheAppClearsThumbnails() async throws {
        let (model, host) = try await hostedModel(mode: .grid)
        model.invalidateWorkflowRenderCaches()
        XCTAssertTrue(model.photos.allSatisfy { model.thumbnail(for: $0) == nil })
        try await TestSupport.wait("refill", timeout: 20) { Self.shown(host, model) == 4 }
    }

    func testGridRefillsAfterTheSystemEvictsThumbnails() async throws {
        let (model, host) = try await hostedModel(mode: .grid)
        model.thumbnailCache.removeAllObjects()
        // 시스템이 비울 때는 알림이 없다. 다음에 화면이 다시 그려질 때(다른 변경이 있을 때) 채운다.
        model.objectWillChange.send()
        try await TestSupport.wait("refill", timeout: 20) { Self.shown(host, model) == 4 }
    }

    func testFilmstripRefillsAfterTheAppClearsThumbnails() async throws {
        let (model, host) = try await hostedModel(mode: .edit)
        model.invalidateWorkflowRenderCaches()
        try await TestSupport.wait("refill", timeout: 20) { Self.shown(host, model) == 4 }
    }
}
