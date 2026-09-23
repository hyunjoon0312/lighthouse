import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import LighthouseCore

final class AdvancedColorTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func testCurveIdentityEndpointsNodesAndNonmonotonicBounds() throws {
        XCTAssertEqual(try AdvancedColorProcessor.curveValue(0, points: ToneCurves.identityPoints), 0)
        XCTAssertEqual(try AdvancedColorProcessor.curveValue(0.37, points: ToneCurves.identityPoints), 0.37,
                       accuracy: 0.000_001)
        XCTAssertEqual(try AdvancedColorProcessor.curveValue(1, points: ToneCurves.identityPoints), 1)

        let points = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 0.4, y: 0.9),
                      CurvePoint(x: 0.7, y: 0.1), CurvePoint(x: 1, y: 0.8)]
        XCTAssertEqual(try AdvancedColorProcessor.curveValue(0.4, points: points), 0.9,
                       accuracy: 0.000_001)
        XCTAssertEqual(try AdvancedColorProcessor.curveValue(0.7, points: points), 0.1,
                       accuracy: 0.000_001)
        for sample in stride(from: 0.0, through: 1.0, by: 0.01) {
            let value = try AdvancedColorProcessor.curveValue(sample, points: points)
            XCTAssertTrue(value.isFinite)
            XCTAssertTrue((0...1).contains(value))
        }
    }

    func testCurveRejectsInvalidPointsAndInput() {
        XCTAssertThrowsError(try AdvancedColorProcessor.curveValue(.nan, points: ToneCurves.identityPoints))
        XCTAssertThrowsError(try AdvancedColorProcessor.curveValue(
            0.5,
            points: [.init(x: 0, y: 0), .init(x: 0, y: 0.5), .init(x: 1, y: 1)]
        ))
        XCTAssertThrowsError(try AdvancedColorProcessor.curveValue(
            0.5,
            points: [.init(x: 0.1, y: 0), .init(x: 1, y: 1)]
        ))
    }

    func testMasterCurveRunsBeforePerChannelCurves() throws {
        let master = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.25),
                      CurvePoint(x: 1, y: 1)]
        let red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.5),
                   CurvePoint(x: 1, y: 1)]
        let output = try AdvancedColorProcessor.transformRGB(
            SIMD3(repeating: 0.5),
            curves: ToneCurves(master: master, red: red),
            ranges: []
        )
        XCTAssertEqual(output.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(output.y, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(output.z, 0.25, accuracy: 0.000_001)
    }

    func testHSLBandsAreBoundedOrderIndependentAndHueSelective() throws {
        let red = SIMD3(0.9, 0.1, 0.1)
        let redAdjustment = ColorRangeAdjustment(band: .red, hue: 20, saturation: -0.2,
                                                 lightness: 0.2)
        let changed = try AdvancedColorProcessor.transformRGB(red, curves: .identity,
                                                              ranges: [redAdjustment])
        XCTAssertNotEqual(changed, red)
        for component in [changed.x, changed.y, changed.z] {
            XCTAssertTrue((0...1).contains(component))
        }

        let outside = try AdvancedColorProcessor.transformRGB(
            red,
            curves: .identity,
            ranges: [.init(band: .blue, hue: 30, saturation: 1, lightness: 1)]
        )
        XCTAssertEqual(outside.x, red.x, accuracy: 0.000_001)
        XCTAssertEqual(outside.y, red.y, accuracy: 0.000_001)
        XCTAssertEqual(outside.z, red.z, accuracy: 0.000_001)

        let original = SIMD3(0.9, 0.45, 0.1)
        let first = ColorRangeAdjustment(band: .orange, hue: -10, saturation: 0.2)
        let second = ColorRangeAdjustment(band: .yellow, lightness: -0.3)
        let forward = try AdvancedColorProcessor.transformRGB(original, curves: .identity,
                                                              ranges: [first, second])
        let reverse = try AdvancedColorProcessor.transformRGB(original, curves: .identity,
                                                              ranges: [second, first])
        XCTAssertEqual(forward.x, reverse.x, accuracy: 0.000_000_001)
        XCTAssertEqual(forward.y, reverse.y, accuracy: 0.000_000_001)
        XCTAssertEqual(forward.z, reverse.z, accuracy: 0.000_000_001)
    }

    func testAchromaticProtectionKeepsGrayAndScalesLowSaturationContinuously() throws {
        let adjustment = ColorRangeAdjustment(band: .red, hue: 30, saturation: 0.7,
                                              lightness: 0.5)
        let gray = SIMD3<Double>(repeating: 0.5)
        XCTAssertEqual(try AdvancedColorProcessor.transformRGB(gray, curves: .identity,
                                                               ranges: [adjustment]), gray)

        let low = SIMD3(0.55, 0.45, 0.45)
        let high = SIMD3(0.9, 0.1, 0.1)
        let lowChanged = try AdvancedColorProcessor.transformRGB(low, curves: .identity,
                                                                 ranges: [adjustment])
        let highChanged = try AdvancedColorProcessor.transformRGB(high, curves: .identity,
                                                                  ranges: [adjustment])
        XCTAssertGreaterThan(distance(lowChanged, low), 0)
        XCTAssertLessThan(distance(lowChanged, low), distance(highChanged, high))
    }

    func testColorValidationRejectsDuplicatesAndOutOfRangeValues() {
        XCTAssertThrowsError(try AdvancedColorProcessor.transformRGB(
            SIMD3(repeating: 0.5), curves: .identity,
            ranges: [.init(band: .red), .init(band: .red, hue: 1)]
        ))
        XCTAssertThrowsError(try AdvancedColorProcessor.transformRGB(
            SIMD3(repeating: 0.5), curves: .identity,
            ranges: [.init(band: .green, hue: 31)]
        ))
        XCTAssertThrowsError(try AdvancedColorProcessor.transformRGB(
            SIMD3(.nan, 0, 0), curves: .identity, ranges: []
        ))
    }

    func testColorCubePreservesAlphaAndNeutralBypasses() throws {
        let source = CIImage(color: CIColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let neutral = try AdvancedColorProcessor.applyColor(to: source, curves: .identity, ranges: [])
        XCTAssertEqual(neutral.extent, source.extent)
        XCTAssertEqual(try rgba8(neutral), try rgba8(source))

        let changed = try AdvancedColorProcessor.applyColor(
            to: source,
            curves: ToneCurves(red: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.8), .init(x: 1, y: 1)]),
            ranges: []
        )
        let sourceBytes = try rgba8(source)
        let changedBytes = try rgba8(changed)
        XCTAssertNotEqual(changedBytes, sourceBytes)
        XCTAssertEqual(changedBytes[3], sourceBytes[3])
    }

    func testLargeSeedGrainIsDeterministicVariedMonochromeAndAlphaPreserving() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let settings = GrainSettings(amount: 0.8, size: 1.5, seed: .max)
        let first = try rgba8(AdvancedColorProcessor.applyGrain(to: source, settings: settings))
        let second = try rgba8(AdvancedColorProcessor.applyGrain(to: source, settings: settings))
        XCTAssertEqual(first, second)

        var redValues = Set<UInt8>()
        for pixel in stride(from: 0, to: first.count, by: 4) {
            redValues.insert(first[pixel])
            XCTAssertEqual(first[pixel], first[pixel + 1], accuracy: 1)
            XCTAssertEqual(first[pixel], first[pixel + 2], accuracy: 1)
            XCTAssertEqual(first[pixel + 3], 153, accuracy: 1)
        }
        XCTAssertGreaterThan(redValues.count, 16)

        let other = try rgba8(AdvancedColorProcessor.applyGrain(
            to: source,
            settings: GrainSettings(amount: 0.8, size: 1.5, seed: UInt32.max - 1)
        ))
        XCTAssertNotEqual(first, other)
    }

    func testGrainNeutralBypassesAndInvalidSettingsFail() throws {
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 3, height: 3))
        XCTAssertEqual(
            try rgba8(AdvancedColorProcessor.applyGrain(to: source, settings: GrainSettings())),
            try rgba8(source)
        )
        XCTAssertThrowsError(try AdvancedColorProcessor.applyGrain(
            to: source,
            settings: GrainSettings(amount: 1.1)
        ))
        XCTAssertThrowsError(try AdvancedColorProcessor.applyGrain(
            to: source,
            settings: GrainSettings(amount: 0, size: .nan)
        ))
    }

    private func rgba8(_ image: CIImage) throws -> Data {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            context.render(
                image,
                toBitmap: bytes.baseAddress!,
                rowBytes: width * 4,
                bounds: image.extent,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return data
    }

    private func distance(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> Double {
        let delta = first - second
        return (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
    }
}
