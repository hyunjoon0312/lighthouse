import AppKit
import SwiftUI
@testable import Lighthouse
import LighthouseCore
import ObjectiveC
import UniformTypeIdentifiers
import XCTest

/// 합성한 클릭·트랙패드 핀치·끌기가 실제 창의 SwiftUI 화면에서 누른 위치에 작동하는지 본다.
/// 창을 화면 순서에 올려야 클릭이 전달되고 끌기 중에는 마우스 포인터를 창 위로 옮기므로 `LIGHTHOUSE_UI_EVENTS`를 줄 때만
/// 돈다. 앱이 활성화되지 않아도(화면 잠금 중 등) 첫 클릭이 뷰에 가도록 테스트용 호스팅 뷰가 첫 클릭을 받는다.
/// 커서는 macOS가 활성 앱에만 바꾸므로, 커서 테스트에서는 이 테스트 안에서만 앱이 활성이고 창이 키 창인 것처럼 보이게 한다.
@MainActor
final class UIEventTests: XCTestCase {
    private let size = CGSize(width: 1440, height: 900)

    private final class FirstMouseHost: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// 창 내용 왼쪽 위 기준 좌표를 창 좌표(아래가 0)로 바꾼다. 창은 화면에 맞춰 줄어들 수 있다.
    private func windowPoint(_ window: NSWindow, _ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: (window.contentView?.bounds.height ?? size.height) - point.y)
    }

    private func mouse(_ window: NSWindow, _ type: NSEvent.EventType, _ point: CGPoint, clickCount: Int = 1) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: windowPoint(window, point), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    private func click(_ window: NSWindow, _ point: CGPoint) async throws {
        try await mouse(window, .leftMouseDown, point)
        try await mouse(window, .leftMouseUp, point)
    }

    /// 트랙패드 벌리기·오므리기. 공개 생성자가 없어 CGEvent 제스처(29)·확대 HID 형식(8)·배율(113)·단계(132)·창 번호(51)
    /// 필드로 만들고, 창 안 위치는 CoreGraphics의 `CGEventSetWindowLocation`으로 넣는다. 실제 트랙패드 이벤트처럼
    /// 앱 이벤트 흐름(`NSApp.sendEvent`)으로 보낸다.
    private func magnify(_ window: NSWindow, at point: CGPoint, by steps: [Double], end: Bool = true) async throws {
        typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
        let setWindowLocation = unsafeBitCast(symbol, to: SetWindowLocation.self)
        let inWindow = windowPoint(window, point)
        let phases = (steps.isEmpty ? [] : [(Int64(1), 0.0)]) + steps.map { (Int64(2), $0) } + (end ? [(Int64(4), 0.0)] : [])
        for (phase, amount) in phases {
            let event = try XCTUnwrap(CGEvent(source: nil))
            event.type = unsafeBitCast(UInt32(29), to: CGEventType.self)
            event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 110)), value: 8)
            event.setDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 113)), value: amount)
            event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 132)), value: phase)
            event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 51)), value: Int64(window.windowNumber))
            event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            setWindowLocation(event, CGPoint(x: inWindow.x, y: window.frame.height - inWindow.y))
            let converted = try XCTUnwrap(NSEvent(cgEvent: event))
            XCTAssertEqual(converted.type, .magnify)
            XCTAssertEqual(converted.window, window)
            XCTAssertEqual(converted.locationInWindow, inWindow)
            NSApp.sendEvent(converted)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 실제 마우스 포인터를 창 안의 그 위치로 옮긴다(끌기는 포인터가 있는 곳에 놓인다).
    private func moveCursor(_ window: NSWindow, _ point: CGPoint) throws {
        let screen = window.convertPoint(toScreen: windowPoint(window, point))
        let mainHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: mainHeight - screen.y))
    }

    /// 포인터를 창 안의 그 위치로 옮긴 것처럼 추적 영역 소유자에게 마우스 이동을 넘기고, 그때의 커서를 돌려준다.
    /// 실제로는 창 서버가 활성 앱의 추적 영역에 마우스 이동을 보낸다.
    private func hover(_ window: NSWindow, _ host: NSView, at point: CGPoint) async throws -> NSCursor {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: windowPoint(window, point), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        for area in host.trackingAreas where area.options.contains(.mouseMoved) {
            // SwiftUI의 커서 담당(PointerBridge)은 NSResponder가 아니어서 셀렉터로 보낸다.
            if let owner = area.owner as? NSObject, owner.responds(to: #selector(NSResponder.mouseMoved(with:))) {
                owner.perform(#selector(NSResponder.mouseMoved(with:)), with: event)
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        return NSCursor.current
    }

    /// 테스트 안에서만 앱이 활성인 것처럼 보이게 한다(커서·포인터 올림은 활성 앱에만 반응한다). 돌려받은 함수로 되돌린다.
    private func pretendActive() throws -> () -> Void {
        let isActive = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)))
        let alwaysActive: @convention(block) (AnyObject) -> Bool = { _ in true }
        let original = method_setImplementation(isActive, imp_implementationWithBlock(alwaysActive))
        return { method_setImplementation(isActive, original) }
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

    func testClickPinchAndGrayPickUseTheTouchedPlace() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_UI_EVENTS"] != nil else {
            throw XCTSkip("LIGHTHOUSE_UI_EVENTS를 주면 창을 띄워 클릭 확대·핀치·회색 찍기를 확인한다.")
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

        // 벌리면 손을 떼기 전에 벌린 곳을 100%로 열고, 100%에서 오므리면 화면 맞춤으로 돌아간다. 조금만 벌리면 그대로다.
        try await magnify(window, at: first, by: [0.1, 0.1], end: false)
        try await TestSupport.wait("pinch out", timeout: 5) { model.actualSize }
        try await magnify(window, at: first, by: [0.1])
        XCTAssertTrue(model.actualSize, "같은 핀치를 계속 벌려도 한 번만 바뀐다")
        XCTAssertEqual(model.zoomAnchor.x, anchors[0].x, accuracy: 0.01, "클릭 확대와 같은 곳을 연다")
        XCTAssertEqual(model.zoomAnchor.y, anchors[0].y, accuracy: 0.01)
        try await Task.sleep(nanoseconds: 400_000_000)
        try await magnify(window, at: first, by: [-0.08, -0.08])
        try await TestSupport.wait("pinch in", timeout: 5) { !model.actualSize }
        try await Task.sleep(nanoseconds: 400_000_000)
        try await magnify(window, at: first, by: [0.05, 0.05])
        try await magnify(window, at: CGPoint(x: 5, y: 5), by: [0.2])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(model.actualSize, "조금만 벌리거나 사진 칸 밖에서 벌리면 그대로다")

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

    /// AppKit이 파일 약속 메타데이터를 더할 수 있지만 실제 내용은 앱 전용 사진 ID이고 원본 이미지·글자·파일 URL은 없어야 한다.
    /// 합성 이벤트로 시작한 끌기는 실제 마우스 떼기를 기다리므로 이 프로세스에만 마우스 떼기를 보내 끝낸다.
    func testDraggingPhotosOnlyCarriesAppIDs() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_UI_EVENTS"] != nil else {
            throw XCTSkip("LIGHTHOUSE_UI_EVENTS를 주면 창을 띄워 끌기를 확인한다.")
        }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 4)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = FirstMouseHost(rootView: AnyView(WorkspaceView().environmentObject(model)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let photos = model.visiblePhotos
        let board = NSPasteboard(name: .drag)
        let before = board.changeCount
        // 그리드 첫 줄 두 번째 칸에서 오른쪽 아래로 끈다.
        let start = CGPoint(x: 570, y: 230)
        try moveCursor(window, start)
        try await mouse(window, .leftMouseDown, start)
        for step in 1...8 {
            try await mouse(window, .leftMouseDragged, CGPoint(x: start.x + CGFloat(step * 12), y: start.y + CGFloat(step * 6)))
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThan(board.changeCount, before, "끌기가 시작된다")
        let appType = NSPasteboard.PasteboardType(UTType.lighthousePhotos.identifier)
        XCTAssertTrue(board.types?.contains(appType) == true)
        let payload = try XCTUnwrap(board.data(forType: appType))
        XCTAssertEqual(try JSONDecoder().decode(PhotoDragItem.self, from: payload).ids, [photos[1].id])

        let publicTypes: [NSPasteboard.PasteboardType] = [.string, .fileURL, .URL, .png, .tiff]
        XCTAssertNil(board.availableType(from: publicTypes))
        XCTAssertNil(board.data(forType: .string))
        XCTAssertNil(board.data(forType: .fileURL))
        XCTAssertNil(board.string(forType: .string))

        let promisedContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        if board.types?.contains(promisedContentType) == true {
            XCTAssertEqual(board.propertyList(forType: promisedContentType) as? String,
                           UTType.lighthousePhotos.identifier)
        }
        let promisedFileURL = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
        XCTAssertTrue(board.data(forType: promisedFileURL)?.isEmpty ?? true)

        let end = CGPoint(x: start.x + 96, y: start.y + 48)
        try moveCursor(window, end)
        let screen = window.convertPoint(toScreen: windowPoint(window, end))
        let mainHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                              mouseCursorPosition: CGPoint(x: screen.x, y: mainHeight - screen.y), mouseButton: .left))
            .postToPid(getpid())
        try await mouse(window, .leftMouseUp, end)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // 끌기가 끝나 다시 클릭을 받는다. 그리드 안에 놓은 사진은 아무 곳에도 들어가지 않는다.
        try await click(window, CGPoint(x: 350 + 2 * 221, y: 230))
        try await TestSupport.wait("click after drag", timeout: 5) { model.selectedID == photos[2].id }
        XCTAssertEqual(model.photos.count, 4)
    }

    /// 회색 찍기 중에는 사진 칸 위에서 십자 커서가 되고, 칸 밖이나 찍기를 끝낸 뒤에는 돌아온다.
    /// 실제로는 창 서버가 활성 앱의 추적 영역에 마우스 이동을 보내므로, 여기서는 추적 영역 소유자에게 직접 넘긴다.
    func testGrayPickShowsCrosshairOverThePhoto() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_UI_EVENTS"] != nil else {
            throw XCTSkip("LIGHTHOUSE_UI_EVENTS를 주면 창을 띄워 회색 찍기 커서를 확인한다.")
        }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let restoreActive = try pretendActive()
        defer { restoreActive() }
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
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

        func cursor(at point: CGPoint) async throws -> NSCursor { try await hover(window, host, at: point) }
        let photo = CGPoint(x: 680, y: 470), sidebar = CGPoint(x: 100, y: 600)
        let before = try await cursor(at: photo)
        XCTAssertNotEqual(before, .crosshair, "찍기 전에는 보통 커서")
        model.beginWhiteBalancePick()
        try await Task.sleep(nanoseconds: 500_000_000)
        let picking = try await cursor(at: photo)
        XCTAssertEqual(picking, .crosshair, "찍는 중 사진 칸 위는 십자 커서")
        let outside = try await cursor(at: sidebar)
        XCTAssertNotEqual(outside, .crosshair, "사진 칸 밖은 보통 커서")
        let back = try await cursor(at: photo)
        XCTAssertEqual(back, .crosshair)
        model.isPickingWhiteBalance = false
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = try await cursor(at: photo)
        XCTAssertNotEqual(after, .crosshair, "찍기를 끝내면 돌아온다")
    }

    /// 사이드바 경계선 위에서는 좌우 조절 커서가 되고, 끌면 너비가 바뀌어 기억되며, 두 번 누르면 기본 너비로 돌아온다.
    func testPanelEdgeDragResizesAndDoubleClickResets() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_UI_EVENTS"] != nil else {
            throw XCTSkip("LIGHTHOUSE_UI_EVENTS를 주면 창을 띄워 패널 경계선 끌기를 확인한다.")
        }
        UserDefaults.standard.removeObject(forKey: "sidebarWidth")
        defer { UserDefaults.standard.removeObject(forKey: "sidebarWidth") }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let restoreActive = try pretendActive()
        defer { restoreActive() }
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                               backing: .buffered, defer: false)
        let host = FirstMouseHost(rootView: AnyView(WorkspaceView().environmentObject(model)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 기본 사이드바 224pt 오른쪽의 1pt 경계선. 잡는 영역은 양옆으로 넓다.
        let edge = CGPoint(x: 226, y: 600), inSidebar = CGPoint(x: 100, y: 600)
        let plain = try await hover(window, host, at: inSidebar)
        let resize = try await hover(window, host, at: edge)
        XCTAssertNotEqual(resize, plain, "경계선 위에서는 커서가 바뀐다")
        XCTAssertNotEqual(resize, .arrow)

        try await mouse(window, .leftMouseDown, edge)
        for step in 1...6 {
            try await mouse(window, .leftMouseDragged, CGPoint(x: edge.x + CGFloat(step * 10), y: edge.y))
        }
        try await mouse(window, .leftMouseUp, CGPoint(x: edge.x + 60, y: edge.y))
        try await TestSupport.wait("resize", timeout: 5) {
            abs(UserDefaults.standard.double(forKey: "sidebarWidth") - 284) < 1
        }

        let moved = CGPoint(x: edge.x + 60, y: edge.y)
        try await mouse(window, .leftMouseDown, moved)
        try await mouse(window, .leftMouseUp, moved)
        try await mouse(window, .leftMouseDown, moved, clickCount: 2)
        try await mouse(window, .leftMouseUp, moved, clickCount: 2)
        try await TestSupport.wait("reset", timeout: 5) {
            UserDefaults.standard.double(forKey: "sidebarWidth") == PanelLayout.sidebarDefault
        }
    }

    /// 그리드 칸의 선택 원은 평소 숨어 있어 누르면 칸을 고르고, 포인터를 올린 칸에서는 보여 눌러 여러 장을 고른다.
    func testHoverRevealsSelectionToggle() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_UI_EVENTS"] != nil else {
            throw XCTSkip("LIGHTHOUSE_UI_EVENTS를 주면 창을 띄워 포인터 올림을 확인한다.")
        }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 4)
        let restoreActive = try pretendActive()
        defer { restoreActive() }
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                               backing: .buffered, defer: false)
        let host = FirstMouseHost(rootView: AnyView(WorkspaceView().environmentObject(model)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        let photos = model.visiblePhotos
        model.select(photos[0])
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 1440×900 그리드 첫 줄 칸의 오른쪽 위 선택 원 가운데.
        func toggle(_ column: Int) -> CGPoint { CGPoint(x: 428 + CGFloat(column) * 221, y: 137) }
        _ = try await hover(window, host, at: CGPoint(x: 100, y: 600))
        try await click(window, toggle(2))
        try await TestSupport.wait("plain click selects tile", timeout: 5) { model.selectedPhotoIDs == [photos[2].id] }

        _ = try await hover(window, host, at: toggle(1))
        try await click(window, toggle(1))
        try await TestSupport.wait("hover toggle adds", timeout: 5) {
            model.selectedPhotoIDs == [photos[2].id, photos[1].id]
        }
    }

    /// 단추와 사이드바 줄은 그림이 없는 빈 곳을 눌러도 동작한다. 보이는 모양 전체가 누름 영역이다.
    func testButtonsAndSidebarRowsAcceptClicksAcrossTheirShape() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTHOUSE_UI_EVENTS"] != nil else {
            throw XCTSkip("LIGHTHOUSE_UI_EVENTS를 주면 창을 띄워 누름 영역을 확인한다.")
        }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = FirstMouseHost(rootView: AnyView(WorkspaceView().environmentObject(model)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        model.select(model.visiblePhotos[0])
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 1440×900 창의 사진 보기 단추(34×28, 가운데 x 424) 왼쪽 안쪽 3pt. 아이콘 밖이다.
        try await click(window, CGPoint(x: 410, y: 26))
        try await TestSupport.wait("mode button edge", timeout: 5) { model.mode == .edit }
        model.setMode(.grid)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 사이드바 "채택됨" 줄(가운데 y 146)의 위쪽 여백과, 글자와 개수 사이 빈 곳.
        try await click(window, CGPoint(x: 150, y: 134))
        try await TestSupport.wait("row padding", timeout: 5) { model.filter == .picks }
        model.filter = .all
        try await Task.sleep(nanoseconds: 300_000_000)
        try await click(window, CGPoint(x: 150, y: 146))
        try await TestSupport.wait("row spacer", timeout: 5) { model.filter == .picks }
    }
}
