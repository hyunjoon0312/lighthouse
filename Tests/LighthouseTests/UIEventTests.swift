import AppKit
import SwiftUI
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 합성한 마우스 클릭이 사진 보기의 SwiftUI 제스처까지 가서 누른 위치에 작동하는지 본다.
/// 창을 화면 순서에 올려야 클릭이 전달되므로 `LIGHTHOUSE_UI_EVENTS`를 줄 때만 돈다. 앱이 활성화되지 않아도
/// (화면 잠금 중 등) 첫 클릭이 뷰에 가도록 테스트용 호스팅 뷰가 첫 클릭을 받는다.
/// 트랙패드 핀치는 합성한 확대 이벤트를 SwiftUI가 제스처로 잇지 않아 여기서 확인하지 않는다(핀치도 클릭 확대와 같은
/// 좌표 변환을 쓴다). 커서 모양도 앱이 활성화되어야 바뀌어 확인하지 않는다.
@MainActor
final class UIEventTests: XCTestCase {
    private let size = CGSize(width: 1440, height: 900)

    private final class FirstMouseHost: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// `point`는 창 왼쪽 위 기준 좌표다.
    private func click(_ window: NSWindow, _ point: CGPoint) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// 위쪽은 푸른 회색, 아래쪽은 붉은 회색인 3:2 사진.
    private func writeSplitPhoto(_ url: URL) throws {
        let width = 120, height = 80
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let color: [UInt8] = y < height / 2 ? [150, 160, 190] : [190, 160, 150]
            for x in 0..<width { bytes.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 3, with: color) }
        }
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testClickZoomAndGrayPickUseTheClickedPlace() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_UI_EVENTS"] != nil else {
            throw XCTSkip("LIGHTHOUSE_UI_EVENTS를 주면 창을 띄워 클릭 확대·회색 찍기를 확인한다.")
        }
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let url = root.appendingPathComponent("photos/split.jpg")
        try writeSplitPhoto(url)
        model.importURLs([url])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 1 }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = FirstMouseHost(rootView: AnyView(WorkspaceView().environmentObject(model)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        model.select(model.visiblePhotos[0])
        model.setMode(.edit)
        try await TestSupport.wait("render") { model.rendered != nil }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // 두 곳을 눌러 화면 위치가 사진 좌표(왼쪽 위 0, 오른쪽 아래 1)로 바뀌는 비율을 잰다.
        let first = CGPoint(x: 680, y: 470), second = CGPoint(x: 780, y: 530)
        var anchors: [CGPoint] = []
        for point in [first, second] {
            try await click(window, point)
            try await TestSupport.wait("click zoom", timeout: 5) { model.actualSize }
            anchors.append(model.zoomAnchor)
            model.toggleActualSize()
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        let perPointX = (anchors[1].x - anchors[0].x) / 100, perPointY = (anchors[1].y - anchors[0].y) / 60
        XCTAssertGreaterThan(perPointX, 0, "오른쪽을 누르면 사진의 오른쪽을 연다")
        XCTAssertGreaterThan(perPointY, 0, "아래를 누르면 사진의 아래쪽을 연다(위아래가 뒤집히지 않는다)")
        XCTAssertEqual(perPointX / perPointY, 80.0 / 120.0, accuracy: 0.03, "가로세로가 같은 배율로 맞춰진다")

        // 회색 찍기: 푸른 위쪽을 누르면 따뜻하게, 붉은 아래쪽을 누르면 차갑게 맞춘다.
        func place(_ anchor: CGPoint) -> CGPoint {
            CGPoint(x: first.x + (anchor.x - anchors[0].x) / perPointX, y: first.y + (anchor.y - anchors[0].y) / perPointY)
        }
        var shifts: [Double] = []
        for anchor in [CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 0.75)] {
            model.beginWhiteBalancePick()
            try await Task.sleep(nanoseconds: 400_000_000)
            try await click(window, place(anchor))
            try await TestSupport.wait("pick", timeout: 60) {
                !model.isAutoAdjusting && model.selection?.edits.temperatureShift != 0
            }
            XCTAssertFalse(model.isPickingWhiteBalance)
            shifts.append(model.selection?.edits.temperatureShift ?? 0)
            model.undo()
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        XCTAssertGreaterThan(shifts[0], 300, "위쪽(푸른 회색)을 누르면 따뜻하게")
        XCTAssertLessThan(shifts[1], -300, "아래쪽(붉은 회색)을 누르면 차갑게")
    }
}
