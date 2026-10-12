import AppKit
import SwiftUI
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 창에 시트가 붙어 있으면 macOS는 종료 요청을 무시한다(앱 델리게이트도 부르지 않는다). 그래서 ⌘Q는 열린 창을 먼저 닫는다.
/// 시트는 밖에서 `endSheet`로 닫으면 SwiftUI가 다시 붙여 두므로, 모델 값을 내려 닫는다.
@MainActor
final class QuitWithSheetTests: XCTestCase {
    func testClosingPresentationsClearsEveryModalValue() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        model.showExport = true; model.showBatchEdit = true; model.showCardImport = true; model.showShortcuts = true
        model.showPeople = true; model.showHelp = true; model.showColorLabelNames = true
        model.showSimilarPhotos = true; model.showSmartPreviews = true; model.showLibraryBackup = true; model.showLibraryRestore = true
        model.presetSheet = PresetSheetRequest(kind: .save, initialName: "")
        model.lightroomPresetSheet = LightroomPresetSheetRequest(content: .importResult(LightroomPresetImportSummary(imported: [], failures: [])))
        model.folderSheetRequest = PhotoFolderSheetRequest(kind: .create, initialName: "", selectedIDs: [])
        model.catalogRemoval = CatalogRemoval(photos: model.photos, hiddenCompanions: 0)
        model.cropSource = model.photos[0]
        model.referenceMatchSource = model.photos[0]
        model.rangeMaskRequest = RangeMaskSheetRequest(photoID: model.photos[0].id, path: model.photos[0].url.path,
                                                       edits: model.photos[0].edits, localID: nil, initial: RangeSelection())
        XCTAssertTrue(model.hasModalPresentation)

        model.closePresentations()

        XCTAssertFalse(model.hasModalPresentation)
    }

    func testClosingPresentationsDetachesTheSheetFromTheWindow() async throws {
        let root = try TestSupport.temporaryDirectory(self)
        let session = LibrarySession(initialDirectory: root.appendingPathComponent("data", isDirectory: true))
        let model = session.library
        model.start()
        try await TestSupport.wait("catalog") { model.catalogLoaded && model.foldersLoaded }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WorkspaceView().environment(model).environmentObject(session))
        // 시트는 화면에 올라간 창에만 붙는다. 사용자 화면을 가리지 않게 화면 밖 멀리, 맨 뒤에 둔다.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil }

        for open in [{ model.showLibraryBackup = true },
                     { model.catalogRemoval = CatalogRemoval(photos: [], hiddenCompanions: 0) },
                     { model.presetSheet = PresetSheetRequest(kind: .save, initialName: "") }] {
            open()
            try await TestSupport.wait("sheet attached", timeout: 10) { window.attachedSheet != nil }
            model.closePresentations()
            try await TestSupport.wait("sheet detached", timeout: 10) { window.attachedSheet == nil }
        }
    }
}
