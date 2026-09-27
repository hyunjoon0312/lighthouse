import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class ExportTerminationTests: XCTestCase {
    func testCancelAndWaitCommitsCurrentReexportSkipsLaterFilesAndSupportsMultipleWaiters() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 3)
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        model.selectAllVisible()
        model.export(scope: .selected, options: ExportOptions(maxPixel: 40), directory: exports)
        try await TestSupport.wait("initial export") { !model.isExporting }
        for index in model.photos.indices { model.photos[index].edits.exposure = Double(index + 1) * 0.1 }
        let targets = model.changedSinceExport
        XCTAssertEqual(targets.count, 3)

        let firstWaiter = expectation(description: "first cancellation waiter")
        let secondWaiter = expectation(description: "second cancellation waiter")
        let cancelOnce = LockedFlag()
        model.moveToTrash = { url in
            if cancelOnce.claim() {
                MainActor.assumeIsolated { model.cancelExport() }
                Task { @MainActor in
                    await model.cancelExportAndWait()
                    firstWaiter.fulfill()
                }
                Task { @MainActor in
                    await model.cancelExportAndWait()
                    secondWaiter.fulfill()
                }
            }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }

        model.reexport(targets, trashPrevious: true)
        await fulfillment(of: [firstWaiter, secondWaiter], timeout: 5)

        XCTAssertFalse(model.isExporting)
        XCTAssertFalse(model.isCancellingExport)
        XCTAssertNil(model.exportCancellation)
        XCTAssertEqual(model.changedSinceExport.count, 2, "현재 파일 기록은 커밋하고 뒤의 파일은 건너뛴다")
        XCTAssertEqual(model.lastExportedFiles.count, 1)
    }

    func testCancelAndWaitIsSafeWhenNoLocalExportIsActive() async {
        let model = LibraryModel()
        await model.cancelExportAndWait()
        XCTAssertFalse(model.isExporting)
        XCTAssertTrue(model.exportCompletionWaiters.isEmpty)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}
