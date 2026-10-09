import AppKit
import CryptoKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import SwiftUI
import XCTest

@MainActor
final class LightroomPresetFlowTests: XCTestCase {
    private var snapshotWindows: [NSWindow] = []
    func testPartialImportResolvesNamesReloadsWithoutAutoApplyAndAppliesVisibleSelectionAsOneUndoStep() async throws {
        let (model, root, urls) = try await TestSupport.startedModel(self, photos: 3)
        let originalHashes = try urls.map(Self.sha256)
        let native = EditPreset(name: "Warm Film", source: EditSettings(contrast: 1.2), components: .global)
        XCTAssertNil(model.writePresets([native], message: nil))

        let input = root.appendingPathComponent("preset-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let first = input.appendingPathComponent("first.lrtemplate")
        let second = input.appendingPathComponent("second.lrtemplate")
        let bad = input.appendingPathComponent("broken.lrtemplate")
        try Self.template(name: "Warm Film", exposure: 1).write(to: first)
        try Self.template(name: "Warm Film", exposure: -1).write(to: second)
        try Data("s = function() return {} end".utf8).write(to: bad)

        let editsBeforeImport = model.photos.map(\.edits)
        model.importLightroomPresets(from: [first, bad, second])
        try await TestSupport.wait("Lightroom preset import") { !model.isPresetImporting }

        XCTAssertEqual(model.presets.map(\.name), ["Warm Film", "Warm Film (2)", "Warm Film (3)"])
        XCTAssertEqual(model.photos.map(\.edits), editsBeforeImport, "가져온 프리셋은 사진에 자동 적용하지 않는다")
        guard case .importResult(let result)? = model.lightroomPresetSheet?.content else {
            return XCTFail("가져오기 결과 시트가 열려야 한다")
        }
        XCTAssertEqual(result.imported.map(\.name), ["Warm Film (2)", "Warm Film (3)"])
        XCTAssertEqual(result.failures.map(\.filename), ["broken.lrtemplate"])
        XCTAssertEqual(try model.presetStore.load(), model.presets, "저장된 목록을 그대로 다시 읽는다")

        model.selectAllVisible()
        model.photos[0].flag = .pick
        model.criteria.flag = .pick
        let preset = try XCTUnwrap(model.presets.first { $0.name == "Warm Film (2)" })
        let before = model.photos.map(\.edits)
        model.applyPreset(preset)
        XCTAssertEqual(model.photos[0].edits.exposure, 1)
        XCTAssertEqual(model.photos[0].edits.contrast, before[0].contrast, "명시하지 않은 값은 보존한다")
        XCTAssertEqual(model.photos[1].edits, before[1], "필터로 가려진 선택은 제외한다")
        XCTAssertEqual(model.photos[2].edits, before[2], "필터로 가려진 선택은 제외한다")
        model.undo()
        XCTAssertEqual(model.photos.map(\.edits), before)
        model.redo()
        XCTAssertEqual(model.photos[0].edits.exposure, 1)
        XCTAssertEqual(try urls.map(Self.sha256), originalHashes, "프리셋 가져오기와 적용은 원본 bytes를 바꾸지 않는다")
    }

    func testCancelInvalidatesLateResultsAndConflictGateTracksImport() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let input = root.appendingPathComponent("cancel-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let urls = try (0..<80).map { index -> URL in
            let url = input.appendingPathComponent("preset-\(index).lrtemplate")
            try Self.template(name: "Preset \(index)", exposure: 0.5).write(to: url)
            return url
        }

        model.importLightroomPresets(from: urls)
        XCTAssertTrue(model.isPresetImporting)
        XCTAssertTrue(model.hasConflictingWorkflow)
        let activeGeneration = model.presetImportGeneration
        model.importLightroomPresets(from: urls)
        XCTAssertEqual(model.presetImportGeneration, activeGeneration, "진행 중인 중복 요청을 시작하지 않는다")
        model.cancelPresetImport()
        XCTAssertFalse(model.isPresetImporting)
        XCTAssertFalse(model.hasConflictingWorkflow)

        let replacement = root.appendingPathComponent("replacement.lrtemplate")
        try Self.template(name: "Replacement", exposure: -0.5).write(to: replacement)
        model.importLightroomPresets(from: [replacement])
        let concurrent = EditPreset(name: "Saved While Importing", source: EditSettings(contrast: 1.1), components: .global)
        XCTAssertNil(model.writePresets([concurrent], message: nil))
        try await TestSupport.wait("replacement preset import") { !model.isPresetImporting }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(Set(model.presets.map(\.name)), ["Replacement", "Saved While Importing"],
                       "새 작업은 완료 시점의 최신 목록에 합치고 취소한 이전 결과는 버린다")
        guard case .importResult(let result)? = model.lightroomPresetSheet?.content else {
            return XCTFail("새 가져오기 결과만 표시해야 한다")
        }
        XCTAssertEqual(result.imported.map(\.name), ["Replacement"])
    }

    func testImportPresetAppliesToNewPhotoAndQuickFlagCriteriaAutoAdvanceDoesNotSkip() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 4)
        let preset = EditPreset(name: "On Import", lightroom: LightroomPresetPayload(
            format: "xmp", scalars: ["Exposure2012": 0.75], curves: [:], warnings: ["엔진 차이"]
        ))
        XCTAssertNil(model.writePresets([preset], message: nil))
        model.importPresetID = preset.id
        let incoming = root.appendingPathComponent("incoming.jpg")
        try TestSupport.writeJPEG(incoming, color: (80, 100, 140))
        model.importURLs([incoming])
        try await TestSupport.wait("photo import with preset") { !model.isImporting && model.photos.count == 5 }
        XCTAssertEqual(model.photos.first { $0.path == incoming.resolvingSymlinksInPath().path }?.edits.exposure, 0.75)

        for index in model.photos.indices {
            model.photos[index].rating = 3
            model.photos[index].flag = PhotoFlag.none
        }
        model.search = "photo-0"
        model.minimumRating = 3
        model.criteria.flag = PhotoFlag.none
        let before = model.visiblePhotos
        XCTAssertEqual(before.count, 4, "검색·별점·빠른 표시 조건을 함께 적용한다")
        model.setMode(.edit)
        model.focusPhoto(before[0])
        model.autoAdvance = true
        model.markFromKeyboard(flag: .pick)
        XCTAssertEqual(model.selectedID, before[1].id, "미분류 목록에서 P 뒤 바로 다음 사진을 건너뛰지 않는다")
        XCTAssertEqual(model.visiblePhotos.count, 3)
        model.criteria.flag = nil
        XCTAssertEqual(model.visiblePhotos.count, 4, "전체 표시는 표시 조건만 지우고 검색·별점 조건은 유지한다")
    }

    func testSaveFailureKeepsMemoryAndReportsNoImportedPresets() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let existing = EditPreset(name: "Existing", source: EditSettings(exposure: 0.2), components: .global)
        XCTAssertNil(model.writePresets([existing], message: nil))
        try FileManager.default.removeItem(at: model.presetStore.url)
        try FileManager.default.createDirectory(at: model.presetStore.url, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("new.lrtemplate")
        try Self.template(name: "New", exposure: 1).write(to: source)

        model.importLightroomPresets(from: [source])
        try await TestSupport.wait("failed preset save") { !model.isPresetImporting }

        XCTAssertEqual(model.presets, [existing])
        guard case .importResult(let result)? = model.lightroomPresetSheet?.content else {
            return XCTFail("저장 실패 결과 시트가 열려야 한다")
        }
        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertEqual(result.failures.map(\.filename), ["프리셋 보관함"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.presetStore.url.path), "기존 경로를 덮어쓰지 않는다")
    }

    func testExtendedToneImportsApplyAsOneStepPreserveMissingValuesAndReload() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 2)
        let input = root.appendingPathComponent("tone-presets", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let xmp = input.appendingPathComponent("tone.xmp")
        try Self.xmp(name: "Tone Complete", settings: """
        crs:Highlights2012="35" crs:Shadows2012="-25" crs:Whites2012="40"
        crs:Blacks2012="-30" crs:GrainFrequency="80" crs:CameraProfile="Default Monochrome"
        """).write(to: xmp)
        let partial = input.appendingPathComponent("partial.lrtemplate")
        try Data("""
        s = { title = "Tone Partial", type = "Develop", value = { settings = {
          Whites2012 = -10, GrainFrequency = 25,
        } } }
        """.utf8).write(to: partial)

        model.importLightroomPresets(from: [xmp, partial])
        try await TestSupport.wait("extended tone preset import") { !model.isPresetImporting }
        let complete = try XCTUnwrap(model.presets.first { $0.name == "Tone Complete" })
        let incomplete = try XCTUnwrap(model.presets.first { $0.name == "Tone Partial" })
        XCTAssertEqual(complete.lightroom?.colorProfile, .monochrome)
        XCTAssertEqual(incomplete.lightroom?.scalars["GrainFrequency"], 25)

        model.selectAllVisible()
        var starting = EditSettings(highlights: 0.8, shadows: 0.2, whites: 0.1, blacks: 0.15,
                                    colorProfile: .color,
                                    grain: GrainSettings(amount: 0.6, size: 2.5, seed: 17, roughness: 0.6))
        starting.exposure = 0.7
        for photo in model.photos { model.updatePhoto(photo.id) { $0.edits = starting } }
        model.applyPreset(incomplete)
        XCTAssertTrue(model.photos.allSatisfy {
            $0.edits.whites == -0.1 && $0.edits.grain.roughness == 0.25 &&
            $0.edits.highlights == starting.highlights && $0.edits.shadows == starting.shadows &&
            $0.edits.blacks == starting.blacks && $0.edits.colorProfile == starting.colorProfile &&
            $0.edits.grain.amount == starting.grain.amount && $0.edits.exposure == starting.exposure
        }, "프리셋에 없는 값은 선택한 사진마다 유지한다")
        model.undo()
        XCTAssertTrue(model.photos.allSatisfy { $0.edits == starting })

        model.applyPreset(complete)
        XCTAssertTrue(model.photos.allSatisfy {
            $0.edits.highlights == 1.35 && $0.edits.shadows == -0.25 &&
            $0.edits.whites == 0.4 && $0.edits.blacks == -0.3 &&
            $0.edits.colorProfile == .monochrome && $0.edits.grain.roughness == 0.8 &&
            $0.edits.grain.amount == starting.grain.amount && $0.edits.exposure == starting.exposure
        })
        model.undo()
        XCTAssertTrue(model.photos.allSatisfy { $0.edits == starting }, "다중 적용을 한 번에 실행 취소한다")
        model.redo()
        XCTAssertTrue(model.photos.allSatisfy { $0.edits.colorProfile == .monochrome && $0.edits.whites == 0.4 },
                      "다중 적용을 한 번에 다시 실행한다")

        try model.flushSave()
        let reloaded = LibraryModel()
        reloaded.start()
        try await TestSupport.wait("extended tone catalog reload") { reloaded.catalogLoaded && reloaded.foldersLoaded }
        XCTAssertEqual(reloaded.photos.map(\.edits), model.photos.map(\.edits))
        XCTAssertEqual(reloaded.presets, model.presets, "가져온 payload의 톤·입자·프로필을 presets.json에서 다시 읽는다")
    }

    func testExtendedToneDefaultsCanBeRestoredThroughEditFlow() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        var changed = try XCTUnwrap(model.selection).edits
        changed.highlights = 1.7
        changed.shadows = -0.6
        changed.whites = 0.8
        changed.blacks = -0.4
        changed.colorProfile = .monochrome
        changed.grain.roughness = 0.1
        model.updateEdits(changed)

        var reset = try XCTUnwrap(model.selection).edits
        reset.highlights = EditSettings.neutral.highlights
        reset.shadows = EditSettings.neutral.shadows
        reset.whites = EditSettings.neutral.whites
        reset.blacks = EditSettings.neutral.blacks
        reset.colorProfile = EditSettings.neutral.colorProfile
        reset.grain.roughness = GrainSettings().roughness
        model.updateEdits(reset)

        let edits = try XCTUnwrap(model.selection).edits
        XCTAssertEqual(edits.highlights, 1)
        XCTAssertEqual(edits.shadows, 0)
        XCTAssertEqual(edits.whites, 0)
        XCTAssertEqual(edits.blacks, 0)
        XCTAssertEqual(edits.colorProfile, .color)
        XCTAssertEqual(edits.grain.roughness, 0.5)
    }

    func testRenderLightroomPresetSurfacesWhenSnapshotDirectoryIsProvided() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LIGHTHOUSE_SNAPSHOT_DIR"] else {
            throw XCTSkip("LIGHTHOUSE_SNAPSHOT_DIR를 주면 Lightroom 프리셋 화면을 PNG로 그린다.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let native = EditPreset(name: "Lighthouse Neutral", source: EditSettings(contrast: 1.1), components: .global)
        let lightroom = EditPreset(name: "Warm Street Film (2)", lightroom: LightroomPresetPayload(
            format: "xmp",
            scalars: ["Exposure2012": 0.4, "Saturation": 12, "Highlights2012": 35,
                      "Shadows2012": -25, "Whites2012": 40, "Blacks2012": -30,
                      "GrainFrequency": 80],
            curves: [:],
            warnings: ["Adobe 현상 엔진과 결과가 다를 수 있습니다.", "Temperature 설정은 제외했습니다."],
            colorProfile: .monochrome
        ))
        XCTAssertNil(model.writePresets([native, lightroom], message: nil))
        var toneEdits = try XCTUnwrap(model.selection).edits
        toneEdits.highlights = 1.35
        toneEdits.shadows = -0.25
        toneEdits.whites = 0.4
        toneEdits.blacks = -0.3
        toneEdits.colorProfile = .monochrome
        toneEdits.grain = GrainSettings(amount: 0.6, size: 3.2, seed: 71, roughness: 0.8)
        model.updateEdits(toneEdits)
        try await renderSnapshot(InspectorView(photo: try XCTUnwrap(model.selection)), model: model,
                                 size: CGSize(width: 300, height: 2100), name: "tone-inspector-300", directory: directory)
        try await renderSnapshot(AdvancedColorControls(edits: toneEdits)
            .padding(12)
            .background(Color(red: 0.145, green: 0.152, blue: 0.164)), model: model,
                                 size: CGSize(width: 300, height: 900), name: "tone-advanced-color-grain-300",
                                 directory: directory)

        let summary = LightroomPresetImportSummary(
            imported: [lightroom],
            failures: [LightroomPresetImportFailure(filename: "unsupported.xmp", message: "지원하는 보정값이 없습니다.")]
        )
        try await renderSnapshot(
            LightroomPresetImportSheet(request: LightroomPresetSheetRequest(content: .importResult(summary))),
            model: model, size: CGSize(width: 540, height: 620), name: "lightroom-import-result", directory: directory
        )
        try await renderSnapshot(
            LightroomPresetImportSheet(request: LightroomPresetSheetRequest(content: .compatibility(lightroom))),
            model: model, size: CGSize(width: 540, height: 520), name: "tone-compatibility", directory: directory
        )
    }

    private static func template(name: String, exposure: Double) -> Data {
        Data("""
        s = {
          title = "\(name)",
          type = "Develop",
          value = { settings = { Exposure2012 = \(exposure) } },
        }
        """.utf8)
    }

    private static func xmp(name: String, settings: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            <rdf:Description crs:Name="\(name)" \(settings)/>
          </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
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
