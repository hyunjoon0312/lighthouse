import CoreGraphics
import Foundation
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import LighthouseCore

final class WorkflowImagingTests: XCTestCase {
    func testKnownPhaseCorrectionUsesTopLeftCoordinates() throws {
        let url = try bandedImage(width: 160, height: 240, cycles: 7.3, phase: 0.17, amplitude: 0.16)
        defer { try? FileManager.default.removeItem(at: url) }
        let coefficients = [0.16, 0.0, 0, 0, 0, 0]
        let profile = FlickerProfile(redCoefficients: coefficients, greenCoefficients: coefficients,
                                     blueCoefficients: coefficients, referenceAmplitudeEV: 0.16)
        let settings = FlickerSettings(isEnabled: true, amount: 1, direction: .horizontal, cycles: 7.3,
                                       phase: 0.17, amplitudeEV: 0.16, profile: profile)
        let pipeline = ImagePipeline()
        let original = try pipeline.render(url: url, edits: .neutral, maxPixel: nil)
        let corrected = try pipeline.render(url: url, edits: EditSettings(flicker: settings), maxPixel: nil)
        XCTAssertLessThan(rowVariance(corrected), rowVariance(original) * 0.35)
    }

    func testAnalysisFindsFractionalFrequencyAndCorrectionReducesError() throws {
        for cycles in [7.3, 21.8, 13.4] {
            let url = try bandedImage(width: 192, height: 320, cycles: cycles, phase: 0.11, amplitude: 0.13)
            defer { try? FileManager.default.removeItem(at: url) }
            let pipeline = ImagePipeline()
            let analysis = try pipeline.analyzeFlicker(url: url)
            XCTAssertEqual(analysis.settings.direction, .horizontal)
            XCTAssertLessThan(abs(analysis.settings.cycles - cycles), 0.35)
            var settings = analysis.settings
            settings.amount = 1
            let original = try pipeline.render(url: url, edits: .neutral, maxPixel: nil)
            let corrected = try pipeline.render(url: url, edits: EditSettings(flicker: settings), maxPixel: nil)
            XCTAssertLessThan(rowVariance(corrected), rowVariance(original) * 0.35, "cycles \(cycles)")
        }
    }

    func testSmoothGradientAndLocalizedStripeAreRejected() throws {
        let smooth = try imageURL(width: 192, height: 256) { x, y in
            let value = 0.18 + 0.62 * Double(x + y) / Double(192 + 256)
            return (value, value, value, 1)
        }
        defer { try? FileManager.default.removeItem(at: smooth) }
        XCTAssertThrowsError(try ImagePipeline().analyzeFlicker(url: smooth))

        let patch = try imageURL(width: 192, height: 256) { x, y in
            let correction = x < 48 ? 0.17 * sin(2 * .pi * (9.4 * Double(y) / 256 + 0.2)) : 0
            let value = Self.sRGBEncode(0.35 * exp2(correction))
            return (value, value, value, 1)
        }
        defer { try? FileManager.default.removeItem(at: patch) }
        XCTAssertThrowsError(try ImagePipeline().analyzeFlicker(url: patch))
    }

    func testRangeMasksUseStoredGrayscalePNG() throws {
        let url = try imageURL(width: 64, height: 16) { x, _ in
            let value = Double(x) / 63
            return (value, 0, 1 - value, 1)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = ImagePipeline()
        let luminance = try pipeline.rangeMask(url: url,
                                               selection: .init(lower: 0.18, upper: 0.3, softness: 0.05))
        XCTAssertEqual(luminance.width, 64)
        XCTAssertEqual(luminance.height, 16)
        XCTAssertLessThan(luminance.pngData.count, 8 * 1_024 * 1_024)
        let color = try pipeline.rangeMask(url: url,
                                           selection: .init(kind: .color, red: 1, green: 0, blue: 0,
                                                            tolerance: 0.08))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(color.pngData as CFData, nil))
        let mask = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertGreaterThan(gray(mask, x: 62, y: 8), 220)
        XCTAssertLessThan(gray(mask, x: 2, y: 8), 20)
    }

    func testSmartPreviewIsOrientedBounded16BitTIFF() throws {
        let url = try imageURL(width: 96, height: 48) { x, y in
            (Double(x) / 95, Double(y) / 47, 0.25, 1)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try ImagePipeline().makeSmartPreview(url: url, maxPixel: 40)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.tiff.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 40)
        XCTAssertEqual(image.bitsPerComponent, 16)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
    }

    func testLocalNoiseCacheSeparatesUpstreamButNotMaskOrColorEdits() {
        let url = URL(fileURLWithPath: "/tmp/workflow-cache.rw2")
        let attributes: [FileAttributeKey: Any] = [.size: 42, .modificationDate: Date(timeIntervalSinceReferenceDate: 9)]
        var base = EditSettings(noiseReduction: .init(mode: .standard, amount: 0.2),
                                flicker: .init(isEnabled: true, cycles: 7.3))
        let local = NoiseReductionSettings(mode: .ai, amount: 0.4)
        let first = NoiseReductionService.CacheKey(url: url, attributes: attributes, edits: base,
                                                    settings: local, cacheContext: "upstream-a", width: 20, height: 10)
        base.localAdjustments = [LocalAdjustment(exposure: 1, strokes: [.init(points: [.init(x: 0.2, y: 0.2)], radius: 0.1)])]
        let maskChanged = NoiseReductionService.CacheKey(url: url, attributes: attributes, edits: base,
                                                          settings: local, cacheContext: "upstream-a", width: 20, height: 10)
        XCTAssertEqual(first, maskChanged)
        let upstreamChanged = NoiseReductionService.CacheKey(url: url, attributes: attributes, edits: base,
                                                              settings: local, cacheContext: "upstream-b", width: 20, height: 10)
        XCTAssertNotEqual(first, upstreamChanged)
    }

    private func bandedImage(width: Int, height: Int, cycles: Double,
                             phase: Double, amplitude: Double) throws -> URL {
        try imageURL(width: width, height: height) { x, y in
            let detail = 0.015 * sin(2 * .pi * Double(x) / 37)
            let correction = amplitude * sin(2 * .pi * (cycles * Double(y) / Double(height) + phase))
            let linear = max(0.01, 0.34 + detail) * exp2(correction)
            let value = Self.sRGBEncode(linear)
            return (value, value * 0.98, value * 0.95, 1)
        }
    }

    private func imageURL(width: Int, height: Int,
                          pixel: (Int, Int) -> (Double, Double, Double, Double)) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((min(1, max(0, value.0)) * 255).rounded())
                bytes[offset + 1] = UInt8((min(1, max(0, value.1)) * 255).rounded())
                bytes[offset + 2] = UInt8((min(1, max(0, value.2)) * 255).rounded())
                bytes[offset + 3] = UInt8((min(1, max(0, value.3)) * 255).rounded())
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                                                       UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func rowVariance(_ image: CGImage) -> Double {
        let values = (0..<image.height).map { y -> Double in
            (0..<image.width).reduce(0.0) { $0 + Double(gray(image, x: $1, y: y)) } / Double(image.width)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    }

    private func gray(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var byte: UInt8 = 0
        let context = CGContext(data: &byte, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                space: CGColorSpace(name: CGColorSpace.linearGray)!,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(-x), y: CGFloat(y + 1 - image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return byte
    }

    private static func sRGBEncode(_ linear: Double) -> Double {
        linear <= 0.003_130_8 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
}
