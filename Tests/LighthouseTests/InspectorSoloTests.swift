import AppKit
@testable import Lighthouse
import XCTest

/// 보정 묶음 "한 묶음만 펴기"(Lightroom의 Solo Mode): 켜 두면 보정 묶음 하나를 펼 때 다른 보정 묶음을 접는다.
@MainActor
final class InspectorSoloTests: XCTestCase {
    func testExpandingCollapsesOtherAdjustmentSectionsOnlyInSoloMode() throws {
        let suite = "InspectorSoloTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let light = "inspector.section.light", color = "inspector.section.color", marks = "inspector.section.marks"
        defaults.set(true, forKey: color)
        defaults.set(true, forKey: marks)

        InspectorSolo.expand(light, among: [light, color], defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: light))
        XCTAssertTrue(defaults.bool(forKey: color), "꺼져 있으면 다른 묶음을 그대로 둔다")

        defaults.set(true, forKey: InspectorSolo.settingKey)
        defaults.set(false, forKey: light)
        InspectorSolo.expand(light, among: [light, color], defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: light))
        XCTAssertFalse(defaults.bool(forKey: color), "켜져 있으면 다른 보정 묶음을 접는다")
        XCTAssertTrue(defaults.bool(forKey: marks), "보정 묶음이 아닌 키워드·설명 묶음은 그대로 둔다")
    }
}
