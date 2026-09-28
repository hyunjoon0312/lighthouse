import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class NoiseReductionAppTests: XCTestCase {
    func testCopyGlobalBatchUndoRedoAndResetPreserveNoiseReduction() async throws {
        let (model, _, urls) = try await TestSupport.startedModel(self, photos: 3)
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let source = model.photos[0]
        let firstTarget = model.photos[1]
        let secondTarget = model.photos[2]
        let expected = NoiseReductionSettings(mode: .standard, amount: 0.62)

        model.focusPhoto(source)
        var sourceEdits = source.edits
        sourceEdits.noiseReduction = expected
        model.updateEdits(sourceEdits)
        XCTAssertEqual(model.editTimeline.last?.title, "노이즈 감소")
        model.copyEdits()

        model.focusPhoto(try XCTUnwrap(model.photo(withID: firstTarget.id)))
        model.pasteEditsToSelection()
        XCTAssertEqual(model.photo(withID: firstTarget.id)?.edits.noiseReduction, expected)

        model.undo()
        XCTAssertEqual(model.photo(withID: firstTarget.id)?.edits.noiseReduction, NoiseReductionSettings())
        model.redo()
        XCTAssertEqual(model.photo(withID: firstTarget.id)?.edits.noiseReduction, expected)

        model.applyBatchEdits(source: sourceEdits, to: [firstTarget.id, secondTarget.id], components: .global)
        XCTAssertEqual(model.photo(withID: firstTarget.id)?.edits.noiseReduction, expected)
        XCTAssertEqual(model.photo(withID: secondTarget.id)?.edits.noiseReduction, expected)
        model.undo()
        XCTAssertEqual(model.photo(withID: secondTarget.id)?.edits.noiseReduction, NoiseReductionSettings())
        model.redo()
        XCTAssertEqual(model.photo(withID: secondTarget.id)?.edits.noiseReduction, expected)

        model.focusPhoto(try XCTUnwrap(model.photo(withID: firstTarget.id)))
        model.updateEdits(.neutral)
        XCTAssertEqual(model.selection?.edits.noiseReduction, NoiseReductionSettings())
        model.undo()
        XCTAssertEqual(model.selection?.edits.noiseReduction, expected)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes,
                       "편집은 원본 파일을 바꾸지 않는다")
    }

    func testSnapshotAndCatalogReloadPreserveNoiseReduction() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let photoID = try XCTUnwrap(model.selection?.id)
        let expected = NoiseReductionSettings(mode: .standard, amount: 0.47)
        var edits = try XCTUnwrap(model.selection?.edits)
        edits.noiseReduction = expected
        model.updateEdits(edits)
        model.saveSnapshot(name: "노이즈 감소")

        model.updateEdits(.neutral)
        let snapshot = try XCTUnwrap(model.selection?.snapshots.first)
        XCTAssertEqual(snapshot.edits.noiseReduction, expected)
        model.restoreEdits(snapshot.edits)
        XCTAssertEqual(model.selection?.edits.noiseReduction, expected)
        try model.flushSave()

        let restarted = LibraryModel()
        restarted.start()
        try await TestSupport.wait("noise reduction catalog reload") { restarted.catalogLoaded }
        let reloaded = try XCTUnwrap(restarted.photo(withID: photoID))
        XCTAssertEqual(reloaded.edits.noiseReduction, expected)
        XCTAssertEqual(reloaded.snapshots.first?.edits.noiseReduction, expected)
    }

    func testSupersededAIRenderIsRejectedAfterOffUndoAndPhotoSwitch() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let first = model.photos[0]
        let second = model.photos[1]
        model.focusPhoto(first)
        var aiEdits = first.edits
        aiEdits.noiseReduction = NoiseReductionSettings(mode: .ai, amount: 0.55)
        model.updateEdits(aiEdits)
        let firstSource = "\(first.id.uuidString):false:false"
        model.renderedSource = firstSource
        model.displayedToken = 0

        XCTAssertTrue(model.canDisplaySupersededRender(source: firstSource, token: 1, edits: aiEdits),
                      "같은 AI 설정의 순서가 늦은 결과는 기존 슬라이더 연속성을 유지한다")

        var offEdits = aiEdits
        offEdits.noiseReduction = NoiseReductionSettings()
        model.updateEdits(offEdits)
        XCTAssertFalse(model.canDisplaySupersededRender(source: firstSource, token: 1, edits: aiEdits),
                       "AI를 끈 뒤 도착한 AI 결과는 표시하지 않는다")

        model.undo()
        XCTAssertEqual(model.selection?.edits.noiseReduction, aiEdits.noiseReduction)
        XCTAssertFalse(model.canDisplaySupersededRender(source: firstSource, token: 1, edits: offEdits),
                       "undo로 AI를 복원한 뒤 도착한 끔 상태 결과는 표시하지 않는다")

        model.focusPhoto(second)
        XCTAssertFalse(model.canDisplaySupersededRender(source: firstSource, token: 1, edits: aiEdits),
                       "사진을 바꾼 뒤 도착한 이전 사진 결과는 표시하지 않는다")
    }
}
