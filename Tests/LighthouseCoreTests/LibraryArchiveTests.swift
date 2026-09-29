import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class LibraryArchiveTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func writeImage(to url: URL, type: UTType = .png) throws -> Data {
        let width = 40, height = 30
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x * 6)
                pixels[offset + 1] = UInt8(y * 8)
                pixels[offset + 2] = UInt8((x + y) * 3)
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4,
                                              space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try Data(contentsOf: url)
    }

    private func cubeData(title: String = "Archive Film") -> Data {
        Data("""
        TITLE \"\(title)\"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """.utf8)
    }

    private func makeLibrary(at root: URL, original: URL) throws -> PhotoAsset {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var photo = PhotoAsset(url: original)
        let maskURL = root.appendingPathComponent("mask.png")
        let maskData = try writeImage(to: maskURL)
        try FileManager.default.removeItem(at: maskURL)
        photo.edits.localAdjustments = [LocalAdjustment(exposure: 0.4,
                                                         baseMask: RasterMask(width: 40, height: 30, pngData: maskData))]
        let cube = root.appendingPathComponent("source.cube")
        try cubeData().write(to: cube)
        photo.edits.lut = try LUTStore(directory: root.appendingPathComponent("LUTs")).importCube(from: cube)
        try FileManager.default.removeItem(at: cube)
        photo.lastExport = ExportRecord(exportedAt: Date(timeIntervalSince1970: 1), path: "/tmp/old.jpg",
                                        baseName: "old", options: ExportOptions(), digest: "old", fileSize: 1,
                                        fileModified: Date(timeIntervalSince1970: 1))
        try CatalogStore(url: root.appendingPathComponent("catalog.json")).save([photo])
        try PhotoFolderStore(url: root.appendingPathComponent("folders.json"))
            .save([PhotoFolder(name: "보관", photoIDs: [photo.id])])
        let sourceValues = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let analysis = PhotoFaceAnalysis(photoID: photo.id, sourcePath: photo.path,
                                         sourceSize: Int64(try XCTUnwrap(sourceValues.fileSize)),
                                         sourceModifiedAt: try XCTUnwrap(sourceValues.contentModificationDate), faces: [])
        try PeopleStore(url: root.appendingPathComponent("people.json"))
            .save(PeopleCatalog(analyses: [analysis]))
        _ = try SmartPreviewStore(directory: root.appendingPathComponent("SmartPreviews"))
            .create(for: photo, pipeline: ImagePipeline())
        return photo
    }

    func testFullRoundTripPreservesLibraryAndRemapsOriginalDependentRecords() throws {
        let base = try temporaryDirectory()
        let original = base.appendingPathComponent("outside.png")
        let originalBytes = try writeImage(to: original)
        let library = base.appendingPathComponent("Library")
        let photo = try makeLibrary(at: library, original: original)
        let archive = base.appendingPathComponent("Complete.lighthousebackup")

        let summary = try LibraryArchive.create(dataDirectory: library, destination: archive, includeOriginals: true)
        XCTAssertTrue(summary.includesOriginals)
        XCTAssertEqual(summary.photoCount, 1)
        XCTAssertEqual(try LibraryArchive.inspect(at: archive), summary)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes, "백업은 원본을 바꾸지 않는다")

        let restored = base.appendingPathComponent("Restored")
        XCTAssertEqual(try LibraryArchive.restore(from: archive, to: restored), restored)
        let restoredPhoto = try XCTUnwrap(CatalogStore(url: restored.appendingPathComponent("catalog.json")).load().first)
        XCTAssertEqual(restoredPhoto.id, photo.id)
        XCTAssertEqual(restoredPhoto.filename, original.lastPathComponent)
        XCTAssertNil(restoredPhoto.lastExport)
        XCTAssertTrue(restoredPhoto.path.hasPrefix(restored.path + "/OriginalFiles/"))
        XCTAssertEqual(try Data(contentsOf: restoredPhoto.url), originalBytes)
        XCTAssertEqual(try PhotoFolderStore(url: restored.appendingPathComponent("folders.json")).load().first?.photoIDs,
                       Set([photo.id]))
        let people = try PeopleStore(url: restored.appendingPathComponent("people.json")).load()
        XCTAssertEqual(people.analyses.first?.sourcePath, restoredPhoto.path)
        XCTAssertNotNil(try SmartPreviewStore(directory: restored.appendingPathComponent("SmartPreviews"))
            .previewURL(for: restoredPhoto))
        XCTAssertNotNil(restoredPhoto.edits.lut)
    }

    func testMetadataOnlyRoundTripKeepsOldPathAndAllowsMissingOriginal() throws {
        let base = try temporaryDirectory()
        let original = base.appendingPathComponent("outside.png")
        try writeImage(to: original)
        let library = base.appendingPathComponent("Library")
        let photo = try makeLibrary(at: library, original: original)
        try FileManager.default.removeItem(at: original)
        let archive = base.appendingPathComponent("Metadata.lighthousebackup")

        let summary = try LibraryArchive.create(dataDirectory: library, destination: archive, includeOriginals: false)
        XCTAssertFalse(summary.includesOriginals)
        XCTAssertTrue(summary.originals.isEmpty)
        XCTAssertThrowsError(try LibraryArchive.create(dataDirectory: library,
                                                       destination: base.appendingPathComponent("MissingOriginals.lighthousebackup"),
                                                       includeOriginals: true)) { error in
            guard case LibraryArchiveError.missingOriginal = error else { return XCTFail("\(error)") }
        }
        let restored = try LibraryArchive.restore(from: archive, to: base.appendingPathComponent("Restored"))
        let restoredPhoto = try XCTUnwrap(CatalogStore(url: restored.appendingPathComponent("catalog.json")).load().first)
        XCTAssertEqual(restoredPhoto.path, photo.path)
        XCTAssertNil(restoredPhoto.lastExport)
        XCTAssertNotNil(try SmartPreviewStore(directory: restored.appendingPathComponent("SmartPreviews"))
            .previewURL(for: restoredPhoto))
    }

    func testHashDamageTraversalAndSymlinkAreRejectedBeforeRestore() throws {
        let base = try temporaryDirectory()
        let original = base.appendingPathComponent("outside.png")
        try writeImage(to: original)
        let library = base.appendingPathComponent("Library")
        _ = try makeLibrary(at: library, original: original)
        let archive = base.appendingPathComponent("Archive.lighthousebackup")
        let summary = try LibraryArchive.create(dataDirectory: library, destination: archive, includeOriginals: false)

        let catalog = archive.appendingPathComponent("catalog.json")
        var bytes = try Data(contentsOf: catalog)
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: catalog)
        XCTAssertThrowsError(try LibraryArchive.inspect(at: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("NeverRestored").path))

        try FileManager.default.removeItem(at: archive)
        _ = try LibraryArchive.create(dataDirectory: library, destination: archive, includeOriginals: false)
        let escaped = LibraryArchiveSummary(createdAt: summary.createdAt, includesOriginals: false,
            photoCount: summary.photoCount,
            files: summary.files + [LibraryArchiveFileRecord(relativePath: "../escape", size: 0,
                                                               sha256: String(repeating: "0", count: 64))], originals: [])
        try JSONEncoder().encode(escaped).write(to: archive.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertThrowsError(try LibraryArchive.inspect(at: archive)) { error in
            guard case LibraryArchiveError.invalidRelativePath = error else { return XCTFail("\(error)") }
        }

        try FileManager.default.removeItem(at: archive)
        let valid = try LibraryArchive.create(dataDirectory: library, destination: archive, includeOriginals: false)
        let collision = LibraryArchiveSummary(createdAt: valid.createdAt, includesOriginals: false,
            photoCount: valid.photoCount,
            files: valid.files + [
                LibraryArchiveFileRecord(relativePath: "Masks/Café.png", size: 0,
                                         sha256: String(repeating: "0", count: 64)),
                LibraryArchiveFileRecord(relativePath: "Masks/Café.PNG", size: 0,
                                         sha256: String(repeating: "1", count: 64)),
            ], originals: [])
        try JSONEncoder().encode(collision).write(to: archive.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertThrowsError(try LibraryArchive.inspect(at: archive)) { error in
            guard case LibraryArchiveError.duplicatePath = error else { return XCTFail("\(error)") }
        }
        try JSONEncoder().encode(valid).write(to: archive.appendingPathComponent("manifest.json"), options: .atomic)
        try FileManager.default.createSymbolicLink(at: archive.appendingPathComponent("Masks/link"),
                                                   withDestinationURL: original)
        XCTAssertThrowsError(try LibraryArchive.inspect(at: archive)) { error in
            guard case LibraryArchiveError.symbolicLink = error else { return XCTFail("\(error)") }
        }
    }

    func testDSStoreIsSkippedAndUnusedDamagedLUTRejectsCreation() throws {
        let base = try temporaryDirectory()
        let original = base.appendingPathComponent("outside.png")
        try writeImage(to: original)
        let library = base.appendingPathComponent("Library")
        _ = try makeLibrary(at: library, original: original)
        try Data("finder".utf8).write(to: library.appendingPathComponent("Masks/.DS_Store"))
        let archive = base.appendingPathComponent("Archive.lighthousebackup")
        let summary = try LibraryArchive.create(dataDirectory: library, destination: archive, includeOriginals: false)
        XCTAssertFalse(summary.files.contains { $0.relativePath.hasSuffix(".DS_Store") })

        try FileManager.default.removeItem(at: archive)
        let badID = String(repeating: "a", count: 64)
        try Data("broken cube".utf8).write(to: library.appendingPathComponent("LUTs/\(badID).cube"))
        XCTAssertThrowsError(try LibraryArchive.create(dataDirectory: library, destination: archive,
                                                       includeOriginals: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testCancellationAndExistingDestinationPreserveData() throws {
        let base = try temporaryDirectory()
        let original = base.appendingPathComponent("outside.png")
        let originalBytes = try writeImage(to: original)
        let library = base.appendingPathComponent("Library")
        _ = try makeLibrary(at: library, original: original)
        let cancelled = base.appendingPathComponent("Cancelled.lighthousebackup")
        XCTAssertThrowsError(try LibraryArchive.create(dataDirectory: library, destination: cancelled,
                                                       includeOriginals: true, isCancelled: { true })) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)

        let existing = base.appendingPathComponent("Existing.lighthousebackup")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let marker = existing.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try LibraryArchive.create(dataDirectory: library, destination: existing,
                                                       includeOriginals: false))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))

        let archive = base.appendingPathComponent("Valid.lighthousebackup")
        _ = try LibraryArchive.create(dataDirectory: library, destination: archive, includeOriginals: false)
        let restoreTarget = base.appendingPathComponent("CancelledRestore")
        XCTAssertThrowsError(try LibraryArchive.restore(from: archive, to: restoreTarget,
                                                        isCancelled: { true })) { error in
            XCTAssertEqual(error as? LibraryArchiveError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreTarget.path))
    }
}
