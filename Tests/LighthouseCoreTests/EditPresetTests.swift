import Foundation
import XCTest
@testable import LighthouseCore

final class EditPresetTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("presets.json")
    }

    func testPresetKeepsOnlyChosenComponentsAndApplies() {
        var source = EditSettings(exposure: 0.7, vibrance: 0.3)
        source.lut = LUTAdjustment(id: String(repeating: "a", count: 64), name: "Film", intensity: 0.6)
        source.cropRect = NormalizedCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        source.localAdjustments = [LocalAdjustment(exposure: 1)]
        source.retouchStrokes = [RetouchStroke(points: [MaskPoint(x: 0.5, y: 0.5)])]
        let preset = EditPreset(name: "따뜻한 저녁", source: source, components: [.global, .lut, .local, .retouch])
        XCTAssertEqual(preset.components, [.global, .lut])
        XCTAssertEqual(preset.settings.exposure, 0.7)
        XCTAssertEqual(preset.settings.lut, source.lut)
        XCTAssertNil(preset.settings.cropRect)
        XCTAssertTrue(preset.settings.localAdjustments.isEmpty && preset.settings.retouchStrokes.isEmpty)

        var target = EditSettings(contrast: 1.2)
        target.cropRect = NormalizedCrop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let applied = preset.applied(to: target, isRAW: false)
        XCTAssertEqual(applied.exposure, 0.7)
        XCTAssertEqual(applied.contrast, 1)
        XCTAssertEqual(applied.vibrance, 0.3)
        XCTAssertEqual(applied.cropRect, target.cropRect)
        XCTAssertEqual(applied.lut, source.lut)
    }

    func testStoreRoundTripValidationAndCorruptionProtection() throws {
        let store = EditPresetStore(url: try temporaryURL())
        XCTAssertEqual(try store.load(), [])
        let first = EditPreset(name: "  맑은 하늘 ", source: EditSettings(exposure: 0.3), components: .global)
        let second = EditPreset(name: "Film", source: EditSettings(clarity: 0.4), components: [.global, .geometry])
        try store.save([first, second])
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.name), ["맑은 하늘", "Film"])
        XCTAssertEqual(loaded[1].components, [.global, .geometry])
        XCTAssertEqual(loaded[0].settings, first.settings)

        var duplicate = second
        duplicate.id = UUID()
        duplicate.name = "film"
        XCTAssertThrowsError(try store.save([first, second, duplicate]))
        XCTAssertThrowsError(try store.save([EditPreset(name: "  ", source: .neutral, components: .global)]))
        XCTAssertThrowsError(try store.save([EditPreset(name: "Local", source: .neutral, components: .local)]))

        try Data(#"{"version":1,"presets":[{"id":"\#(UUID().uuidString)","name":"X","components":8,"settings":\#(String(data: JSONEncoder().encode(EditSettings()), encoding: .utf8)!)}]}"#.utf8).write(to: store.url)
        let corrupt = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        try Data(#"{"version":2,"presets":[]}"#.utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }
}
