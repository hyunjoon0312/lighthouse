import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class AdvancedImagingTests: XCTestCase {
    func testBaseMaskInvertThenEraseUsesStoredPNG() throws {
        let pipeline = ImagePipeline()
        let baseImage = try makeImage(width: 20, height: 12) { x, _ in
            x < 10 ? (255, 255, 255, 255) : (0, 0, 0, 255)
        }
        let mask = RasterMask(width: 20, height: 12, pngData: try pngData(baseImage))
        let adjustment = LocalAdjustment(
            feather: 0,
            strokes: [MaskStroke(points: [MaskPoint(x: 0.75, y: 0.5)],
                                 radius: 0.12, isErasing: true)],
            baseMask: mask,
            isInverted: true
        )

        let rendered = try pipeline.renderMask(adjustment: adjustment,
                                               sourceWidth: 20, sourceHeight: 12,
                                               edits: .neutral, maxPixel: 20)
        XCTAssertLessThan(try gray(rendered, x: 3, y: 6), 10)
        XCTAssertGreaterThan(try gray(rendered, x: 19, y: 6), 245)
        XCTAssertLessThan(try gray(rendered, x: 15, y: 6), 10)
    }

    func testStoredMaskRejectsInvalidPNGAndDimensionMismatch() throws {
        let pipeline = ImagePipeline()
        let invalid = LocalAdjustment(baseMask: RasterMask(width: 2, height: 2,
                                                            pngData: Data([0, 1, 2])))
        XCTAssertThrowsError(try pipeline.renderMask(adjustment: invalid,
                                                     sourceWidth: 20, sourceHeight: 12,
                                                     edits: .neutral))

        let png = try pngData(makeImage(width: 3, height: 2) { _, _ in (255, 255, 255, 255) })
        let mismatch = LocalAdjustment(baseMask: RasterMask(width: 2, height: 2, pngData: png))
        XCTAssertThrowsError(try pipeline.renderMask(adjustment: mismatch,
                                                     sourceWidth: 20, sourceHeight: 12,
                                                     edits: .neutral))

        let input = try temporaryPNG(width: 20, height: 12) { _, _ in (80, 90, 100, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        XCTAssertThrowsError(try pipeline.render(
            url: input, edits: EditSettings(localAdjustments: [invalid]), maxPixel: nil
        ))
    }

    func testCloneCopiesRequestedSourceAndPreservesOtherPixels() throws {
        let input = try temporaryPNG(width: 64, height: 32) { x, _ in
            x < 32 ? (240, 20, 20, 255) : (20, 40, 230, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let stroke = RetouchStroke(
            mode: .clone,
            points: [MaskPoint(x: 0.75, y: 0.5)],
            radius: 0.10,
            sourceOffset: MaskPoint(x: -0.5, y: 0)
        )
        let output = try ImagePipeline().render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )

        let copied = try rgba(output, x: 48, y: 16)
        XCTAssertGreaterThan(copied.0, 220)
        XCTAssertLessThan(copied.2, 50)
        let untouched = try rgba(output, x: 60, y: 4)
        XCTAssertLessThan(untouched.0, 50)
        XCTAssertGreaterThan(untouched.2, 200)
    }

    func testCloneWithSourceOutsideImageLeavesDestinationUnchanged() throws {
        let input = try temporaryPNG(width: 64, height: 32) { x, y in
            (UInt8(x * 3), UInt8(y * 5), 90, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let original = try pipeline.render(url: input, edits: .neutral, maxPixel: nil)
        let stroke = RetouchStroke(
            mode: .clone,
            points: [MaskPoint(x: 0.04, y: 0.5)],
            radius: 0.025,
            sourceOffset: MaskPoint(x: -0.25, y: 0)
        )
        let cloned = try pipeline.render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )
        let actual = try rgba(cloned, x: 2, y: 16)
        let expected = try rgba(original, x: 2, y: 16)
        XCTAssertEqual(actual.0, expected.0)
        XCTAssertEqual(actual.1, expected.1)
        XCTAssertEqual(actual.2, expected.2)
        XCTAssertEqual(actual.3, expected.3)
    }

    func testLongHealStrokeRejectsOverlappingCandidatePaths() throws {
        let input = try temporaryPNG(width: 64, height: 64) { _, _ in (128, 128, 128, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let stroke = RetouchStroke(
            mode: .heal,
            points: [MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.8, y: 0.8)],
            radius: 0.05
        )
        XCTAssertThrowsError(try ImagePipeline().render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )) { error in
            XCTAssertEqual(error as? RetouchProcessingError, .noHealingSource)
        }
    }

    func testHealReducesSmallSpotErrorAndKeepsDistantPixelsFinite() throws {
        let input = try temporaryPNG(width: 64, height: 64) { x, y in
            (29...35).contains(x) && (29...35).contains(y)
                ? (0, 0, 0, 255) : (160, 160, 160, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let original = try pipeline.render(url: input, edits: .neutral, maxPixel: nil)
        let stroke = RetouchStroke(mode: .heal,
                                   points: [MaskPoint(x: 0.5, y: 0.5)],
                                   radius: 0.055)
        let healed = try pipeline.render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )
        let originalCenter = try rgba(original, x: 32, y: 32)
        let healedCenter = try rgba(healed, x: 32, y: 32)
        XCTAssertGreaterThan(healedCenter.0, originalCenter.0 + 20)
        XCTAssertGreaterThan(healedCenter.1, originalCenter.1 + 20)
        XCTAssertGreaterThan(healedCenter.2, originalCenter.2 + 20)

        let distant = try rgba(healed, x: 4, y: 4)
        XCTAssertGreaterThan(distant.0, 140)
        XCTAssertGreaterThan(distant.1, 140)
        XCTAssertGreaterThan(distant.2, 140)
        XCTAssertEqual(distant.3, 255)
    }

    func testStraightenedImageHasOpaqueSafeCornersAndFinalScale() throws {
        let input = try temporaryPNG(width: 80, height: 50) { _, _ in (80, 120, 160, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let output = try ImagePipeline().render(
            url: input,
            edits: EditSettings(straightenDegrees: 13,
                                cropRect: NormalizedCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            maxPixel: 32
        )
        XCTAssertLessThanOrEqual(max(output.width, output.height), 32)
        for point in [(0, 0), (output.width - 1, 0),
                      (0, output.height - 1), (output.width - 1, output.height - 1)] {
            XCTAssertEqual(try rgba(output, x: point.0, y: point.1).3, 255)
        }
    }

    func testPreparedJPEGDecodesExactBytesAndWritePreservesExistingFile() throws {
        let input = try temporaryPNG(width: 48, height: 32) { x, y in
            (UInt8(x * 5), UInt8(y * 7), UInt8((x + y) * 3), 255)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: directory)
        }
        let pipeline = ImagePipeline()
        let low = try pipeline.prepareJPEG(url: input, edits: .neutral,
                                           maxPixel: 24, quality: 0.2)
        let high = try pipeline.prepareJPEG(url: input, edits: .neutral,
                                            maxPixel: 24, quality: 0.95)
        XCTAssertEqual(low.image.width, low.width)
        XCTAssertEqual(low.image.height, low.height)
        XCTAssertLessThanOrEqual(max(low.width, low.height), 24)
        XCTAssertNotEqual(low.data, high.data)

        let existing = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-edited.jpg")
        let sentinel = Data("existing".utf8)
        try sentinel.write(to: existing)
        let written = try pipeline.writeJPEG(high.data, sourceURL: input, to: directory)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try Data(contentsOf: written), high.data)
        XCTAssertTrue(written.lastPathComponent.hasSuffix("-edited-2.jpg"))
    }

    private func temporaryPNG(width: Int, height: Int,
                              pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> URL {
        let image = try makeImage(width: width, height: height, pixel: pixel)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try pngData(image).write(to: url)
        return url
    }

    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let index = y * rowBytes + x * 4
                bytes[index] = color.0
                bytes[index + 1] = color.1
                bytes[index + 2] = color.2
                bytes[index + 3] = color.3
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw TestError.imageCreation
        }
        return image
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw TestError.imageCreation }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.imageCreation }
        return data as Data
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else {
            throw TestError.pixelOutsideImage
        }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestError.imageCreation
        }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y * image.width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    private func gray(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        try rgba(image, x: x, y: y).0
    }

    private enum TestError: Error {
        case imageCreation
        case pixelOutsideImage
    }
}
