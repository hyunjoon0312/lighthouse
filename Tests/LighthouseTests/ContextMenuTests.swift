import AppKit
import SwiftUI
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 그리드 사진 칸을 오른쪽 클릭했을 때 SwiftUI가 만드는 실제 메뉴를 받아 항목을 실행한다. 메뉴와 창은 화면에 띄우지 않는다.
@MainActor
final class ContextMenuTests: XCTestCase {
    private let size = CGSize(width: 1440, height: 900)

    /// 1440×900 창에서 그리드 첫 줄 칸의 가운데(창 좌표, 아래가 0).
    private func tileCenter(_ column: Int) -> NSPoint {
        NSPoint(x: 350 + CGFloat(column) * 221, y: size.height - 230)
    }

    private func menu(_ window: NSWindow, _ host: NSView, column: Int) throws -> NSMenu {
        try menu(window, host, at: tileCenter(column), "\(column)번째 칸")
    }

    private func menu(_ window: NSWindow, _ host: NSView, at point: NSPoint, _ label: String) throws -> NSMenu {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // 누른 곳의 SwiftUI 칸이 메뉴를 주지 않으면 호스팅 뷰가 그 위치의 메뉴를 준다.
        return try XCTUnwrap(host.hitTest(point)?.menu(for: event) ?? host.menu(for: event),
                             "\(label)에 오른쪽 클릭 메뉴가 없다")
    }

    private func choose(_ path: [String], in menu: NSMenu) throws {
        var current = menu
        for (depth, title) in path.enumerated() {
            let index = current.indexOfItem(withTitle: title)
            guard index >= 0 else { return XCTFail("메뉴에 \(title) 항목이 없다: \(current.items.map(\.title))") }
            if depth == path.count - 1 {
                current.performActionForItem(at: index)
            } else {
                current = try XCTUnwrap(current.item(at: index)?.submenu)
            }
        }
    }

    func testRightClickActsOnClickedPhotoOrWholeSelection() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 4)
        var revealed: [URL] = []
        model.revealInFinder = { revealed = $0 }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkspaceView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        let photos = model.visiblePhotos
        func current(_ index: Int) -> PhotoAsset? { model.photos.first { $0.id == photos[index].id } }
        model.select(photos[0])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()

        let first = try menu(window, host, column: 1)
        XCTAssertEqual(first.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["별점", "표시", "색상 라벨", "폴더에 추가", "사진 보기에서 열기", "가상 사본 만들기",
                        "Finder에서 원본 보기", "내보내기…", "카탈로그에서 빼기…"])
        // 고르지 않은 사진을 누르면 그 사진만 현재 사진이 되어 바뀐다.
        try choose(["별점", "★★★"], in: first)
        XCTAssertEqual(model.selectedID, photos[1].id)
        XCTAssertEqual(current(1)?.rating, 3)
        XCTAssertEqual(current(0)?.rating, 0)

        // 고른 사진 중 하나를 누르면 고른 사진 모두에 붙는다.
        model.togglePhotoSelection(photos[2])
        try await Task.sleep(nanoseconds: 300_000_000)
        try choose(["표시", "채택"], in: menu(window, host, column: 2))
        XCTAssertEqual((0..<4).map { current($0)?.flag }, [PhotoFlag.none, .pick, .pick, PhotoFlag.none])

        // 고른 것 밖의 사진은 그 사진만.
        try choose(["색상 라벨", "빨강"], in: menu(window, host, column: 3))
        XCTAssertEqual((0..<4).map { current($0)?.colorLabel }, [nil, nil, nil, .red])
        XCTAssertEqual(model.selectedPhotoIDs, [photos[3].id])

        try await Task.sleep(nanoseconds: 300_000_000)
        try choose(["Finder에서 원본 보기"], in: menu(window, host, column: 0))
        XCTAssertEqual(revealed, [photos[0].url])

        try choose(["사진 보기에서 열기"], in: menu(window, host, column: 1))
        XCTAssertEqual(model.mode, .edit)
        XCTAssertEqual(model.selectedID, photos[1].id)
    }

    /// 색상 라벨 메뉴는 붙인 이름을 함께 보이고(블로그 · 빨강), 이름을 정하는 창을 연다.
    func testLabelSubmenuShowsNamesAndOffersRenaming() async throws {
        UserDefaults.standard.removeObject(forKey: "colorLabelNames")
        defer { UserDefaults.standard.removeObject(forKey: "colorLabelNames") }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        model.setColorLabelNames([.red: "블로그"])
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkspaceView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        let photos = model.visiblePhotos
        model.select(photos[0])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()

        let labels = try XCTUnwrap(menu(window, host, column: 0).item(withTitle: "색상 라벨")?.submenu)
        XCTAssertEqual(labels.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["블로그 · 빨강", "노랑", "초록", "파랑", "보라", "라벨 떼기", "라벨 이름 정하기…"])
        try choose(["색상 라벨", "블로그 · 빨강"], in: menu(window, host, column: 0))
        XCTAssertEqual(model.photo(withID: photos[0].id)?.colorLabel, .red)
        try choose(["색상 라벨", "라벨 이름 정하기…"], in: menu(window, host, column: 0))
        XCTAssertTrue(model.showColorLabelNames)
    }

    /// 오른쪽 패널의 묶음 제목을 오른쪽 클릭하면 그 묶음 값만 기본값으로 돌리고, ⌘Z 한 번으로 돌아온다.
    func testSectionHeaderMenuResetsOnlyThatSection() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkspaceView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        model.select(model.visiblePhotos[0])
        model.setMode(.edit)
        var edits = try XCTUnwrap(model.selection).edits
        edits.exposure = 0.8; edits.contrast = 1.2; edits.vibrance = 0.3
        model.updateEdits(edits)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()

        // 오른쪽 패널(x 1140–1440)을 위에서부터 오른쪽 클릭해 "빛" 제목 줄을 찾는다.
        let title = "‘빛’ 초기화"
        let found = try stride(from: 60, to: size.height - 20, by: 4).lazy.compactMap { top -> NSMenu? in
            let point = NSPoint(x: 1190, y: size.height - top)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = host.hitTest(point)?.menu(for: event) ?? host.menu(for: event)
            return menu?.indexOfItem(withTitle: title) ?? -1 >= 0 ? menu : nil
        }.first
        let menu = try XCTUnwrap(found, "빛 제목 줄의 오른쪽 클릭 메뉴가 없다")
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: title)).isEnabled, "바뀐 묶음은 초기화할 수 있다")
        try choose([title], in: menu)
        var current = try XCTUnwrap(model.selection).edits
        XCTAssertEqual(current.exposure, EditSettings.neutral.exposure)
        XCTAssertEqual(current.contrast, EditSettings.neutral.contrast)
        XCTAssertEqual(current.vibrance, 0.3, "색상 묶음은 그대로")

        model.undo()
        current = try XCTUnwrap(model.selection).edits
        XCTAssertEqual(current.exposure, 0.8)
        XCTAssertEqual(current.contrast, 1.2)
    }

    /// 보정 묶음 제목 줄의 "한 묶음만 펴기"를 켜면 그 묶음만 펴고 다른 보정 묶음을 접는다. 키워드·설명 묶음은 그대로다.
    func testSectionHeaderMenuTurnsOnSoloMode() async throws {
        let keys = ["light", "color", "geometry", "marks"].map { "inspector.section." + $0 }
        let clear = { for key in keys + [InspectorSolo.settingKey] { UserDefaults.standard.removeObject(forKey: key) } }
        clear()
        defer { clear() }
        UserDefaults.standard.set(false, forKey: "inspector.section.light")
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkspaceView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        model.select(model.visiblePhotos[0])
        model.setMode(.edit)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()

        // 접어 둔 "빛" 제목 줄에서 켠다.
        let title = "한 묶음만 펴기"
        let found = try stride(from: 60, to: size.height - 20, by: 4).lazy.compactMap { top -> NSMenu? in
            let point = NSPoint(x: 1190, y: size.height - top)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = host.hitTest(point)?.menu(for: event) ?? host.menu(for: event)
            return menu?.indexOfItem(withTitle: "‘빛’ 초기화") ?? -1 >= 0 ? menu : nil
        }.first
        let menu = try XCTUnwrap(found, "빛 제목 줄의 오른쪽 클릭 메뉴가 없다")
        XCTAssertEqual(try XCTUnwrap(menu.item(withTitle: title)).state, .off)
        try choose([title], in: menu)

        let defaults = UserDefaults.standard
        XCTAssertTrue(defaults.bool(forKey: InspectorSolo.settingKey))
        XCTAssertTrue(defaults.bool(forKey: "inspector.section.light"), "누른 묶음은 펼친다")
        XCTAssertFalse(defaults.bool(forKey: "inspector.section.color"), "다른 보정 묶음은 접는다")
        XCTAssertFalse(defaults.bool(forKey: "inspector.section.geometry"))
        XCTAssertNil(defaults.object(forKey: "inspector.section.marks"), "키워드·설명 묶음은 건드리지 않는다")
    }

    /// 사진 보기의 필름 스트립과 여러 장 보기에서는 고른 사진이 여러 장이어도 누른 사진 한 장에 적용하고 그 사진을 기준으로 삼는다.
    func testRightClickInFilmstripAndSurveyActsOnClickedPhoto() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 4)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkspaceView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.contentView = nil }
        let photos = model.visiblePhotos
        func current(_ index: Int) -> PhotoAsset? { model.photos.first { $0.id == photos[index].id } }
        model.select(photos[0])
        model.setMode(.edit)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()

        // 필름 스트립 세 번째 칸(1440×900 창의 아래쪽 줄).
        try choose(["표시", "제외"], in: menu(window, host, at: NSPoint(x: 285 + 2 * 100, y: 54), "필름 스트립 칸"))
        XCTAssertEqual((0..<4).map { current($0)?.flag }, [PhotoFlag.none, PhotoFlag.none, .reject, PhotoFlag.none])
        XCTAssertEqual(model.selectedID, photos[2].id)

        // 여러 장 보기: 세 장을 골라 두 번째 칸을 누르면 그 사진에만 별점이 붙는다.
        model.setMode(.grid)
        model.select(photos[1])
        for photo in photos[2...3] { model.togglePhotoSelection(photo) }
        model.setMode(.survey)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try choose(["별점", "★★"], in: menu(window, host, at: NSPoint(x: 906, y: size.height - 274), "여러 장 보기 칸"))
        XCTAssertEqual((0..<4).map { current($0)?.rating }, [0, 0, 2, 0])
        XCTAssertEqual(model.selectedID, photos[2].id)
    }
}
