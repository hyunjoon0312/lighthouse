import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LighthouseCore

final class LightroomToneTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func testLegacyJSONDefaultsNewFieldsAndDefaultEncodingOmitsKeys() throws {
        let encoded = try JSONEncoder().encode(EditSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["whites"])
        XCTAssertNil(object["blacks"])
        XCTAssertNil(object["colorProfile"])

        var grain = try XCTUnwrap(object["grain"] as? [String: Any])
        XCTAssertNil(grain["roughness"])
        let decoded = try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.whites, 0)
        XCTAssertEqual(decoded.blacks, 0)
        XCTAssertEqual(decoded.colorProfile, .color)
        XCTAssertEqual(decoded.grain.roughness, 0.5)

        object["whites"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        object.removeValue(forKey: "whites")
        object["colorProfile"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        object["colorProfile"] = "cameraStandard"
        XCTAssertThrowsError(try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        object.removeValue(forKey: "colorProfile")
        grain["roughness"] = 1.1
        object["grain"] = grain
        XCTAssertThrowsError(try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        grain["roughness"] = NSNull()
        object["grain"] = grain
        XCTAssertThrowsError(try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testNewSettingsRoundTripModificationAndGlobalMerge() throws {
        let source = EditSettings(highlights: 1.4, shadows: -0.3, whites: 0.25, blacks: -0.2,
                                  colorProfile: .monochrome,
                                  grain: GrainSettings(amount: 0.4, size: 2, seed: 7, roughness: 0.8))
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(source)), source)
        XCTAssertTrue(source.isModified)
        XCTAssertEqual(EditSettings().merging(from: source, components: .global), source)
        XCTAssertEqual(EditSettings().merging(from: source, components: .geometry).colorProfile, .color)
    }

    func testAdditionalToneDirectionsMonotonicityAndNeutralPixels() throws {
        let source = grayscaleRamp()
        let original = try rgba8(source)
        let neutral = try rgba8(AdvancedColorProcessor.applyAdditionalTone(
            to: source, highlights: 1, shadows: 0, whites: 0, blacks: 0
        ))
        XCTAssertEqual(neutral, original)

        let highlight = try rgba8(AdvancedColorProcessor.applyAdditionalTone(
            to: source, highlights: 2, shadows: 0, whites: 0, blacks: 0
        ))
        let shadow = try rgba8(AdvancedColorProcessor.applyAdditionalTone(
            to: source, highlights: 1, shadows: -1, whites: 0, blacks: 0
        ))
        let whites = try rgba8(AdvancedColorProcessor.applyAdditionalTone(
            to: source, highlights: 1, shadows: 0, whites: 1, blacks: 0
        ))
        let blacks = try rgba8(AdvancedColorProcessor.applyAdditionalTone(
            to: source, highlights: 1, shadows: 0, whites: 0, blacks: -1
        ))
        XCTAssertGreaterThan(highlight[12], original[12])
        XCTAssertLessThan(shadow[4], original[4])
        XCTAssertGreaterThan(whites[12], original[12])
        XCTAssertLessThan(blacks[4], original[4])
        for data in [highlight, shadow, whites, blacks] {
            let values = stride(from: 0, to: data.count, by: 4).map { data[$0] }
            XCTAssertEqual(values, values.sorted())
            XCTAssertEqual(data[3], 255)
            XCTAssertEqual(data[data.count - 1], 255)
        }
        XCTAssertThrowsError(try AdvancedColorProcessor.applyAdditionalTone(
            to: source, highlights: 2.1, shadows: 0, whites: 0, blacks: 0
        ))
    }

    func testAdditionalToneBoundaryContinuityExtendedRangeAndAlpha() throws {
        let lower = try toneFloats(values: [-0.001, 0, 0.001], alpha: 1,
                                   highlights: 1, shadows: 0, whites: 0, blacks: 1)
        let upper = try toneFloats(values: [0.999, 1, 1.001, 1.5], alpha: 1,
                                   highlights: 1, shadows: 0, whites: -1, blacks: 0)
        for values in [lower, upper] {
            XCTAssertTrue(values.allSatisfy(\.isFinite))
            for pair in zip(values, values.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1, pair.0)
            }
        }
        XCTAssertEqual(lower[1] - lower[0], lower[2] - lower[1], accuracy: 0.002)
        XCTAssertEqual(upper[1] - upper[0], upper[2] - upper[1], accuracy: 0.002)
        XCTAssertGreaterThan(upper[3], 1, "확장 범위를 전부 1로 자르지 않는다")
        XCTAssertEqual(upper[3] - upper[2], 0.499, accuracy: 0.003,
                       "끝점 이동 뒤에도 확장 범위의 상대 차이를 보존한다")

        let alpha = try toneFloats(values: [0.2, 0.5, 0.8], alpha: 0.4,
                                   highlights: 1.5, shadows: -0.5, whites: 0.4, blacks: -0.3,
                                   includeAlpha: true)
        let opaque = try toneFloats(values: [0.2, 0.5, 0.8], alpha: 1,
                                    highlights: 1.5, shadows: -0.5, whites: 0.4, blacks: -0.3)
        for index in stride(from: 3, to: alpha.count, by: 4) {
            XCTAssertEqual(alpha[index], 0.4, accuracy: 0.000_5)
        }
        for pixel in 0..<opaque.count {
            XCTAssertEqual(alpha[pixel * 4] / alpha[pixel * 4 + 3], opaque[pixel], accuracy: 0.001)
        }
        XCTAssertTrue(alpha.allSatisfy(\.isFinite))
    }

    func testGrainRoughnessKeepsLegacyDefaultAndChangesTextureDeterministically() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let legacy = GrainSettings(amount: 0.8, size: 2, seed: 42)
        let defaultBytes = try rgba8(AdvancedColorProcessor.applyGrain(to: source, settings: legacy))
        let explicitLegacy = try rgba8(AdvancedColorProcessor.applyGrain(
            to: source,
            settings: GrainSettings(amount: 0.8, size: 2, seed: 42, roughness: 0.5)
        ))
        XCTAssertEqual(defaultBytes, explicitLegacy)
        for roughness in [0.0, 1.0] {
            let settings = GrainSettings(amount: 0.8, size: 2, seed: 42, roughness: roughness)
            let first = try rgba8(AdvancedColorProcessor.applyGrain(to: source, settings: settings))
            let second = try rgba8(AdvancedColorProcessor.applyGrain(to: source, settings: settings))
            XCTAssertEqual(first, second)
            XCTAssertNotEqual(first, defaultBytes)
            for alpha in stride(from: 3, to: first.count, by: 4) {
                XCTAssertEqual(first[alpha], 153, accuracy: 1)
            }
        }
        XCTAssertThrowsError(try AdvancedColorProcessor.applyGrain(
            to: source,
            settings: GrainSettings(amount: 0.5, roughness: .nan)
        ))
    }

    func testMonochromeAndToneUseSamePreviewAndExactCompositionPath() throws {
        let url = try temporaryPNG()
        let edits = EditSettings(highlights: 1.3, shadows: -0.2, whites: 0.4, blacks: -0.3,
                                 colorProfile: .monochrome)
        let pipeline = ImagePipeline(cachesDevelopment: true)
        let preview = try pipeline.renderPreview(url: url, edits: edits, maxPixel: nil,
                                                 allowApproximation: true)
        let exact = try ImagePipeline().render(url: url, edits: edits, maxPixel: nil)
        XCTAssertFalse(preview.isApproximate)
        XCTAssertEqual(try rgba8(preview.image), try rgba8(exact))
        let bytes = try rgba8(exact)
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            XCTAssertEqual(bytes[pixel], bytes[pixel + 1], accuracy: 1)
            XCTAssertEqual(bytes[pixel], bytes[pixel + 2], accuracy: 1)
        }
    }

    private func grayscaleRamp() -> CIImage {
        let data = Data([0, 0, 0, 255, 64, 64, 64, 255, 128, 128, 128, 255,
                         192, 192, 192, 255, 255, 255, 255, 255])
        return CIImage(bitmapData: data, bytesPerRow: 20, size: CGSize(width: 5, height: 1),
                       format: .RGBA8, colorSpace: colorSpace)
    }

    private func rgba8(_ image: CIImage) throws -> Data {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                           bounds: image.extent, format: .RGBA8, colorSpace: colorSpace)
        }
        return data
    }

    private func rgba8(_ image: CGImage) throws -> Data {
        try rgba8(CIImage(cgImage: image))
    }

    private func toneFloats(values: [Float], alpha: Float, highlights: Double, shadows: Double,
                            whites: Double, blacks: Double, includeAlpha: Bool = false) throws -> [Float] {
        var source: [Float] = []
        for value in values {
            source += [value * alpha, value * alpha, value * alpha, alpha]
        }
        let data = source.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: values.count * 16,
                            size: CGSize(width: values.count, height: 1), format: .RGBAf,
                            colorSpace: colorSpace)
        let changed = try AdvancedColorProcessor.applyAdditionalTone(
            to: image, highlights: highlights, shadows: shadows, whites: whites, blacks: blacks
        )
        var result = [Float](repeating: 0, count: source.count)
        result.withUnsafeMutableBytes { bytes in
            context.render(changed, toBitmap: bytes.baseAddress!, rowBytes: values.count * 16,
                           bounds: changed.extent, format: .RGBAf, colorSpace: colorSpace)
        }
        if includeAlpha { return result }
        return stride(from: 0, to: result.count, by: 4).map { result[$0] / max(result[$0 + 3], 0.000_001) }
    }

    private func temporaryPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let bytes = Data([255, 32, 16, 255, 16, 128, 240, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: 8, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
