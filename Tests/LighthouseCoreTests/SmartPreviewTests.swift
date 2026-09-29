import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class SmartPreviewTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeImage(to url: URL, seed: Int = 0) throws {
        let width = 48, height = 32
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 5 + seed) % 256)
                pixels[offset + 1] = UInt8((y * 7 + seed) % 256)
                pixels[offset + 2] = UInt8((x * 3 + y * 2 + seed) % 256)
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testCreatesValidatedPreviewAndAllowsMissingOriginalFallback() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("original.png")
        try writeImage(to: source)
        let originalDigest = try sha256(source)
        let photo = PhotoAsset(url: source)
        let store = SmartPreviewStore(directory: root.appendingPathComponent("SmartPreviews"))

        let record = try store.create(for: photo, pipeline: ImagePipeline())
        XCTAssertEqual(record.photoID, photo.id)
        XCTAssertEqual(record.sourcePath, photo.path)
        XCTAssertLessThanOrEqual(max(record.width, record.height), 2560)
        XCTAssertNotNil(try store.previewURL(for: photo))
        XCTAssertEqual(try sha256(source), originalDigest, "원본 bytes를 바꾸지 않는다")

        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try store.record(for: photo), record, "원본이 없을 때만 검증된 proxy를 쓴다")
        var moved = photo
        moved.path = root.appendingPathComponent("moved.png").path
        XCTAssertNil(try store.record(for: moved), "같은 photo ID라도 원본 위치가 바뀌면 무효")
    }

    func testChangedSourceAndDamagedTIFFAreRejected() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("original.png")
        try writeImage(to: source)
        let photo = PhotoAsset(url: source)
        let directory = root.appendingPathComponent("SmartPreviews")
        let store = SmartPreviewStore(directory: directory)
        _ = try store.create(for: photo, pipeline: ImagePipeline())

        try writeImage(to: source, seed: 80)
        XCTAssertNil(try store.record(for: photo))

        try FileManager.default.removeItem(at: source)
        let tiff = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "tiff" })
        try Data("broken".utf8).write(to: tiff)
        XCTAssertThrowsError(try store.record(for: photo)) { error in
            guard case SmartPreviewStoreError.damagedPreview = error else { return XCTFail("\(error)") }
        }
    }

    func testFailedRegenerationKeepsPreviousPairAndNeverChangesOriginal() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("original.png")
        try writeImage(to: source)
        let original = try Data(contentsOf: source)
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let photo = PhotoAsset(url: source)
        let store = SmartPreviewStore(directory: root.appendingPathComponent("SmartPreviews"))
        let first = try store.create(for: photo, pipeline: ImagePipeline())
        let storedBefore = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })

        try Data("not an image".utf8).write(to: source)
        XCTAssertThrowsError(try store.create(for: photo, pipeline: ImagePipeline()))
        let storedAfter = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil
        ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        XCTAssertEqual(storedAfter, storedBefore)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try store.record(for: photo)?.generation, first.generation)
        try original.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPreviewEditsDisableOriginalOnlyOperationsWithoutMutatingInput() {
        var edits = EditSettings.neutral
        edits.exposure = 1
        edits.sharpness = 0.7
        edits.hdrAmount = 1
        edits.grain = GrainSettings(amount: 0.5)
        edits.noiseReduction = NoiseReductionSettings(mode: .standard, amount: 0.8)
        edits.flicker = FlickerSettings(isEnabled: true)
        edits.retouchStrokes = [RetouchStroke(points: [MaskPoint(x: 0.5, y: 0.5)])]
        edits.localAdjustments = [LocalAdjustment(noiseReduction: NoiseReductionSettings(mode: .standard, amount: 0.6))]

        let preview = SmartPreviewStore.previewEdits(edits)
        XCTAssertEqual(preview.exposure, 1)
        XCTAssertEqual(preview.sharpness, 0)
        XCTAssertEqual(preview.hdrAmount, 0)
        XCTAssertFalse(preview.noiseReduction.isActive)
        XCTAssertFalse(preview.flicker.isActive)
        XCTAssertTrue(preview.retouchStrokes.isEmpty)
        XCTAssertFalse(preview.localAdjustments[0].noiseReduction.isActive)
        XCTAssertTrue(edits.noiseReduction.isActive, "저장된 보정을 바꾸지 않는다")
    }
}
