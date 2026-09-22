import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class CoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func testImage(in directory: URL) throws -> URL {
        let width = 80, height = 60
        let pixels = (0..<(width * height)).flatMap { index -> [UInt8] in
            let x = index % width
            return [UInt8(30 + x * 2), 80, 110, 255]
        }
        let image = pixels.withUnsafeBytes { bytes -> CGImage? in
            let context = CGContext(data: UnsafeMutableRawPointer(mutating: bytes.baseAddress), width: width,
                                    height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return context?.makeImage()
        }
        let url = directory.appendingPathComponent("sample.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, try XCTUnwrap(image), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        return Array(data[offset..<(offset + bytesPerPixel)])
    }

    func testCatalogRoundTripAndCorruptionProtection() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("catalog.json")
        let store = CatalogStore(url: url)
        XCTAssertEqual(try store.load(), [])
        var photo = PhotoAsset(url: directory.appendingPathComponent("sample.png"), metadata: .init(width: 80, height: 60))
        photo.rating = 5
        photo.flag = .pick
        photo.edits.exposure = 1
        try store.save([photo])
        XCTAssertEqual(try store.load(), [photo])
        try Data("broken json".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), Data("broken json".utf8))
        try Data(#"{"version":2,"photos":[]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }

    func testEditsRotationCropAndResize() throws {
        let directory = try temporaryDirectory()
        let url = try testImage(in: directory)
        let pipeline = ImagePipeline()
        let neutral = try pipeline.render(url: url, edits: .neutral, maxPixel: nil)
        var edits = EditSettings()
        edits.exposure = 1
        let changed = try pipeline.render(url: url, edits: edits, maxPixel: nil)
        XCTAssertNotEqual(neutral.dataProvider?.data as Data?, changed.dataProvider?.data as Data?)
        edits = .init(rotationQuarterTurns: 1, cropAspect: 1)
        let cropped = try pipeline.render(url: url, edits: edits, maxPixel: nil)
        XCTAssertEqual(cropped.width, 60)
        XCTAssertEqual(cropped.height, 60)
        let small = try pipeline.render(url: url, edits: edits, maxPixel: 30)
        XCTAssertEqual(small.width, 30)
        XCTAssertEqual(small.height, 30)
    }

    func testJPEGNameCollisionKeepsExistingFiles() throws {
        let directory = try temporaryDirectory()
        let original = try testImage(in: directory)
        let exportDirectory = directory.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let existing = exportDirectory.appendingPathComponent("sample-edited.jpg")
        try Data("keep".utf8).write(to: existing)
        let result = try ImagePipeline().exportJPEG(url: original, edits: .neutral,
                                                    to: exportDirectory, maxPixel: 40, quality: 0.8)
        XCTAssertEqual(result.lastPathComponent, "sample-edited-2.jpg")
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        let source = CGImageSourceCreateWithURL(result as CFURL, nil)
        XCTAssertEqual(CGImageSourceGetType(source!), UTType.jpeg.identifier as CFString)
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source!, 0, nil)?.width, 40)
    }

    func testLegacyEditsAndNewCatalogRoundTrip() throws {
        let directory = try temporaryDirectory()
        let old = try JSONEncoder().encode(EditSettings())
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        dictionary.removeValue(forKey: "localAdjustments")
        let legacy = try JSONSerialization.data(withJSONObject: dictionary)
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: legacy).localAdjustments, [])
        dictionary["localAdjustments"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(EditSettings.self,
                                                     from: JSONSerialization.data(withJSONObject: dictionary)))
        dictionary["localAdjustments"] = "invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(EditSettings.self,
                                                     from: JSONSerialization.data(withJSONObject: dictionary)))
        dictionary.removeValue(forKey: "localAdjustments")
        dictionary.removeValue(forKey: "contrast")
        XCTAssertThrowsError(try JSONDecoder().decode(EditSettings.self,
                                                     from: JSONSerialization.data(withJSONObject: dictionary)))

        var photo = PhotoAsset(url: directory.appendingPathComponent("source.png"))
        photo.edits.localAdjustments = [LocalAdjustment(name: "얼굴", exposure: 0.8,
            strokes: [MaskStroke(points: [MaskPoint(x: 0.2, y: 0.25)], radius: 0.08)])]
        let store = CatalogStore(url: directory.appendingPathComponent("catalog.json"))
        try store.save([photo])
        XCTAssertEqual(try store.load(), [photo])
        XCTAssertTrue(photo.edits.isModified)
    }

    func testGeometryRoundTripAndCroppedPosition() {
        let point = MaskPoint(x: 0.2, y: 0.25)
        for turns in -1...4 {
            let geometry = LocalMaskGeometry(sourceWidth: 80, sourceHeight: 60,
                                             rotationQuarterTurns: turns, cropAspect: 1)
            let display = geometry.displayPoint(fromSource: point)
            let back = geometry.sourcePoint(fromDisplay: display)
            XCTAssertEqual(back.x, point.x, accuracy: 0.000_001)
            XCTAssertEqual(back.y, point.y, accuracy: 0.000_001)
            XCTAssertEqual(geometry.displayAspect, 1, accuracy: 0.000_001)
        }
        let rotated = LocalMaskGeometry(sourceWidth: 80, sourceHeight: 60,
                                        rotationQuarterTurns: 1, cropAspect: 1)
        let position = rotated.displayPoint(fromSource: point)
        XCTAssertEqual(position.x, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(position.y, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(rotated.displayRadius(fromSource: 0.1), 0.1, accuracy: 0.000_001)
    }

    func testLocalExposureEraseDisableAndMultipleAreas() throws {
        let directory = try temporaryDirectory()
        let url = try testImage(in: directory)
        let pipeline = ImagePipeline()
        let neutral = try pipeline.render(url: url, edits: .neutral, maxPixel: nil)
        let first = LocalAdjustment(exposure: 1, feather: 0,
            strokes: [MaskStroke(points: [MaskPoint(x: 0.25, y: 0.25)], radius: 0.11)])
        var edits = EditSettings(localAdjustments: [first])
        let localized = try pipeline.render(url: url, edits: edits, maxPixel: nil)
        XCTAssertNotEqual(try pixel(localized, x: 20, y: 15), try pixel(neutral, x: 20, y: 15))
        XCTAssertEqual(try pixel(localized, x: 20, y: 45), try pixel(neutral, x: 20, y: 45))
        XCTAssertEqual(try pixel(localized, x: 60, y: 15), try pixel(neutral, x: 60, y: 15))

        edits.localAdjustments[0].strokes.append(MaskStroke(points: [MaskPoint(x: 0.25, y: 0.25)],
                                                             radius: 0.04, isErasing: true))
        let erased = try pipeline.render(url: url, edits: edits, maxPixel: nil)
        XCTAssertEqual(try pixel(erased, x: 20, y: 15), try pixel(neutral, x: 20, y: 15))
        XCTAssertNotEqual(try pixel(erased, x: 24, y: 15), try pixel(neutral, x: 24, y: 15))

        edits.localAdjustments[0].isEnabled = false
        let disabled = try pipeline.render(url: url, edits: edits, maxPixel: nil)
        XCTAssertEqual(try pixel(disabled, x: 24, y: 15), try pixel(neutral, x: 24, y: 15))

        edits.localAdjustments = [first, LocalAdjustment(contrast: 1.5, feather: 0,
            strokes: [MaskStroke(points: [MaskPoint(x: 0.75, y: 0.75)], radius: 0.11)])]
        let combined = try pipeline.render(url: url, edits: edits, maxPixel: nil)
        XCTAssertNotEqual(try pixel(combined, x: 20, y: 15), try pixel(neutral, x: 20, y: 15))
        XCTAssertNotEqual(try pixel(combined, x: 60, y: 45), try pixel(neutral, x: 60, y: 45))
        XCTAssertEqual(try pixel(combined, x: 20, y: 45), try pixel(neutral, x: 20, y: 45))
    }

    func testMaskFeatherEdgeAndPreviewGeometry() throws {
        let pipeline = ImagePipeline()
        let sharp = LocalAdjustment(feather: 0, strokes: [
            MaskStroke(points: [MaskPoint(x: 0.5, y: 0.25)], radius: 0.15)
        ])
        var soft = sharp
        soft.feather = 0.05
        let hardMask = try pipeline.renderMask(adjustment: sharp, sourceWidth: 80, sourceHeight: 60,
                                               edits: .neutral, maxPixel: 1600)
        let softMask = try pipeline.renderMask(adjustment: soft, sourceWidth: 80, sourceHeight: 60,
                                               edits: .neutral, maxPixel: 1600)
        XCTAssertGreaterThan(try pixel(hardMask, x: 40, y: 15)[0], 240)
        XCTAssertLessThan(try pixel(hardMask, x: 40, y: 45)[0], 15)
        XCTAssertGreaterThan(try pixel(softMask, x: 49, y: 15)[0],
                             try pixel(hardMask, x: 49, y: 15)[0])

        let edge = LocalAdjustment(feather: 0.05, strokes: [
            MaskStroke(points: [MaskPoint(x: 0, y: 0.5)], radius: 0.3)
        ])
        let edgeMask = try pipeline.renderMask(adjustment: edge, sourceWidth: 80, sourceHeight: 60,
                                               edits: .neutral, maxPixel: 1600)
        XCTAssertEqual(Int(try pixel(edgeMask, x: 0, y: 30)[0]),
                       Int(try pixel(edgeMask, x: 5, y: 30)[0]), accuracy: 2)

        let edits = EditSettings(rotationQuarterTurns: 1, cropAspect: 1)
        let full = try pipeline.renderMask(adjustment: sharp, sourceWidth: 80, sourceHeight: 60,
                                           edits: edits, maxPixel: 1600)
        let preview = try pipeline.renderMask(adjustment: sharp, sourceWidth: 80, sourceHeight: 60,
                                              edits: edits, maxPixel: 30)
        XCTAssertEqual(full.width, 60)
        XCTAssertEqual(full.height, 60)
        XCTAssertEqual(preview.width, 30)
        XCTAssertEqual(preview.height, 30)
        XCTAssertGreaterThan(try pixel(full, x: 45, y: 30)[0], 200)
        XCTAssertGreaterThan(try pixel(preview, x: 22, y: 15)[0], 180)

        let directory = try temporaryDirectory()
        let url = try testImage(in: directory)
        let neutral = try pipeline.render(url: url, edits: EditSettings(rotationQuarterTurns: 1, cropAspect: 1),
                                          maxPixel: nil)
        var localEdits = edits
        localEdits.localAdjustments = [LocalAdjustment(exposure: 1, feather: 0, strokes: [
            MaskStroke(points: [MaskPoint(x: 0.5, y: 0.25)], radius: 0.15)
        ])]
        let rendered = try pipeline.render(url: url, edits: localEdits, maxPixel: nil)
        XCTAssertNotEqual(try pixel(rendered, x: 45, y: 30), try pixel(neutral, x: 45, y: 30))
        XCTAssertEqual(try pixel(rendered, x: 15, y: 30), try pixel(neutral, x: 15, y: 30))
    }
}
