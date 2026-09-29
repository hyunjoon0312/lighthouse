import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class WorkflowAppTests: XCTestCase {
    func testLibraryModelPinsEveryDependencyToInjectedRoot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = LibraryModel(dataDirectory: root)

        XCTAssertEqual(model.dataDirectory, root.standardizedFileURL)
        XCTAssertEqual(model.catalog.url, root.appendingPathComponent("catalog.json"))
        XCTAssertEqual(model.folderStore.url, root.appendingPathComponent("folders.json"))
        XCTAssertEqual(model.presetStore.url, root.appendingPathComponent("presets.json"))
        XCTAssertEqual(model.smartFolderStore.url, root.appendingPathComponent("smart-folders.json"))
        XCTAssertEqual(model.peopleStore.url, root.appendingPathComponent("people.json"))
        XCTAssertEqual(model.lutStore.directory, root.appendingPathComponent("LUTs", isDirectory: true))
        XCTAssertEqual(model.thumbnailStore.directory, root.appendingPathComponent("Thumbnails", isDirectory: true))
        XCTAssertEqual(model.smartPreviewStore.directory, root.appendingPathComponent("SmartPreviews", isDirectory: true))
        XCTAssertEqual(model.backup.directory, root.appendingPathComponent("Backups", isDirectory: true))
    }

    func testLibrarySessionRejectsDirectoryWithoutCatalogAndKeepsCurrentModel() async {
        let initial = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = LibrarySession(initialDirectory: initial)
        let current = session.library

        let opened = await session.openLibrary(at: missing)
        XCTAssertFalse(opened)
        XCTAssertTrue(session.library === current)
        XCTAssertEqual(session.library.dataDirectory, initial.standardizedFileURL)
        XCTAssertNotNil(session.errorMessage)
    }

    func testAutomaticMaskBatchFallbackIsOneUndoStepAndPreservesProvenance() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let source = model.photos[0]
        let target = model.photos[1]
        var sourceEdits = source.edits
        sourceEdits.localAdjustments = [LocalAdjustment(name: "피사체", exposure: 0.7,
                                                        automaticMaskKind: .subject)]

        model.applyBatchEditsWithAutomaticMasks(source: sourceEdits, to: [target.id],
                                                components: .local, reRecognize: false)
        XCTAssertEqual(model.photo(withID: target.id)?.edits.localAdjustments.first?.automaticMaskKind, .subject)
        XCTAssertEqual(model.photo(withID: target.id)?.edits.localAdjustments.first?.exposure, 0.7)
        model.undo()
        XCTAssertTrue(model.photo(withID: target.id)?.edits.localAdjustments.isEmpty == true)
        model.redo()
        XCTAssertEqual(model.photo(withID: target.id)?.edits.localAdjustments.first?.automaticMaskKind, .subject)
    }

    func testCachedOfflinePreviewSourcePreservesUnsupportedEditsWithoutDiskValidation() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let photo = try XCTUnwrap(model.selection)
        var edited = photo.edits
        edited.noiseReduction = NoiseReductionSettings(mode: .ai, amount: 0.8)
        edited.flicker = FlickerSettings(isEnabled: true, amount: 0.6)
        edited.retouchStrokes = [RetouchStroke(points: [MaskPoint(x: 0.5, y: 0.5)])]
        model.updateEdits(edited)
        let generation = UUID()
        let record = SmartPreviewRecord(photoID: photo.id, sourcePath: photo.path, sourceSize: 1,
                                        sourceModifiedAt: .now, width: 40, height: 30,
                                        previewSHA256: String(repeating: "a", count: 64), generation: generation)
        let cachedURL = model.smartPreviewStore.directory.appendingPathComponent("cached.tiff")
        model.smartPreviewRecords[photo.id] = record
        model.smartPreviewURLs[photo.id] = cachedURL
        model.missingPaths.insert(photo.path)

        let resolved = try XCTUnwrap(model.validatedPreviewSource(for: try XCTUnwrap(model.selection)))
        XCTAssertEqual(resolved.url, cachedURL)
        XCTAssertEqual(resolved.edits.noiseReduction, NoiseReductionSettings())
        XCTAssertEqual(resolved.edits.flicker, FlickerSettings())
        XCTAssertTrue(resolved.edits.retouchStrokes.isEmpty)
        XCTAssertEqual(model.selection?.edits.noiseReduction, edited.noiseReduction)
        XCTAssertEqual(model.selection?.edits.flicker, edited.flicker)
        XCTAssertEqual(model.selection?.edits.retouchStrokes, edited.retouchStrokes)
    }

    func testConflictGateIncludesAllMutatingWorkflowStates() {
        let model = LibraryModel()
        XCTAssertFalse(model.hasConflictingWorkflow)
        model.isAutoMasking = true
        XCTAssertTrue(model.hasConflictingWorkflow)
        model.isAutoMasking = false
        model.isLUTImporting = true
        XCTAssertTrue(model.hasConflictingWorkflow)
        model.isLUTImporting = false
        model.isFindingHealSource = true
        XCTAssertTrue(model.hasConflictingWorkflow)
    }

    func testCorruptAuxiliaryPreservesBytesDuringNormalFlushAndRejectsStrictBackupFlush() async throws {
        let root = try TestSupport.temporaryDirectory(self)
        let photoURL = root.appendingPathComponent("photo.jpg")
        try TestSupport.writeJPEG(photoURL)
        let photo = PhotoAsset(url: photoURL)
        try CatalogStore(url: root.appendingPathComponent("catalog.json")).save([photo])
        let peopleURL = root.appendingPathComponent("people.json")
        let corruptPeople = Data("{damaged".utf8)
        try corruptPeople.write(to: peopleURL)

        let model = LibraryModel(dataDirectory: root)
        model.start()
        try await TestSupport.wait("corrupt people library load") {
            model.catalogLoaded && model.foldersLoaded && model.peopleLoadError != nil
        }
        model.setRating(4)

        XCTAssertNoThrow(try model.flushSave())
        XCTAssertEqual(try CatalogStore(url: root.appendingPathComponent("catalog.json")).load().first?.rating, 4)
        XCTAssertEqual(try Data(contentsOf: peopleURL), corruptPeople)
        XCTAssertThrowsError(try model.flushSave(requireCompleteLibrary: true))
        XCTAssertEqual(try Data(contentsOf: peopleURL), corruptPeople)
    }
}
