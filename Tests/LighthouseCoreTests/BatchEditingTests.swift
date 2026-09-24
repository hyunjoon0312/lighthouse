import Foundation
import XCTest
@testable import LighthouseCore

final class BatchEditingTests: XCTestCase {
    func testSelectionModesAndFocus() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = PhotoSelectionState()
        selection.select(ids[1], in: ids)
        XCTAssertEqual(selection.selectedIDs, [ids[1]])
        XCTAssertEqual(selection.activeID, ids[1])
        XCTAssertEqual(selection.anchorID, ids[1])

        selection.select(ids[3], in: ids, mode: .toggle)
        XCTAssertEqual(selection.selectedIDs, [ids[1], ids[3]])
        XCTAssertEqual(selection.activeID, ids[3])
        selection.select(ids[4], in: ids, mode: .range)
        XCTAssertEqual(selection.selectedIDs, [ids[3], ids[4]])
        XCTAssertEqual(selection.activeID, ids[4])
        XCTAssertEqual(selection.anchorID, ids[3])

        selection.focus(ids[3], in: ids)
        XCTAssertEqual(selection.selectedIDs, [ids[3], ids[4]])
        XCTAssertEqual(selection.activeID, ids[3])
        XCTAssertEqual(selection.anchorID, ids[3])
        selection.focus(ids[0], in: ids)
        XCTAssertEqual(selection.selectedIDs, [ids[0]])
        XCTAssertEqual(selection.activeID, ids[0])
        XCTAssertEqual(selection.anchorID, ids[0])

        selection.select(ids[0], in: ids, mode: .toggle)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.activeID)
        XCTAssertNil(selection.anchorID)
    }

    func testSelectionReconcileAllAndHiddenInput() {
        let ids = (0..<4).map { _ in UUID() }
        var selection = PhotoSelectionState()
        selection.select(ids[2], in: ids, mode: .range)
        XCTAssertEqual(selection.selectedIDs, [ids[2]])
        selection.selectAll(in: ids)
        XCTAssertEqual(selection.selectedIDs, Set(ids))
        XCTAssertEqual(selection.activeID, ids[2])
        XCTAssertEqual(selection.anchorID, ids[2])

        selection.select(ids[1], in: ids, mode: .toggle)
        selection.select(ids[2], in: ids, mode: .toggle)
        XCTAssertEqual(selection.activeID, ids[0])
        XCTAssertEqual(selection.anchorID, ids[0])
        selection.select(ids[3], in: [ids[0]], mode: .single)
        XCTAssertEqual(selection.selectedIDs, [ids[0], ids[3]])

        selection.reconcile(with: [ids[3], ids[1]])
        XCTAssertEqual(selection.selectedIDs, [ids[3]])
        XCTAssertEqual(selection.activeID, ids[3])
        XCTAssertEqual(selection.anchorID, ids[3])
        selection.reconcile(with: [])
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.activeID)
        XCTAssertNil(selection.anchorID)
        selection.reconcile(with: ids)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.reconcile(with: ids, selectFirstIfEmpty: true)
        XCTAssertEqual(selection.selectedIDs, [ids[0]])
        selection.clear()
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.activeID)
        XCTAssertNil(selection.anchorID)
    }

    func testMergingCopiesOnlyRequestedComponents() {
        let sourceLocal = LocalAdjustment(name: "source", exposure: 1,
                                          strokes: [MaskStroke(points: [MaskPoint(x: 0.2, y: 0.3)], radius: 0.1)])
        let targetLocal = LocalAdjustment(name: "target", exposure: -1)
        let source = EditSettings(exposure: 2, contrast: 1.2, saturation: 1.3,
                                  temperatureShift: 4, tintShift: 5, highlights: 0.7,
                                  shadows: 0.6, sharpness: 0.5, rotationQuarterTurns: 1,
                                  cropAspect: 1, localAdjustments: [sourceLocal],
                                  lut: LUTAdjustment(id: "source", name: "Film", intensity: 0.4,
                                                     isEnabled: false))
        let target = EditSettings(exposure: -2, contrast: 0.8, saturation: 0.7,
                                  temperatureShift: -4, tintShift: -5, highlights: 0.3,
                                  shadows: -0.6, sharpness: 0.1, rotationQuarterTurns: 3,
                                  cropAspect: 1.5, localAdjustments: [targetLocal],
                                  lut: LUTAdjustment(id: "target", name: "Old"))
        XCTAssertEqual(target.merging(from: source, components: []), target)
        let lutOnly = target.merging(from: source, components: .lut)
        XCTAssertEqual(lutOnly.lut, source.lut)
        var expected = target
        expected.lut = source.lut
        XCTAssertEqual(lutOnly, expected)

        expected = source
        expected.lut = target.lut
        XCTAssertEqual(target.merging(from: source, components: [.global, .geometry, .local]), expected)
        XCTAssertEqual(target.merging(from: source, components: .all), source)

        var noLUT = source
        noLUT.lut = nil
        expected = target
        expected.lut = nil
        XCTAssertEqual(target.merging(from: noLUT, components: .lut), expected)
    }

    func testHistoryGroupsChangesAndPreservesRedoForNoOp() {
        let first = UUID(), second = UUID()
        let before = EditSettings()
        let after = EditSettings(exposure: 1)
        let changes = [PhotoEditChange(id: first, before: before, after: after),
                       PhotoEditChange(id: second, before: after, after: before)]
        let noOp = PhotoEditChange(id: UUID(), before: before, after: before)
        var history = EditHistory()
        history.record([noOp] + changes)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo(), changes)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
        history.record([noOp])
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo(), changes)
        XCTAssertEqual(history.undo(), changes)
        history.record([PhotoEditChange(id: first, before: after, after: .neutral)])
        XCTAssertFalse(history.canRedo)
    }

    func testContinuousChangesBecomeOneUndoStep() {
        let photo = UUID(), other = UUID()
        let steps = (0...20).map { EditSettings(exposure: Double($0) / 10) }
        var history = EditHistory()
        for index in 1..<steps.count {
            history.recordContinuous(PhotoEditChange(id: photo, before: steps[index - 1], after: steps[index]))
        }
        XCTAssertTrue(history.canUndo)
        history.commitContinuous()
        XCTAssertEqual(history.undo(), [PhotoEditChange(id: photo, before: steps[0], after: steps[20])])
        XCTAssertNil(history.undo())

        history.recordContinuous(PhotoEditChange(id: photo, before: .neutral, after: steps[1]))
        XCTAssertFalse(history.canRedo)
        history.recordContinuous(PhotoEditChange(id: other, before: .neutral, after: steps[2]))
        history.record([PhotoEditChange(id: photo, before: steps[1], after: steps[3])])
        XCTAssertEqual(history.undo(), [PhotoEditChange(id: photo, before: steps[1], after: steps[3])])
        XCTAssertEqual(history.undo(), [PhotoEditChange(id: other, before: .neutral, after: steps[2])])
        XCTAssertEqual(history.undo(), [PhotoEditChange(id: photo, before: .neutral, after: steps[1])])

        var returned = EditHistory()
        returned.record([PhotoEditChange(id: photo, before: .neutral, after: steps[1])])
        _ = returned.undo()
        returned.recordContinuous(PhotoEditChange(id: photo, before: .neutral, after: steps[2]))
        returned.recordContinuous(PhotoEditChange(id: photo, before: steps[2], after: .neutral))
        XCTAssertTrue(returned.canRedo)
        XCTAssertEqual(returned.redo(), [PhotoEditChange(id: photo, before: .neutral, after: steps[1])])
    }

    func testHistoryLimit() {
        let id = UUID()
        let a = EditSettings(exposure: 1)
        let b = EditSettings(exposure: 2)
        let c = EditSettings(exposure: 3)
        let first = PhotoEditChange(id: id, before: .neutral, after: a)
        let second = PhotoEditChange(id: id, before: a, after: b)
        let third = PhotoEditChange(id: id, before: b, after: c)
        var history = EditHistory(limit: 2)
        history.record([first])
        history.record([second])
        history.record([third])
        XCTAssertEqual(history.undo(), [third])
        XCTAssertEqual(history.undo(), [second])
        XCTAssertNil(history.undo())
        XCTAssertEqual(history.redo(), [second])
        XCTAssertEqual(history.redo(), [third])
        XCTAssertNil(history.redo())
    }
}
