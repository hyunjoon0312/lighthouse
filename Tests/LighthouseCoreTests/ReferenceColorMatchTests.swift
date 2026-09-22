import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class ReferenceColorMatchTests: XCTestCase {
    private func sampleColors() -> [SIMD3<Double>] {
        [SIMD3(0.15, 0.22, 0.3), SIMD3(0.3, 0.42, 0.5),
         SIMD3(0.5, 0.48, 0.37), SIMD3(0.72, 0.61, 0.52),
         SIMD3(0.84, 0.77, 0.68)]
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func png(_ pixels: [UInt8], width: Int, height: Int, at url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                                                         UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }

    func testIdentityStrengthAndInvalidSamples() throws {
        let colors = sampleColors()
        let identity = try ColorMatchTransform(source: colors, reference: colors)
        for rgb in colors {
            let mapped = identity.map(rgb)
            for channel in 0..<3 { XCTAssertEqual(mapped[channel], rgb[channel], accuracy: 0.000_01) }
        }
        let changed = try ColorMatchTransform(source: colors,
            reference: colors.map { SIMD3(min(1, $0.x + 0.08), min(1, $0.y + 0.05), max(0, $0.z - 0.02)) })
        let value = SIMD3<Double>(0.2, 0.4, 0.6)
        XCTAssertEqual(changed.map(value, strength: 0), value)
        XCTAssertEqual(changed.map(value, strength: .nan), value)
        let half = changed.map(value, strength: 0.5)
        let full = changed.map(value)
        for channel in 0..<3 {
            XCTAssertEqual(half[channel], (value[channel] + full[channel]) / 2, accuracy: 0.000_001)
        }
        XCTAssertThrowsError(try ColorMatchTransform(source: [], reference: colors))
        XCTAssertThrowsError(try ColorMatchTransform(source: [SIMD3(.nan, 0, 0)], reference: colors))
        XCTAssertThrowsError(try ColorMatchTransform(source: [SIMD3(1.1, 0, 0)], reference: colors))
        XCTAssertThrowsError(try ColorMatchTransform(source: colors, reference: [SIMD3(-0.1, 0, 0)]))
    }

    func testWarmBrightReferenceMovesStatisticsAndUniformFinite() throws {
        let source = sampleColors()
        let reference = source.map { SIMD3(min(1, $0.x + 0.12), min(1, $0.y + 0.07), $0.z) }
        let transform = try ColorMatchTransform(source: source, reference: reference)
        let mapped = source.map { transform.map($0) }
        func mean(_ samples: [SIMD3<Double>]) -> SIMD3<Double> {
            samples.reduce(SIMD3<Double>(repeating: 0), +) / Double(samples.count)
        }
        let before = mean(source)
        let after = mean(mapped)
        let target = mean(reference)
        XCTAssertLessThan(abs(after.x - target.x), abs(before.x - target.x))
        XCTAssertLessThan(abs(after.y - target.y), abs(before.y - target.y))
        for color in [SIMD3<Double>(repeating: 0), SIMD3<Double>(repeating: 1),
                      SIMD3<Double>(0.5, 0.5, 0.5)] {
            let uniform = try ColorMatchTransform(source: [color, color], reference: [color, color])
            let output = uniform.map(color)
            XCTAssertTrue([output.x, output.y, output.z].allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
    }

    func testCubeHeaderSafeTitleAndRedFastestRoundTrip() throws {
        let colors = sampleColors()
        let identity = try ColorMatchTransform(source: colors, reference: colors)
        let data = identity.cubeData(title: "Name\"\n\u{0001}\u{2028}\u{2029} Safe", strength: 1)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines[0], "TITLE \"Name Safe\"")
        XCTAssertEqual(lines[1], "#LUMIXPHOTOSTYLE STD")
        XCTAssertFalse(text.contains("\u{0001}"))
        XCTAssertFalse(text.contains("\u{2028}"))
        XCTAssertFalse(text.contains("\u{2029}"))
        XCTAssertTrue(text.contains("DOMAIN_MIN 0 0 0"))
        XCTAssertTrue(text.contains("DOMAIN_MAX 1 1 1"))
        let cube = try CubeLUT.parse(data)
        XCTAssertEqual(cube.dimension, 33)
        XCTAssertEqual(cube.domainMin, SIMD3<Float>(repeating: 0))
        XCTAssertEqual(cube.domainMax, SIMD3<Float>(repeating: 1))
        let values = cube.cubeData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Double(values[4]), 1.0 / 32, accuracy: 0.000_01)
        XCTAssertEqual(Double(values[5]), 0, accuracy: 0.000_01)
        XCTAssertEqual(Double(values[33 * 4 + 1]), 1.0 / 32, accuracy: 0.000_01)
        XCTAssertEqual(Double(values[33 * 33 * 4 + 2]), 1.0 / 32, accuracy: 0.000_01)
        XCTAssertEqual(values.count, 33 * 33 * 33 * 4)
    }

    func testAnalyzeIgnoresCurrentLUTAndPreviewKeepsOrientationAlpha() throws {
        let directory = try directory()
        let sourceURL = directory.appendingPathComponent("source.png")
        let referenceURL = directory.appendingPathComponent("reference.png")
        // Row 0: red, half-transparent green. Row 1: blue, yellow.
        let source: [UInt8] = [180, 30, 30, 255, 15, 90, 15, 128,
                               30, 30, 180, 255, 170, 170, 30, 255]
        let reference: [UInt8] = [210, 70, 40, 255, 30, 105, 20, 128,
                                  40, 50, 190, 255, 200, 190, 45, 255]
        try png(source, width: 2, height: 2, at: sourceURL)
        try png(reference, width: 2, height: 2, at: referenceURL)
        var photo = PhotoAsset(url: sourceURL)
        photo.edits.lut = LUTAdjustment(id: String(repeating: "0", count: 64), name: "Missing")
        let matcher = ReferenceColorMatcher(lutDirectory: directory.appendingPathComponent("LUTs"))
        let result = try matcher.analyze(source: photo, referenceURL: referenceURL)
        XCTAssertEqual(result.sourcePreview.width, 2)
        XCTAssertEqual(result.referencePreview.height, 2)
        let unchanged = try matcher.preview(result: result, strength: 0)
        for y in 0..<2 {
            for x in 0..<2 {
                let before = try pixel(result.sourcePreview, x: x, y: y)
                let after = try pixel(unchanged, x: x, y: y)
                for channel in 0..<4 { XCTAssertEqual(Int(after[channel]), Int(before[channel]), accuracy: 1) }
            }
        }
        let applied = try matcher.preview(result: result, strength: 1)
        XCTAssertNotEqual(try pixel(applied, x: 0, y: 0), try pixel(unchanged, x: 0, y: 0))
        XCTAssertEqual(try pixel(applied, x: 1, y: 0)[3], try pixel(unchanged, x: 1, y: 0)[3])
        XCTAssertEqual(try pixel(applied, x: 0, y: 1)[3], 255)

        let clearURL = directory.appendingPathComponent("clear.png")
        try png(Array(repeating: 0, count: 16), width: 2, height: 2, at: clearURL)
        XCTAssertThrowsError(try matcher.analyze(source: PhotoAsset(url: clearURL), referenceURL: referenceURL))
    }
}
