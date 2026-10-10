import AppKit
import SwiftUI
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 화면 캡처·접근성 권한 없이 주요 화면을 PNG로 그려 눈으로 점검하는 도구다. `LIGHTHOUSE_SNAPSHOT_DIR`을 줄 때만 돌고
/// 평소 `swift test`에서는 건너뛴다. 창을 화면에 띄우지 않고 `NSHostingView`를 창 밖에서 그리므로 실제 화면과
/// 조금 다를 수 있다(날짜 칸 등 일부 AppKit 컨트롤). 사진은 `LIGHTHOUSE_SNAPSHOT_PHOTOS` 폴더의 복사본을 쓰고, 없으면 만든 사진과
/// S9 RW2 표본(있으면)을 쓴다. `LIGHTHOUSE_SNAPSHOT_SCENES=grid,edit`처럼 장면을 고를 수 있다.
@MainActor
final class UISnapshotTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var windows: [NSWindow] = []

    private func wants(_ scene: String) -> Bool {
        let scenes = (environment["LIGHTHOUSE_SNAPSHOT_SCENES"] ?? "").split(separator: ",").map(String.init)
        return scenes.isEmpty || scenes.contains(scene)
    }

    private func render<V: View>(_ view: V, _ model: LibraryModel, _ size: CGSize, _ scene: String,
                                 settle seconds: Double = 1.5) async throws {
        guard wants(scene), let directory = environment["LIGHTHOUSE_SNAPSHOT_DIR"] else { return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AnyView(view.environmentObject(model).preferredColorScheme(.dark)
            .background(Color(nsColor: .windowBackgroundColor))))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        windows.append(window)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(scene + ".png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
    }

    func testRenderScreens() async throws {
        guard let directory = environment["LIGHTHOUSE_SNAPSHOT_DIR"] else {
            throw XCTSkip("LIGHTHOUSE_SNAPSHOT_DIR를 주면 화면을 PNG로 그린다.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let wide = CGSize(width: 1440, height: 900), narrow = CGSize(width: 1100, height: 720)
        try await render(WorkspaceView(), model, narrow, "empty")

        let folder = root.appendingPathComponent("photos", isDirectory: true)
        if let source = environment["LIGHTHOUSE_SNAPSHOT_PHOTOS"] {
            for name in try FileManager.default.contentsOfDirectory(atPath: source) where !name.hasPrefix(".") {
                try FileManager.default.copyItem(atPath: (source as NSString).appendingPathComponent(name),
                                                 toPath: folder.appendingPathComponent(name).path)
            }
        } else {
            for index in 0..<8 {
                try TestSupport.writeJPEG(folder.appendingPathComponent(String(format: "sample-%02d.jpg", index)),
                                          width: 640, height: 427, color: (UInt8(60 + index * 20), 110, 150))
            }
        }
        if let raw = TestSupport.rawSample,
           !FileManager.default.fileExists(atPath: folder.appendingPathComponent(raw.lastPathComponent).path) {
            try FileManager.default.copyItem(at: raw, to: folder.appendingPathComponent(raw.lastPathComponent))
        }
        model.importURLs([folder])
        try await TestSupport.wait("import") { !model.isImporting && !model.photos.isEmpty }
        model.operationMessage = nil
        let photos = model.visiblePhotos
        guard photos.count >= 4 else { throw XCTSkip("사진이 4장 이상 필요하다.") }
        model.select(photos[1]); model.setFlag(.pick); model.setRating(4); model.setColorLabel(.green)
        model.select(photos[2]); model.setFlag(.reject)
        model.select(photos[0])
        try await render(WorkspaceView(), model, wide, "grid", settle: 3)
        try await render(WorkspaceView(), model, narrow, "grid-narrow")
        // 두 장을 고른 고르기 막대와 뒤에서 도는 작업 표시·목록. 상태만 꾸며 그리고 되돌린다.
        model.togglePhotoSelection(photos[1])
        model.isAnalyzingFaces = true
        model.faceAnalysisCompleted = 34
        model.faceAnalysisTotal = 120
        model.sidecarWritesInFlight = 2
        try await render(WorkspaceView(), model, narrow, "grid-activity", settle: 2)
        try await render(BackgroundActivityList(drive: model.driveUpload), model, CGSize(width: 320, height: 190),
                         "activity-list")
        model.isAnalyzingFaces = false
        model.sidecarWritesInFlight = 0
        model.togglePhotoSelection(photos[1])

        let lead = model.photos.first(where: \.isRAW) ?? photos[0]
        model.select(lead)
        model.setMode(.edit)
        try await render(WorkspaceView(), model, wide, "edit", settle: 3)
        try await render(WorkspaceView(), model, narrow, "edit-narrow")
        // 보기 메뉴로 사이드바·오른쪽 패널을 숨긴 좁은 창. 다른 장면에 남지 않게 되돌린다.
        UserDefaults.standard.set(false, forKey: "showsSidebar")
        UserDefaults.standard.set(false, forKey: "showsInspector")
        try await render(WorkspaceView(), model, narrow, "edit-no-panels")
        UserDefaults.standard.removeObject(forKey: "showsSidebar")
        UserDefaults.standard.removeObject(forKey: "showsInspector")
        // 경계선을 끌어 넓힌 패널. 좁은 창에서는 가운데가 위쪽 막대 너비보다 좁아지지 않게 줄어든다.
        UserDefaults.standard.set(320.0, forKey: "sidebarWidth")
        UserDefaults.standard.set(440.0, forKey: "inspectorWidth")
        try await render(WorkspaceView(), model, wide, "edit-wide-panels")
        try await render(WorkspaceView(), model, narrow, "edit-wide-panels-narrow")
        UserDefaults.standard.removeObject(forKey: "sidebarWidth")
        UserDefaults.standard.removeObject(forKey: "inspectorWidth")
        // 값 표시와 나눠 보기를 보려고 몇 가지를 바꿔 둔다.
        var edited = lead.edits
        edited.contrast = 1.1; edited.highlights = 0.63; edited.shadows = 0.35; edited.clarity = 0.2
        edited.tintShift = -7.5; edited.vibrance = -0.15; edited.saturation = 1.2
        edited.sharpness = 0.6; edited.vignette = -0.3
        model.updateEdits(edited)
        try await render(InspectorView(photo: model.selection ?? lead), model, CGSize(width: 300, height: 3400), "inspector")
        // 접히는 묶음을 모두 펼친 모습. 다른 장면에 남지 않게 되돌린다.
        let sectionKeys = ["marks", "presets", "light", "color", "curve", "hsl", "grading", "detail", "geometry", "raw",
                           "effects", "calibration", "lut", "fileInfo"].map { "inspector.section." + $0 } + ["historyPanelExpanded"]
        for key in sectionKeys { UserDefaults.standard.set(true, forKey: key) }
        try await render(InspectorView(photo: model.selection ?? lead), model, CGSize(width: 300, height: 4600),
                         "inspector-expanded")
        for key in sectionKeys { UserDefaults.standard.removeObject(forKey: key) }
        model.toggleSplit()
        try await render(WorkspaceView(), model, wide, "split", settle: 3)
        model.toggleSplit()
        model.beginWhiteBalancePick()
        try await render(WorkspaceView(), model, wide, "pick-gray")
        model.isPickingWhiteBalance = false

        model.setMode(.compare)
        model.move(1)
        try await render(WorkspaceView(), model, narrow, "compare-narrow", settle: 3)
        model.setMode(.grid)
        model.select(photos[1])
        for photo in photos[2...3] { model.togglePhotoSelection(photo) }
        model.setMode(.survey)
        try await render(WorkspaceView(), model, wide, "survey", settle: 3)
        model.setMode(.grid)
        try await render(BatchEditSheet(), model, CGSize(width: 560, height: 760), "batch")

        model.select(lead)
        try await render(ExportSheet(), model, CGSize(width: 1000, height: 820), "export", settle: 3)
        try await render(CriteriaPopover(), model, CGSize(width: 380, height: 560), "criteria")
        try await render(ShortcutHelpSheet(), model, CGSize(width: 600, height: 600), "shortcuts")
        try await render(HelpSheet(), model, CGSize(width: 820, height: 600), "help")
        try await render(HelpSheet(topic: "고르기"), model, CGSize(width: 820, height: 600), "help-culling")
        try await render(HelpSheet(topic: "단축키"), model, CGSize(width: 820, height: 600), "help-shortcuts")
        try await render(HelpSheet(query: "라벨"), model, CGSize(width: 820, height: 600), "help-search")
        try await render(CardImportSheet(), model, CGSize(width: 620, height: 560), "card-import")
        try await render(PresetSheet(request: PresetSheetRequest(kind: .save, initialName: "")), model,
                         CGSize(width: 480, height: 420), "preset")

        // 원본을 옮겨 원본 없음 화면을 그린다.
        let missing = photos[3]
        try FileManager.default.moveItem(at: missing.url, to: root.appendingPathComponent(missing.url.lastPathComponent))
        model.refreshMissingOriginals()
        try await TestSupport.wait("missing") { model.isMissing(missing) }
        model.filter = .missing
        model.setMode(.edit)
        model.ensureSelectionVisible()
        try await render(WorkspaceView(), model, wide, "missing", settle: 2)
    }
}
