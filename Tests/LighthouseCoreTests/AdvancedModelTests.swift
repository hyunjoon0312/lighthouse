import CoreGraphics
import Foundation
import XCTest
@testable import LighthouseCore

final class AdvancedModelTests: XCTestCase {
    func testLegacyEditSettingsDefaultsNewFieldsAndRejectsPresentInvalidValues() throws {
        let encoded = try JSONEncoder().encode(EditSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["curves", "colorRanges", "grain", "straightenDegrees", "cropRect", "retouchStrokes"] {
            object.removeValue(forKey: key)
        }

        let decoded = try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.curves, .identity)
        XCTAssertEqual(decoded.colorRanges, [])
        XCTAssertEqual(decoded.grain, GrainSettings())
        XCTAssertEqual(decoded.straightenDegrees, 0)
        XCTAssertNil(decoded.cropRect)
        XCTAssertEqual(decoded.retouchStrokes, [])

        for key in ["curves", "colorRanges", "grain", "straightenDegrees", "retouchStrokes"] {
            var invalid = object
            invalid[key] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(
                EditSettings.self,
                from: JSONSerialization.data(withJSONObject: invalid)
            ), "Expected explicit null for \(key) to fail")
        }

        var nullCrop = object
        nullCrop["cropRect"] = NSNull()
        XCTAssertNil(try JSONDecoder().decode(
            EditSettings.self,
            from: JSONSerialization.data(withJSONObject: nullCrop)
        ).cropRect)
    }

    func testLegacyLocalAdjustmentDefaultsMaskFieldsAndRejectsInvalidInversion() throws {
        let adjustment = LocalAdjustment(name: "legacy")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(adjustment)
        ) as? [String: Any])
        object.removeValue(forKey: "baseMask")
        object.removeValue(forKey: "isInverted")

        let legacy = try JSONDecoder().decode(
            LocalAdjustment.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.baseMask)
        XCTAssertFalse(legacy.isInverted)

        object["baseMask"] = NSNull()
        object["isInverted"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(
            LocalAdjustment.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testAdvancedSettingsRoundTripAndModificationState() throws {
        let mask = RasterMask(width: 2, height: 3, pngData: Data([1, 2, 3]))
        let local = LocalAdjustment(baseMask: mask, isInverted: true)
        let curves = ToneCurves(
            master: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.7), .init(x: 1, y: 1)],
            red: ToneCurves.identityPoints,
            green: ToneCurves.identityPoints,
            blue: ToneCurves.identityPoints
        )
        let retouch = RetouchStroke(
            mode: .clone,
            points: [.init(x: 0.2, y: 0.3), .init(x: 0.25, y: 0.35)],
            radius: 0.04,
            sourceOffset: .init(x: -0.1, y: 0.2),
            isEnabled: false
        )
        let settings = EditSettings(
            localAdjustments: [local],
            curves: curves,
            colorRanges: [.init(band: .orange, hue: 4, saturation: 0.2, lightness: -0.1)],
            grain: .init(amount: 0.3, size: 2.5, seed: 42),
            straightenDegrees: -7,
            cropRect: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6),
            retouchStrokes: [retouch]
        )

        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertTrue(settings.isModified)
        XCTAssertFalse(EditSettings.neutral.isModified)
    }

    func testToneCurveValidationAtDecodeBoundary() throws {
        XCTAssertNoThrow(try ToneCurves.identity.validate())
        XCTAssertNoThrow(try ToneCurves(
            master: [.init(x: 0, y: 1), .init(x: 0.5, y: 0.1), .init(x: 1, y: 0.8)]
        ).validate())

        let invalidCurves = [
            [CurvePoint(x: 0, y: 0)],
            [CurvePoint(x: 0, y: 0), CurvePoint(x: 0, y: 1), CurvePoint(x: 1, y: 1)],
            [CurvePoint(x: 0.1, y: 0), CurvePoint(x: 1, y: 1)],
            [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: .infinity)]
        ]
        for points in invalidCurves {
            let value = ToneCurves(master: points)
            XCTAssertThrowsError(try value.validate())
            XCTAssertThrowsError(try JSONDecoder().decode(
                ToneCurves.self,
                from: JSONEncoder().encode(value)
            ))
        }
    }

    func testNormalizedCropClampsSizePositionAndNonfiniteValues() {
        XCTAssertEqual(NormalizedCrop(x: -1, y: 2, width: 0.001, height: 2).clamped,
                       NormalizedCrop(x: 0, y: 0, width: 0.02, height: 1))
        XCTAssertEqual(NormalizedCrop(x: 0.9, y: 0.8, width: 0.4, height: 0.5).clamped,
                       NormalizedCrop(x: 0.6, y: 0.5, width: 0.4, height: 0.5))
        XCTAssertEqual(NormalizedCrop(x: .nan, y: 0, width: 1, height: 1).clamped, .full)
    }

    func testLegacyGeometryMatchesExistingCoordinates() {
        let edits = EditSettings(rotationQuarterTurns: 1, cropAspect: 1)
        let geometry = PhotoGeometry(sourceWidth: 80, sourceHeight: 60, edits: edits)
        XCTAssertEqual(geometry.canvasSize.width, 60, accuracy: 0.000_001)
        XCTAssertEqual(geometry.canvasSize.height, 80, accuracy: 0.000_001)
        XCTAssertEqual(geometry.cropBounds, CGRect(x: 0, y: 10, width: 60, height: 60))
        XCTAssertEqual(geometry.outputSize, CGSize(width: 60, height: 60))
        XCTAssertEqual(geometry.displayAspect, 1, accuracy: 0.000_001)

        let display = geometry.displayPoint(fromSource: MaskPoint(x: 0.2, y: 0.25))
        XCTAssertEqual(display.x, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(display.y, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(geometry.displayRadius(fromSource: 0.1), 0.1, accuracy: 0.000_001)
    }

    func testGeometryRoundTripsAcrossTurnsStraightenAndCrop() {
        let point = MaskPoint(x: 0.23, y: 0.71)
        for turns in -1...4 {
            for angle in [-20.0, -7.5, 0, 12, 20] {
                let edits = EditSettings(
                    rotationQuarterTurns: turns,
                    straightenDegrees: angle,
                    cropRect: .init(x: 0.11, y: 0.17, width: 0.71, height: 0.62)
                )
                let geometry = PhotoGeometry(sourceWidth: 4032, sourceHeight: 3024, edits: edits)
                let display = geometry.displayPoint(fromSource: point)
                let result = geometry.sourcePoint(fromDisplay: display)
                XCTAssertEqual(result.x, point.x, accuracy: 0.000_000_1)
                XCTAssertEqual(result.y, point.y, accuracy: 0.000_000_1)
                XCTAssertGreaterThan(geometry.outputSize.width, 0)
                XCTAssertGreaterThan(geometry.outputSize.height, 0)
            }
        }
    }

    func testGeometrySanitizesDimensionsAndAngleAndDefinesCICoordinates() {
        let invalid = PhotoGeometry(
            sourceWidth: .nan,
            sourceHeight: -2,
            edits: EditSettings(straightenDegrees: .nan)
        )
        XCTAssertEqual(invalid.canvasSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(invalid.outputSize, CGSize(width: 1, height: 1))

        let geometry = PhotoGeometry(
            sourceWidth: 80,
            sourceHeight: 60,
            edits: EditSettings(rotationQuarterTurns: 3, straightenDegrees: 50,
                                cropRect: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6))
        )
        let sourceTopLeft = CGPoint(x: 13, y: 21)
        let canvasTopLeft = sourceTopLeft.applying(geometry.sourceToCanvas)
        let ciSource = CGPoint(x: sourceTopLeft.x, y: 60 - sourceTopLeft.y)
        let ciCanvas = ciSource.applying(geometry.ciTransform)
        XCTAssertEqual(ciCanvas.x, canvasTopLeft.x, accuracy: 0.000_001)
        XCTAssertEqual(ciCanvas.y, geometry.canvasSize.height - canvasTopLeft.y, accuracy: 0.000_001)
        XCTAssertEqual(geometry.ciCropBounds.minY,
                       geometry.canvasSize.height - geometry.cropBounds.maxY,
                       accuracy: 0.000_001)
    }

    func testSelectiveBatchIncludesAdvancedComponents() {
        let source = EditSettings(
            curves: ToneCurves(master: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.7), .init(x: 1, y: 1)]),
            colorRanges: [.init(band: .blue, saturation: 0.4)],
            grain: .init(amount: 0.2, size: 3, seed: 8),
            straightenDegrees: 6,
            cropRect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.7),
            retouchStrokes: [.init(points: [.init(x: 0.2, y: 0.3)])]
        )
        let target = EditSettings(exposure: -1, cropAspect: 1.5)

        let global = target.merging(from: source, components: .global)
        XCTAssertEqual(global.curves, source.curves)
        XCTAssertEqual(global.colorRanges, source.colorRanges)
        XCTAssertEqual(global.grain, source.grain)
        XCTAssertEqual(global.cropAspect, target.cropAspect)
        XCTAssertEqual(global.retouchStrokes, target.retouchStrokes)

        let geometry = target.merging(from: source, components: .geometry)
        XCTAssertEqual(geometry.straightenDegrees, source.straightenDegrees)
        XCTAssertEqual(geometry.cropRect, source.cropRect)
        XCTAssertEqual(geometry.curves, target.curves)

        let retouch = target.merging(from: source, components: .retouch)
        XCTAssertEqual(retouch.retouchStrokes, source.retouchStrokes)
        XCTAssertEqual(retouch.curves, target.curves)
        XCTAssertEqual(target.merging(from: source, components: .all), source)
    }
}
