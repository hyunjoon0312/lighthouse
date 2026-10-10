import AppKit
import CryptoKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import SwiftUI
import XCTest

@MainActor
final class ColorGradingFlowTests: XCTestCase {
    private var snapshotWindows: [NSWindow] = []

    func testWheelGeometryMapsAnglesAndClampsDistance() {
        func check(_ point: CGPoint, hue: Double, saturation: Double, line: UInt = #line) {
            let value = ColorWheelGeometry.value(at: point, size: 160)
            XCTAssertEqual(value.hue, hue, accuracy: 1e-9, line: line)
            XCTAssertEqual(value.saturation, saturation, accuracy: 1e-9, line: line)
        }
        check(CGPoint(x: 160, y: 80), hue: 0, saturation: 1)
        check(CGPoint(x: 80, y: 0), hue: 90, saturation: 1)
        check(CGPoint(x: 0, y: 80), hue: 180, saturation: 1)
        check(CGPoint(x: 80, y: 160), hue: 270, saturation: 1)
        check(CGPoint(x: 80, y: 80), hue: 0, saturation: 0)
        check(CGPoint(x: 240, y: 80), hue: 0, saturation: 1)
        let nearlyFull = ColorWheelGeometry.value(at: CGPoint(x: 160, y: 80 + 1e-13), size: 160)
        XCTAssertTrue((0..<360).contains(nearlyFull.hue), "계산 오차로 360이 나오지 않는다")

        let point = ColorWheelGeometry.point(hue: 220, saturation: 0.4, size: 160)
        let back = ColorWheelGeometry.value(at: point, size: 160)
        XCTAssertEqual(back.hue, 220, accuracy: 1e-9)
        XCTAssertEqual(back.saturation, 0.4, accuracy: 1e-9)
    }

    func testContinuousGradingEditIsOneUndoStepAndZoneResetRestoresDefaults() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let start = try XCTUnwrap(model.selection).edits
        for saturation in [0.1, 0.2, 0.3] {
            var next = try XCTUnwrap(model.selection).edits
            next.colorGrading.shadows = ColorGradeZone(hue: 220, saturation: saturation)
            model.updateEdits(next, continuous: true)
        }
        model.endContinuousEdit()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits.colorGrading.shadows.saturation, 0.3)
        model.undo()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits, start, "드래그 한 번은 실행 취소 1단계다")
        model.redo()

        var reset = try XCTUnwrap(model.selection).edits
        reset.colorGrading[keyPath: ColorGradeRegion.shadows.keyPath] = ColorGradeZone()
        model.updateEdits(reset)
        XCTAssertEqual(try XCTUnwrap(model.selection).edits.colorGrading, .neutral)
    }

    func testWheelDoubleTapResetIsOneUndoStepFromValueBeforeClick() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        var start = try XCTUnwrap(model.selection).edits
        start.colorGrading.shadows = ColorGradeZone(hue: 200, saturation: 0.3)
        model.updateEdits(start)
        let gesture = ColorWheelGestureState(settleDelay: .seconds(5))

        // 첫 클릭은 누른 위치의 색을 바로 보여 준다.
        var clicked = try XCTUnwrap(model.selection).edits
        clicked.colorGrading.shadows = ColorGradeZone(hue: 0, saturation: 1)
        model.updateEdits(clicked, continuous: true)
        gesture.dragEnded(moved: false) { model.endContinuousEdit() }
        gesture.doubleTapped(reset: {
            var reset = model.selection!.edits
            reset.colorGrading.shadows = ColorGradeZone()
            model.updateEdits(reset, continuous: true)
        }, end: { model.endContinuousEdit() })

        XCTAssertEqual(try XCTUnwrap(model.selection).edits.colorGrading.shadows, ColorGradeZone())
        model.undo()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits, start, "초기화 뒤 ⌘Z 한 번이면 클릭 전 값으로 돌아간다")
    }

    func testWheelDragEndsImmediatelyWhenMovedAndAfterDelayWhenStationary() async throws {
        let gesture = ColorWheelGestureState(settleDelay: .milliseconds(20))
        var ended = 0
        gesture.dragEnded(moved: true) { ended += 1 }
        XCTAssertEqual(ended, 1, "끌어서 놓으면 바로 한 단계로 묶는다")
        gesture.dragEnded(moved: false) { ended += 1 }
        XCTAssertEqual(ended, 1, "제자리 클릭은 두 번 누르기를 잠시 기다린다")
        try await TestSupport.wait("stationary click settles") { ended == 2 }
    }

    func testColorGradingPresetAppliesToSelectionAsOneStepAndReloads() async throws {
        let (model, root, urls) = try await TestSupport.startedModel(self, photos: 2)
        let originalHashes = try urls.map(Self.sha256)
        let input = root.appendingPathComponent("grading-presets", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let xmp = input.appendingPathComponent("grade.xmp")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            <rdf:Description crs:Name="Teal Orange" crs:SplitToningShadowHue="200"
              crs:SplitToningShadowSaturation="35" crs:SplitToningHighlightHue="35"
              crs:SplitToningHighlightSaturation="30" crs:SplitToningBalance="10"/>
          </rdf:RDF>
        </x:xmpmeta>
        """.utf8).write(to: xmp)

        model.importLightroomPresets(from: [xmp])
        try await TestSupport.wait("color grading preset import") { !model.isPresetImporting }
        let preset = try XCTUnwrap(model.presets.first { $0.name == "Teal Orange" })

        model.selectAllVisible()
        let starting = EditSettings(exposure: 0.4, colorGrading: ColorGrading(
            midtones: ColorGradeZone(hue: 90, saturation: 0.2), blending: 0.8
        ))
        for photo in model.photos { model.updatePhoto(photo.id) { $0.edits = starting } }
        model.applyPreset(preset)
        XCTAssertTrue(model.photos.allSatisfy {
            $0.edits.colorGrading.shadows == ColorGradeZone(hue: 200, saturation: 0.35) &&
            $0.edits.colorGrading.highlights == ColorGradeZone(hue: 35, saturation: 0.3) &&
            $0.edits.colorGrading.balance == 0.1 &&
            $0.edits.colorGrading.midtones == starting.colorGrading.midtones &&
            $0.edits.colorGrading.blending == 0.8 && $0.edits.exposure == 0.4
        }, "프리셋에 없는 영역·혼합은 유지한다")
        model.undo()
        XCTAssertTrue(model.photos.allSatisfy { $0.edits == starting }, "다중 적용을 한 번에 실행 취소한다")
        model.redo()

        try model.flushSave()
        let reloaded = LibraryModel()
        reloaded.start()
        try await TestSupport.wait("color grading catalog reload") { reloaded.catalogLoaded && reloaded.foldersLoaded }
        XCTAssertEqual(reloaded.photos.map(\.edits), model.photos.map(\.edits))
        XCTAssertEqual(reloaded.presets, model.presets)
        XCTAssertEqual(try urls.map(Self.sha256), originalHashes, "원본 bytes를 바꾸지 않는다")
    }

    func testRenderColorGradingControlsWhenSnapshotDirectoryIsProvided() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LIGHTHOUSE_SNAPSHOT_DIR"] else {
            throw XCTSkip("LIGHTHOUSE_SNAPSHOT_DIR를 주면 컬러 그레이딩 화면을 PNG로 그린다.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        var edits = try XCTUnwrap(model.selection).edits
        edits.colorGrading = ColorGrading(shadows: ColorGradeZone(hue: 200, saturation: 0.35, luminance: -0.1),
                                          highlights: ColorGradeZone(hue: 35, saturation: 0.3),
                                          blending: 0.6, balance: 0.1)
        model.updateEdits(edits)
        try await renderSnapshot(ColorGradingControls(edits: edits)
            .padding(12)
            .background(Palette.panel), model: model,
                                 size: CGSize(width: 300, height: 520), name: "color-grading-300", directory: directory)
        try await renderSnapshot(InspectorView(photo: try XCTUnwrap(model.selection)), model: model,
                                 size: CGSize(width: 300, height: 2600), name: "color-grading-inspector-300",
                                 directory: directory)
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func renderSnapshot<V: View>(_ view: V, model: LibraryModel, size: CGSize,
                                         name: String, directory: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AnyView(view.environmentObject(model).preferredColorScheme(.dark)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        snapshotWindows.append(window)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
}
