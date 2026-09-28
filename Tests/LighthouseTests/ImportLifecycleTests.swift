import CryptoKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class ImportLifecycleTests: XCTestCase {
    func testCancelBeforeQueuedImportResumesMultipleWaitersAndFlushesFinalCatalog() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let incoming = root.appendingPathComponent("incoming.jpg")
        try TestSupport.writeJPEG(incoming)
        model.batchQueue.suspend()
        var queueSuspended = true
        defer { if queueSuspended { model.batchQueue.resume() } }

        model.importURLs([incoming])
        XCTAssertTrue(model.isImporting)
        model.cancelImport()
        let first = expectation(description: "first import waiter")
        let second = expectation(description: "second import waiter")
        Task { @MainActor in await model.cancelImportAndWait(); first.fulfill() }
        Task { @MainActor in await model.cancelImportAndWait(); second.fulfill() }
        model.batchQueue.resume()
        queueSuspended = false
        await fulfillment(of: [first, second], timeout: 5)

        XCTAssertFalse(model.isImporting)
        XCTAssertFalse(model.isCancellingImport)
        XCTAssertNil(model.importCancellation)
        XCTAssertTrue(model.importCompletionWaiters.isEmpty)
        XCTAssertTrue(model.photos.isEmpty)
        try model.flushSave()
        let restarted = LibraryModel()
        restarted.start()
        try await TestSupport.wait("cancelled import reload") { restarted.catalogLoaded }
        XCTAssertTrue(restarted.photos.isEmpty)
    }

    func testImportFreezesPresetAndRejectsExportOverlap() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 1)
        let incoming = root.appendingPathComponent("preset-incoming.jpg")
        try TestSupport.writeJPEG(incoming, color: (30, 60, 90))
        var settings = EditSettings.neutral
        settings.exposure = 1.25
        let preset = EditPreset(name: "고정", source: settings, components: .global)
        model.presets = [preset]
        model.importPresetID = preset.id
        model.batchQueue.suspend()
        var queueSuspended = true
        defer { if queueSuspended { model.batchQueue.resume() } }

        model.importURLs([incoming])
        model.importPresetID = nil
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        model.export(scope: .current, options: ExportOptions(maxPixel: 40), directory: exports)
        XCTAssertFalse(model.isExporting)
        XCTAssertTrue(model.operationMessage?.contains("가져오기가 끝난 뒤") == true)
        model.batchQueue.resume()
        queueSuspended = false
        try await TestSupport.wait("frozen preset import") { !model.isImporting && model.photos.count == 2 }
        XCTAssertEqual(model.photos.first { $0.path == incoming.path }?.edits.exposure, 1.25)

        model.isExporting = true
        model.importURLs([root.appendingPathComponent("another.jpg")])
        XCTAssertFalse(model.isImporting)
        XCTAssertTrue(model.operationMessage?.contains("내보내기가 끝난 뒤") == true)
        model.isExporting = false
    }

    func testSupportedFileScanSkipsDirectoriesDeduplicatesCanonicalFilesAndHonorsCancellation() throws {
        let root = try TestSupport.temporaryDirectory(self)
        let disguisedDirectory = root.appendingPathComponent("album.jpg", isDirectory: true)
        try FileManager.default.createDirectory(at: disguisedDirectory, withIntermediateDirectories: true)
        let photo = disguisedDirectory.appendingPathComponent("photo.jpg")
        try TestSupport.writeJPEG(photo)
        let alias = root.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: photo)

        let files = LibraryModel.supportedFiles(in: [disguisedDirectory, photo, alias])
        XCTAssertEqual(files.map(\.path), [photo.resolvingSymlinksInPath().path])
        XCTAssertFalse(files.contains { $0.path == disguisedDirectory.path })

        let cancellation = CancellationFlag()
        cancellation.cancel()
        XCTAssertTrue(LibraryModel.supportedFiles(in: [root], cancellation: cancellation).isEmpty)
    }

    func testCancelledCardCopyLeavesSourceBytesUnchanged() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let source = root.appendingPathComponent("card", isDirectory: true)
        let destination = root.appendingPathComponent("copied", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("one.jpg")
        let second = source.appendingPathComponent("two.jpg")
        try TestSupport.writeJPEG(first, color: (10, 20, 30))
        try TestSupport.writeJPEG(second, color: (40, 50, 60))
        let hashes = try [first, second].map { SHA256.hash(data: try Data(contentsOf: $0)) }
        model.batchQueue.suspend()
        var queueSuspended = true
        defer { if queueSuspended { model.batchQueue.resume() } }

        model.importByCopying(from: source, to: destination, organizeByDate: false)
        model.cancelImport()
        model.batchQueue.resume()
        queueSuspended = false
        try await TestSupport.wait("cancelled card scan") { !model.isImporting }

        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertEqual(try [first, second].map { SHA256.hash(data: try Data(contentsOf: $0)) }, hashes)
    }
}
