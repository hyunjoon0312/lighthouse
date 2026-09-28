import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

/// Actual bundled model and file-format boundaries; no network or Python dependency.
final class AIDenoiseIntegrationTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext()

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func noisyImage(width: Int, height: Int, alpha: UInt8 = 255) -> CGImage {
        var seed: UInt64 = 918231
        var data = [UInt8](repeating: alpha, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            for channel in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1
                let noise = Int((seed >> 32) % 71) - 35
                data[i + channel] = UInt8((([80, 130, 180][channel] + noise) * Int(alpha)) / 255)
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rgba(_ image: CIImage, bounds: CGRect? = nil) -> [Float] {
        let rect = bounds ?? image.extent
        var values = [Float](repeating: 0, count: Int(rect.width * rect.height) * 4)
        context.render(image, toBitmap: &values, rowBytes: Int(rect.width) * 16,
                       bounds: rect, format: .RGBAf, colorSpace: space)
        return values
    }

    private func mse(_ values: [Float]) -> Double {
        var sum = 0.0
        let expected: [Double] = [80.0/255, 130.0/255, 180.0/255]
        for i in values.indices where i % 4 != 3 {
            sum += pow(Double(values[i]) - expected[i % 4], 2)
        }
        return sum / Double(values.count / 4 * 3)
    }

    func testBundledModelReducesJPEGAndHEICNoiseAndMatchesPreviewExport() throws {
        let root = try directory()
        let input = noisyImage(width: 269, height: 141)
        let edits = EditSettings(noiseReduction: .init(mode: .ai, amount: 0.3))
        let pipeline = ImagePipeline()
        for type in [UTType.jpeg, .heic] {
            let rotated = type == .heic
            let url = root.appendingPathComponent("input." + type.preferredFilenameExtension!)
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, input, [kCGImageDestinationLossyCompressionQuality: 1,
                                                     kCGImagePropertyOrientation: rotated ? 6 : 1] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            let before = SHA256.hash(data: try Data(contentsOf: url))
            let original = try pipeline.render(url: url, edits: .neutral, maxPixel: nil)
            let denoised = try pipeline.render(url: url, edits: edits, maxPixel: nil)
            XCTAssertEqual(denoised.width, rotated ? 141 : 269)
            XCTAssertEqual(denoised.height, rotated ? 269 : 141)
            XCTAssertLessThan(mse(rgba(CIImage(cgImage: denoised))), mse(rgba(CIImage(cgImage: original))) * 0.4)
            let preview = try pipeline.renderPreview(url: url, edits: edits, maxPixel: 180).image
            let render = try pipeline.render(url: url, edits: edits, maxPixel: 180)
            XCTAssertEqual(rgba(CIImage(cgImage: preview)), rgba(CIImage(cgImage: render)))
            let prepared = try pipeline.prepareExport(url: url, edits: edits,
                                                      options: ExportOptions(maxPixel: 180, quality: 1))
            XCTAssertEqual(prepared.image.width, preview.width)
            XCTAssertEqual(prepared.image.height, preview.height)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
        }
    }

    func testTileBoundariesAgreeWithShiftedCropAndPreserveAlpha() throws {
        let root = try directory()
        let source = CIImage(cgImage: noisyImage(width: 517, height: 387, alpha: 128))
        let service = NoiseReductionService()
        let edits = EditSettings(noiseReduction: .init(mode: .ai, amount: 0.3))
        let full = try service.apply(to: source, url: root.appendingPathComponent("full.png"), edits: edits,
                                     context: context, colorSpace: space)
        // 387 - (63 + 288) = 36 top rows: even phase for the 2× pixel unshuffle.
        let cropped = source.cropped(to: CGRect(x: 128, y: 63, width: 320, height: 288))
        let other = try service.apply(to: cropped, url: root.appendingPathComponent("crop.png"), edits: edits,
                                      context: context, colorSpace: space)
        XCTAssertEqual(full.extent, source.extent)
        XCTAssertEqual(other.extent, cropped.extent)
        // Both rectangles have the same 2-pixel shuffle phase, but their tile seams differ.
        let interior = CGRect(x: 176, y: 112, width: 224, height: 192)
        let a = rgba(full, bounds: interior), b = rgba(other, bounds: interior)
        XCTAssertLessThan(zip(a,b).map { abs($0 - $1) }.max()!, 0.003)
        for i in stride(from: 3, to: a.count, by: 4) { XCTAssertEqual(a[i], 128.0/255, accuracy: 0.001) }
    }

    func testSmallOddImagesRemainFiniteAndKeepExtent() throws {
        let root = try directory()
        let service = NoiseReductionService()
        let edits = EditSettings(noiseReduction: .init(mode: .ai, amount: 0.3))
        for (width, height) in [(1,1),(3,5),(31,17)] {
            let image = CIImage(cgImage: noisyImage(width: width, height: height))
                .transformed(by: CGAffineTransform(translationX: 4, y: -8))
            let output = try service.apply(to: image, url: root.appendingPathComponent("\(width).png"),
                                           edits: edits, context: context, colorSpace: space)
            XCTAssertEqual(output.extent, image.extent)
            XCTAssertTrue(rgba(output).allSatisfy(\.isFinite))
        }
        let tooLarge = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8001, height: 8001))
        XCTAssertThrowsError(try service.apply(to: tooLarge, url: root.appendingPathComponent("large.png"),
                                               edits: edits, context: context, colorSpace: space))
    }
}
