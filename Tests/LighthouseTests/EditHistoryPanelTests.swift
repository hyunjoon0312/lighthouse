import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 보정 기록으로 돌아가기와 스냅숏.
@MainActor
final class EditHistoryPanelTests: XCTestCase {
    func testTimelineRestoreAndSnapshotsPersist() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let photo = model.photos[0]
        model.focusPhoto(photo)
        XCTAssertTrue(model.editTimeline.isEmpty)
        var edits = photo.edits
        edits.exposure = 0.5
        model.updateEdits(edits)
        edits.contrast = 1.2
        model.updateEdits(edits, continuous: true)
        edits.contrast = 1.3
        model.updateEdits(edits, continuous: true)
        XCTAssertEqual(model.editTimeline.map(\.title), ["처음 상태", "노출", "대비"], "드래그는 한 줄")

        model.endContinuousEdit()
        model.restoreEdits(model.editTimeline[1].edits)
        XCTAssertEqual(model.selection?.edits.exposure, 0.5)
        XCTAssertEqual(model.selection?.edits.contrast, 1)
        XCTAssertEqual(model.editTimeline.last?.title, "대비", "돌아간 것도 새 단계로 남는다")
        model.undo()
        XCTAssertEqual(model.selection?.edits.contrast, 1.3, "⌘Z로 돌아가기 전으로")

        model.saveSnapshot(name: "  밝게  ")
        model.saveSnapshot(name: "")
        XCTAssertEqual(model.selection?.snapshots.map(\.name), ["밝게", "스냅숏 2"])
        model.updateEdits(.neutral)
        let snapshot = try XCTUnwrap(model.selection?.snapshots.first)
        model.restoreEdits(snapshot.edits)
        XCTAssertEqual(model.selection?.edits, snapshot.edits)
        model.deleteSnapshot(snapshot.id)
        XCTAssertEqual(model.selection?.snapshots.map(\.name), ["스냅숏 2"])

        try model.flushSave()
        let restarted = LibraryModel()
        restarted.start()
        try await TestSupport.wait("restart") { restarted.catalogLoaded }
        XCTAssertEqual(restarted.photo(withID: photo.id)?.snapshots.map(\.name), ["스냅숏 2"])
        XCTAssertTrue(restarted.editTimeline.isEmpty, "보정 기록은 이번 실행에만 남는다")
    }
}
