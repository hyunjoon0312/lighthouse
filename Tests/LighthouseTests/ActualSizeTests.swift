import AppKit
import SwiftUI
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 화면 맞춤에서 100%로 바꿀 때 원본 크기 렌더를 기다리는 동안 사진이 사라지지 않는다.
@MainActor
final class ActualSizeTests: XCTestCase {
    func testEnteringActualSizeShowsTheEnlargedPhotoUntilTheFullRenderArrives() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let url = root.appendingPathComponent("photos/large.jpg")
        try TestSupport.writeJPEG(url, width: 3000, height: 2000)
        model.importURLs([url])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 1 }
        model.focusPhoto(model.photos[0])
        model.updateEdits({ var edits = model.selection!.edits; edits.rotationQuarterTurns = 1; return edits }())
        model.setMode(.edit)
        try await TestSupport.wait("fit") { !model.rendering && model.rendered != nil }
        let fit = try XCTUnwrap(model.rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(fit.width, 1466, "화면 맞춤은 긴 변 2200px")

        model.toggleActualSize(at: CGPoint(x: 0.3, y: 0.4))
        let enlarged = try XCTUnwrap(model.rendered, "100%로 바꾼 즉시 사진이 사라지지 않는다")
        XCTAssertEqual(enlarged.size, CGSize(width: 2000, height: 3000), "회전을 반영한 원본 크기로 늘려 보인다")
        XCTAssertEqual(enlarged.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, fit.width)
        XCTAssertTrue(model.rendering)

        try await TestSupport.wait("full") { !model.rendering }
        let full = try XCTUnwrap(model.rendered)
        XCTAssertEqual(full.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 2000)
        XCTAssertEqual(full.size, enlarged.size, "선명한 그림으로 바뀌어도 크기가 같아 스크롤 위치가 그대로다")

        model.toggleActualSize()
        XCTAssertNotNil(model.rendered, "화면 맞춤으로 돌아올 때는 최근 그림을 바로 쓴다")
    }
}

/// 비교 보기 100%에서 두 칸이 같은 곳(사진 안 비율 위치)을 보이고 함께 스크롤한다. 창은 화면에 띄우지 않는다.
@MainActor
final class CompareZoomSyncTests: XCTestCase {
    /// 100% 칸들(내용이 보이는 칸보다 넓은 스크롤 뷰)의 가운데가 가리키는 사진 안 비율 위치. 왼쪽 칸부터.
    private func centers(_ host: NSView) -> [CGPoint] {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.width > scroll.contentView.bounds.width + 50 { found.append(scroll) }
            for subview in view.subviews { found += scrollViews(subview) }
            return found
        }
        return scrollViews(host)
            .sorted { $0.convert(NSPoint.zero, to: nil).x < $1.convert(NSPoint.zero, to: nil).x }
            .map { scroll in
                let document = scroll.documentView!.frame.size, visible = scroll.contentView.bounds
                let y = scroll.contentView.isFlipped ? visible.midY : document.height - visible.midY
                return CGPoint(x: visible.midX / document.width, y: y / document.height)
            }
    }

    private func assertBoth(_ host: NSView, at expected: CGPoint, _ label: String) {
        let found = centers(host)
        XCTAssertEqual(found.count, 2, label)
        for center in found {
            XCTAssertEqual(center.x, expected.x, accuracy: 0.01, label)
            XCTAssertEqual(center.y, expected.y, accuracy: 0.01, label)
        }
    }

    func testBothPanesShowAndFollowTheSameSpot() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        for (index, color) in [(40, 90, 140), (140, 90, 40), (90, 140, 40)].enumerated() {
            try TestSupport.writeJPEG(root.appendingPathComponent("photos/burst-\(index).jpg"), width: 3000, height: 2000,
                                      color: (UInt8(color.0), UInt8(color.1), UInt8(color.2)))
        }
        model.importURLs([root.appendingPathComponent("photos")])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 3 }
        let size = CGSize(width: 1440, height: 900)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkspaceView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        model.select(model.visiblePhotos[0])
        model.setMode(.compare)
        model.move(1)
        try await TestSupport.wait("fit") { model.rendered != nil && model.pinnedImage != nil && !model.rendering }
        try await Task.sleep(nanoseconds: 500_000_000)

        model.toggleActualSize(at: CGPoint(x: 0.62, y: 0.35))
        XCTAssertEqual(model.pinnedImage?.size, CGSize(width: 3000, height: 2000), "기준 사진도 바로 원본 크기로 늘려 보인다")
        try await Task.sleep(nanoseconds: 300_000_000)
        assertBoth(host, at: CGPoint(x: 0.62, y: 0.35), "100%로 바꾸면 두 칸 모두 누른 곳을 보인다")
        try await TestSupport.wait("full") { !model.rendering }
        try await Task.sleep(nanoseconds: 300_000_000)
        assertBoth(host, at: CGPoint(x: 0.62, y: 0.35), "선명한 그림이 와도 그대로다")

        // 사용자가 한 칸을 스크롤한 것처럼 보이는 위치를 옮기면 다른 칸이 따라온다.
        func drag(_ index: Int, by offset: CGPoint) async throws {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            let panes = scrollViews(host).filter { ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 50 }
                .sorted { $0.convert(NSPoint.zero, to: nil).x < $1.convert(NSPoint.zero, to: nil).x }
            let scroll = panes[index]
            var origin = scroll.contentView.bounds.origin
            for _ in 0..<4 {
                origin.x += offset.x / 4
                origin.y += (scroll.contentView.isFlipped ? offset.y : -offset.y) / 4
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try await drag(1, by: CGPoint(x: 240, y: 160))
        assertBoth(host, at: CGPoint(x: 0.70, y: 0.43), "현재 사진 칸을 스크롤하면 기준 사진 칸이 따라온다")
        try await drag(0, by: CGPoint(x: -480, y: -320))
        assertBoth(host, at: CGPoint(x: 0.54, y: 0.27), "기준 사진 칸을 스크롤하면 현재 사진 칸이 따라온다")

        model.move(1)
        try await TestSupport.wait("next") { !model.rendering && model.selectedID == model.visiblePhotos[2].id }
        try await Task.sleep(nanoseconds: 300_000_000)
        assertBoth(host, at: CGPoint(x: 0.54, y: 0.27), "다음 사진으로 넘겨도 보던 곳을 그대로 보인다")
    }
}
