import Foundation
import XCTest
@testable import LighthouseCore

final class WorkflowEditModelTests: XCTestCase {
    func testSettingsDefaultsAndNeutralEncoding() throws {
        let flicker = try JSONDecoder().decode(FlickerSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(flicker, FlickerSettings())
        let range = try JSONDecoder().decode(RangeSelection.self, from: Data("{}".utf8))
        XCTAssertEqual(range, RangeSelection())

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditSettings())) as! [String: Any]
        XCTAssertNil(encoded["flicker"])
        let local = LocalAdjustment()
        let localJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as! [String: Any]
        XCTAssertNil(localJSON["automaticMaskKind"])
        XCTAssertNil(localJSON["rangeSelection"])
        XCTAssertNil(localJSON["noiseReduction"])
    }

    func testExplicitNullWrongTypeAndInvalidValuesReject() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(FlickerSettings.self, from: Data(#"{"profile":null}"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(RangeSelection.self, from: Data(#"{"lower":"zero"}"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(RangeSelection.self, from: Data(#"{"lower":0.8,"upper":0.2}"#.utf8))
        )

        var dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalAdjustment())) as! [String: Any]
        dictionary["automaticMaskKind"] = NSNull()
        XCTAssertThrowsError(
            try JSONDecoder().decode(LocalAdjustment.self, from: JSONSerialization.data(withJSONObject: dictionary))
        )
        dictionary.removeValue(forKey: "automaticMaskKind")
        dictionary["rangeSelection"] = NSNull()
        XCTAssertThrowsError(
            try JSONDecoder().decode(LocalAdjustment.self, from: JSONSerialization.data(withJSONObject: dictionary))
        )
    }

    func testProfileRequiresSixBoundedCoefficients() throws {
        let valid = FlickerProfile(redCoefficients: [0.1, 0, 0, 0, 0, 0],
                                   greenCoefficients: [0.1, 0, 0, 0, 0, 0],
                                   blueCoefficients: [0.1, 0, 0, 0, 0, 0], referenceAmplitudeEV: 0.1)
        XCTAssertEqual(try JSONDecoder().decode(FlickerProfile.self, from: JSONEncoder().encode(valid)), valid)
        let invalid = #"{"redCoefficients":[0],"greenCoefficients":[0,0,0,0,0,0],"blueCoefficients":[0,0,0,0,0,0],"referenceAmplitudeEV":0.1}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(FlickerProfile.self, from: Data(invalid.utf8))
        )
    }

    func testLocalProvenanceDoesNotChangeMaskDefinitionAndNoiseIsAnEffect() {
        let range = RangeSelection(kind: .color, red: 0.8, green: 0.2, blue: 0.1)
        let first = LocalAdjustment(automaticMaskKind: .subject, rangeSelection: range,
                                    noiseReduction: .init(mode: .standard, amount: 0.5))
        var second = first
        second.automaticMaskKind = .background
        second.rangeSelection = .init(lower: 0.2, upper: 0.8)
        XCTAssertEqual(first.maskDefinition, second.maskDefinition)
        XCTAssertTrue(first.hasEffect)
    }

    func testBatchAndSnapshotIncludeFlicker() {
        let source = EditSettings(flicker: FlickerSettings(isEnabled: true, amount: 0.8, cycles: 7.3))
        let merged = EditSettings().merging(from: source, components: .global)
        XCTAssertEqual(merged.flicker, source.flicker)
        XCTAssertEqual(source.changeSummary(from: .neutral), "플리커")
    }
}
