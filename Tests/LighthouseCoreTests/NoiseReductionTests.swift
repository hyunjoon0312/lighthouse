import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import CoreML
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class NoiseReductionTests: XCTestCase {
    func testSettingsDefaultsRoundTripAndLegacyOmission() throws {
        let settings = NoiseReductionSettings()
        XCTAssertEqual(settings.mode, .off)
        XCTAssertEqual(settings.amount, 0.35)
        XCTAssertFalse(settings.isActive)
        XCTAssertFalse(NoiseReductionSettings(mode: .standard, amount: 0).isActive)
        XCTAssertTrue(NoiseReductionSettings(mode: .standard, amount: 0.4).isActive)

        let neutralData = try JSONEncoder().encode(EditSettings())
        let neutralObject = try XCTUnwrap(JSONSerialization.jsonObject(with: neutralData) as? [String: Any])
        XCTAssertNil(neutralObject["noiseReduction"])
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: neutralData).noiseReduction, settings)

        var legacyObject = neutralObject
        legacyObject.removeValue(forKey: "noiseReduction")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: legacyData).noiseReduction, settings)

        let active = EditSettings(noiseReduction: .init(mode: .ai, amount: 0.72))
        let activeData = try JSONEncoder().encode(active)
        let activeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: activeData) as? [String: Any])
        XCTAssertNotNil(activeObject["noiseReduction"])
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: activeData), active)
    }

    func testInvalidStoredSettingsAreRejected() throws {
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditSettings())) as! [String: Any]
        let invalidValues: [Any] = [
            NSNull(),
            "standard",
            ["mode": "unknown", "amount": 0.5],
            ["mode": "standard", "amount": -0.01],
            ["mode": "standard", "amount": 1.01],
            ["mode": "standard", "amount": "0.5"],
            ["mode": NSNull(), "amount": 0.5],
        ]
        for value in invalidValues {
            var object = valid
            object["noiseReduction"] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(EditSettings.self, from: data), "accepted \(value)")
        }

        let nonFinite = #"{"mode":"standard","amount":1e400}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(NoiseReductionSettings.self, from: nonFinite))
    }

    func testGlobalMergeCopiesNoiseReductionAndOtherComponentsPreserveIt() {
        let source = EditSettings(noiseReduction: .init(mode: .ai, amount: 0.8))
        let target = EditSettings(noiseReduction: .init(mode: .standard, amount: 0.2))
        XCTAssertEqual(target.merging(from: source, components: .global).noiseReduction,
                       source.noiseReduction)
        XCTAssertEqual(target.merging(from: source, components: .lut).noiseReduction,
                       target.noiseReduction)
        XCTAssertEqual(target.merging(from: source, components: .geometry).noiseReduction,
                       target.noiseReduction)
        XCTAssertEqual(source.changeSummary(from: .neutral), "노이즈 감소")
    }

    func testStandardReductionChangesPixelsAndPreservesSize() throws {
        let url = try temporaryImage(width: 72, height: 55) { x, y in
            let noise = ((x &* 73) ^ (y &* 151) ^ (x &* y &* 11)) & 63
            let value = UInt8(96 + noise)
            return (value, value, value, 255)
        }
        let pipeline = ImagePipeline()
        let bypass = try rgbaBytes(pipeline.render(url: url, edits: .neutral, maxPixel: nil))
        let zero = try rgbaBytes(pipeline.render(
            url: url,
            edits: EditSettings(noiseReduction: .init(mode: .ai, amount: 0)),
            maxPixel: nil
        ))
        XCTAssertEqual(zero, bypass, "AI amount 0 must bypass without loading the model")

        let changed = try pipeline.render(
            url: url,
            edits: EditSettings(noiseReduction: .init(mode: .standard, amount: 1)),
            maxPixel: nil
        )
        XCTAssertEqual(changed.width, 72)
        XCTAssertEqual(changed.height, 55)
        XCTAssertNotEqual(try rgbaBytes(changed), bypass)

        for invalid in [Double.nan, -.leastNonzeroMagnitude, 1.000_001] {
            XCTAssertThrowsError(try pipeline.render(
                url: url,
                edits: EditSettings(noiseReduction: .init(mode: .standard, amount: invalid)),
                maxPixel: nil
            ))
        }
        XCTAssertNoThrow(try pipeline.render(
            url: url,
            edits: EditSettings(noiseReduction: .init(mode: .off, amount: .nan)),
            maxPixel: nil
        ))
    }

    func testCacheKeyInvalidationAndUnrelatedEditReuse() throws {
        let url = URL(fileURLWithPath: "/tmp/noise-source.rw2")
        let date = Date(timeIntervalSinceReferenceDate: 1234)
        let attributes: [FileAttributeKey: Any] = [.size: NSNumber(value: 500), .modificationDate: date]
        let base = EditSettings(exposure: 0.2, temperatureShift: 50, tintShift: -2,
                                rawDevelop: .init(luminanceNoiseReduction: 0.1),
                                noiseReduction: .init(mode: .ai, amount: 0.4))
        let key = NoiseReductionService.CacheKey(url: url, attributes: attributes, edits: base,
                                                  width: 401, height: 303)

        var unrelated = base
        unrelated.contrast = 1.4
        unrelated.saturation = 0.7
        unrelated.sharpness = 0.8
        unrelated.rotationQuarterTurns = 1
        XCTAssertEqual(key, NoiseReductionService.CacheKey(url: url, attributes: attributes,
                                                            edits: unrelated, width: 401, height: 303))

        var rawChanged = base
        rawChanged.rawDevelop.colorNoiseReduction = 0.3
        XCTAssertNotEqual(key, NoiseReductionService.CacheKey(url: url, attributes: attributes,
                                                               edits: rawChanged, width: 401, height: 303))
        var amountChanged = base
        amountChanged.noiseReduction.amount = 0.5
        XCTAssertNotEqual(key, NoiseReductionService.CacheKey(url: url, attributes: attributes,
                                                               edits: amountChanged, width: 401, height: 303))
        XCTAssertNotEqual(key, NoiseReductionService.CacheKey(
            url: url,
            attributes: [.size: NSNumber(value: 501), .modificationDate: date],
            edits: base,
            width: 401,
            height: 303
        ))
        XCTAssertNotEqual(key, NoiseReductionService.CacheKey(url: url, attributes: attributes,
                                                               edits: base, width: 403, height: 303))

        let jpeg = URL(fileURLWithPath: "/tmp/noise-source.jpg")
        let jpegKey = NoiseReductionService.CacheKey(url: jpeg, attributes: attributes, edits: base,
                                                      width: 401, height: 303)
        var jpegExposureChanged = base
        jpegExposureChanged.exposure = 1.4
        jpegExposureChanged.temperatureShift = -500
        jpegExposureChanged.tintShift = 20
        jpegExposureChanged.rawDevelop = .init(colorNoiseReduction: 0.9)
        XCTAssertEqual(jpegKey, NoiseReductionService.CacheKey(url: jpeg, attributes: attributes,
                                                               edits: jpegExposureChanged,
                                                               width: 401, height: 303))
    }

    func testAITensorPackingUsesRGBPhaseOrderUnpremultipliesAlphaAndSetsSigma() throws {
        let size = NoiseReductionService.tileSize
        var floats = [Float](repeating: 0, count: size * size * 4)
        let x = 2, y = 3
        let pixel = (y * size + x) * 4
        floats[pixel] = 0.4
        floats[pixel + 1] = 0.2
        floats[pixel + 2] = 0.1
        floats[pixel + 3] = 0.5
        let input = try NoiseReductionService().inputArray(
            from: floats.withUnsafeBytes { Data($0) },
            rowBytes: size * 4 * MemoryLayout<Float>.size,
            sigma: 0.125
        )
        let channelStride = input.strides[0].intValue
        let rowStride = input.strides[1].intValue
        let columnStride = input.strides[2].intValue
        let offset = (y / 2) * rowStride + (x / 2) * columnStride
        let values = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        XCTAssertEqual(values[2 * channelStride + offset], 0.8, accuracy: 0.000_001)
        XCTAssertEqual(values[6 * channelStride + offset], 0.4, accuracy: 0.000_001)
        XCTAssertEqual(values[10 * channelStride + offset], 0.2, accuracy: 0.000_001)
        XCTAssertEqual(values[12 * channelStride + offset], 0.125, accuracy: 0.000_001)
    }

    func testAIOutputUsesDirectRGBAsResidualAndRepremultipliesAlpha() throws {
        let size = NoiseReductionService.tileSize
        var source = [Float](repeating: 0, count: size * size * 4)
        let tileX = NoiseReductionService.halo
        let tileY = NoiseReductionService.halo
        let pixel = (tileY * size + tileX) * 4
        source[pixel] = 0.6
        source[pixel + 1] = 0.125
        source[pixel + 2] = 0.05
        source[pixel + 3] = 0.5

        let prediction = try MLMultiArray(
            shape: [12, NSNumber(value: NoiseReductionService.modelSize),
                    NSNumber(value: NoiseReductionService.modelSize)],
            dataType: .float32
        )
        let channelStride = prediction.strides[0].intValue
        let rowStride = prediction.strides[1].intValue
        let columnStride = prediction.strides[2].intValue
        let modelOffset = (tileY / 2) * rowStride + (tileX / 2) * columnStride
        let values = prediction.dataPointer.bindMemory(to: Float.self, capacity: prediction.count)
        values[modelOffset] = 0.8
        values[4 * channelStride + modelOffset] = 0.4
        values[8 * channelStride + modelOffset] = 0.3

        var output = [UInt16](repeating: 0, count: 4)
        try NoiseReductionService().writeCore(
            source: source.withUnsafeBytes { Data($0) },
            rowBytes: size * 4 * MemoryLayout<Float>.size,
            prediction: prediction,
            coreX: 0,
            coreY: 0,
            width: 1,
            height: 1,
            output: &output
        )
        let decoded = try decodeHalf(output, width: 4, height: 1)
        XCTAssertEqual(decoded[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(decoded[1], 0.2, accuracy: 0.001)
        XCTAssertEqual(decoded[2], 0.15, accuracy: 0.001)
        XCTAssertEqual(decoded[3], 0.5, accuracy: 0.001)
    }

    func testAIHalfConversionUsesFullDestinationStrideAndPreservesNeighbors() throws {
        let tileSize = NoiseReductionService.tileSize
        var source = [Float](repeating: 0, count: tileSize * tileSize * 4)
        for y in NoiseReductionService.halo..<(NoiseReductionService.halo + 2) {
            for x in NoiseReductionService.halo..<(NoiseReductionService.halo + 2) {
                let offset = (y * tileSize + x) * 4
                source[offset] = 0.25
                source[offset + 1] = 0.5
                source[offset + 2] = 0.75
                source[offset + 3] = 1
            }
        }
        let prediction = try MLMultiArray(
            shape: [12, NSNumber(value: NoiseReductionService.modelSize),
                    NSNumber(value: NoiseReductionService.modelSize)],
            dataType: .float32
        )
        let channelStride = prediction.strides[0].intValue
        let rowStride = prediction.strides[1].intValue
        let columnStride = prediction.strides[2].intValue
        let modelOffset = 16 * rowStride + 16 * columnStride
        let predicted = prediction.dataPointer.bindMemory(to: Float.self, capacity: prediction.count)
        for phase in 0..<4 {
            predicted[phase * channelStride + modelOffset] = 0.25
            predicted[(4 + phase) * channelStride + modelOffset] = 0.5
            predicted[(8 + phase) * channelStride + modelOffset] = 0.75
        }

        let sentinel = UInt16.max
        var output = [UInt16](repeating: sentinel, count: 4 * 3 * 4)
        try NoiseReductionService().writeCore(
            source: source.withUnsafeBytes { Data($0) },
            rowBytes: tileSize * 4 * MemoryLayout<Float>.size,
            prediction: prediction,
            coreX: 2,
            coreY: 1,
            width: 4,
            height: 3,
            output: &output
        )
        for y in 0..<3 {
            for x in 0..<4 {
                let range = ((y * 4 + x) * 4)..<((y * 4 + x + 1) * 4)
                if y >= 1 && x >= 2 {
                    XCTAssertTrue(output[range].allSatisfy { $0 != sentinel })
                } else {
                    XCTAssertTrue(output[range].allSatisfy { $0 == sentinel })
                }
            }
        }
        for y in 1..<3 {
            let start = (y * 4 + 2) * 4
            let values = try decodeHalf(Array(output[start..<(start + 8)]), width: 8, height: 1)
            XCTAssertEqual(values, [0.25, 0.5, 0.75, 1, 0.25, 0.5, 0.75, 1])
        }
    }

    private func decodeHalf(_ values: [UInt16], width: Int, height: Int) throws -> [Float] {
        var source = values
        var destination = [Float](repeating: 0, count: width * height)
        let error = source.withUnsafeMutableBytes { (sourceBytes: UnsafeMutableRawBufferPointer) -> vImage_Error in
            destination.withUnsafeMutableBytes { (destinationBytes: UnsafeMutableRawBufferPointer) -> vImage_Error in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else { return kvImageNullPointerArgument }
                var sourceBuffer = vImage_Buffer(data: sourceBase, height: vImagePixelCount(height),
                                                 width: vImagePixelCount(width),
                                                 rowBytes: width * MemoryLayout<UInt16>.size)
                var destinationBuffer = vImage_Buffer(data: destinationBase, height: vImagePixelCount(height),
                                                      width: vImagePixelCount(width),
                                                      rowBytes: width * MemoryLayout<Float>.size)
                return vImageConvert_Planar16FtoPlanarF(&sourceBuffer, &destinationBuffer,
                                                        vImage_Flags(kvImageDoNotTile))
            }
        }
        guard error == kvImageNoError else { throw NoiseReductionError.renderFailed }
        return destination
    }

    private func temporaryImage(width: Int, height: Int,
                                pixels: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixels(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = value.0
                bytes[offset + 1] = value.1
                bytes[offset + 2] = value.2
                bytes[offset + 3] = value.3
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighthouse-noise-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func rgbaBytes(_ image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        var bytes = Data(count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(rendered)
        return bytes
    }
}
