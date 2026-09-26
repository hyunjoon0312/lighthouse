import Foundation
import XCTest
@testable import LighthouseCore

final class EditSnapshotTests: XCTestCase {
    func testChangeSummaryNamesChangedItems() {
        let before = EditSettings.neutral
        XCTAssertEqual(EditSettings(exposure: 0.5).changeSummary(from: before), "노출")
        var many = EditSettings(exposure: 0.5, contrast: 1.1)
        many.curves.master = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]
        many.lut = LUTAdjustment(id: "a", name: "필름")
        XCTAssertEqual(many.changeSummary(from: before), "노출·대비 외 2")
        XCTAssertEqual(EditSettings.neutral.changeSummary(from: many), "보정 초기화")
        XCTAssertEqual(many.changeSummary(from: many), "변경 없음")
    }

    func testHistoryListsOnlyThisPhotosUndoableChanges() {
        let photo = UUID(), other = UUID()
        var history = EditHistory()
        history.record([PhotoEditChange(id: photo, before: .neutral, after: EditSettings(exposure: 1))])
        history.record([PhotoEditChange(id: other, before: .neutral, after: EditSettings(contrast: 1.2)),
                        PhotoEditChange(id: photo, before: EditSettings(exposure: 1), after: EditSettings(exposure: 1, saturation: 0))])
        history.recordContinuous(PhotoEditChange(id: photo, before: EditSettings(exposure: 1, saturation: 0),
                                                 after: EditSettings(exposure: 2, saturation: 0)))
        XCTAssertEqual(history.editChanges(for: photo).map(\.after.exposure), [1, 1, 2], "여러 장 단계와 드래그 중 변경 포함")
        XCTAssertEqual(history.editChanges(for: other).count, 1)
        _ = history.undo()
        XCTAssertEqual(history.editChanges(for: photo).count, 2, "되돌린 단계는 빠진다")
    }

    func testCatalogKeepsSnapshotsAndTheirMasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogStore(url: directory.appendingPathComponent("catalog.json"))
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 9, 9, 9])
        var photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(photo), as: UTF8.self).contains("snapshots"))
        var masked = EditSettings(exposure: 0.3)
        masked.localAdjustments = [LocalAdjustment(exposure: 1, baseMask: RasterMask(width: 2, height: 2, pngData: png))]
        photo.snapshots = [EditSnapshot(name: "하늘 밝게", createdAt: Date(timeIntervalSince1970: 1_800_000_000), edits: masked)]
        try store.save([photo])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.maskDirectory.path),
                       [MaskFileStore.contentID(png) + ".png"], "현재 보정에 없는 스냅숏의 마스크도 남긴다")
        XCTAssertEqual(try store.load(), [photo])
    }
}
