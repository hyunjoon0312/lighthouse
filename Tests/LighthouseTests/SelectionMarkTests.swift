import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 그리드에서 여러 장을 골랐을 때 별점·표시·라벨이 고른 사진 모두에 붙는지.
@MainActor
final class SelectionMarkTests: XCTestCase {
    func testGridMarksEverySelectedPhotoAsOneStep() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 4)
        let photos = model.visiblePhotos
        model.autoAdvance = true
        model.select(photos[0])
        model.handleTileClick(photos[1], clickCount: 1, modifiers: .command)
        model.handleTileClick(photos[2], clickCount: 1, modifiers: .command)
        let active = model.selectedID
        model.markFromKeyboard(rating: 3)
        XCTAssertEqual(model.visiblePhotos.map(\.rating), [3, 3, 3, 0])
        XCTAssertEqual(model.selectedID, active, "여러 장에 붙일 때는 다음 사진으로 넘어가지 않는다")
        XCTAssertEqual(model.selectedPhotoIDs.count, 3, "선택은 그대로")
        model.undo()
        XCTAssertEqual(model.visiblePhotos.map(\.rating), [0, 0, 0, 0], "한 번에 실행 취소된다")

        model.select(photos[1])
        model.setColorLabel(.red)
        XCTAssertEqual(model.visiblePhotos.map(\.colorLabel), [nil, .red, nil, nil], "한 장만 고르면 그 사진에만")
        model.select(photos[0])
        model.handleTileClick(photos[1], clickCount: 1, modifiers: .command)
        model.handleTileClick(photos[2], clickCount: 1, modifiers: .command)
        XCTAssertEqual(model.selectedPhotoIDs, Set(photos[0...2].map(\.id)))
        model.markFromKeyboard(toggleLabel: .red)
        XCTAssertEqual(model.visiblePhotos.map(\.colorLabel), [.red, .red, .red, nil], "일부만 빨강이면 모두 빨강")
        model.markFromKeyboard(toggleLabel: .red)
        XCTAssertEqual(model.visiblePhotos.map(\.colorLabel), [nil, nil, nil, nil], "모두 빨강이면 모두 뗀다")
        model.setFlag(.pick)
        XCTAssertEqual(model.visiblePhotos.map(\.flag), [.pick, .pick, .pick, PhotoFlag.none], "패널의 선택 단추도 모두에")

        model.setMode(.edit)
        model.markFromKeyboard(rating: 5)
        XCTAssertEqual(model.visiblePhotos.filter { $0.rating == 5 }.count, 1, "사진 보기에서는 보고 있는 한 장에만")
    }

    /// 사진 보기에서 목록을 바꿔 보던 사진이 빠지면 첫 사진을 보여 준다. 그리드에서는 선택을 비운다.
    func testSingleImageViewKeepsAPhotoWhenTheListChanges() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let photos = model.visiblePhotos
        model.select(photos[1])
        model.setFlag(.pick)
        model.select(photos[2])
        model.setMode(.edit)
        model.filter = .picks
        model.ensureSelectionVisible()
        XCTAssertEqual(model.selectedID, photos[1].id)
        model.setMode(.grid)
        model.filter = .rejects
        model.ensureSelectionVisible()
        XCTAssertNil(model.selectedID)
        model.filter = .all
        model.clearPhotoSelection()
        model.setMode(.edit)
        XCTAssertEqual(model.selectedID, photos[0].id, "아무것도 고르지 않고 사진 보기로 가면 첫 사진")
    }

    /// ⇧+화살표로 처음 고른 사진부터 선택을 넓히고 줄인다.
    func testShiftArrowExtendsTheSelection() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 4)
        let ids = model.visiblePhotos.map(\.id)
        model.select(model.visiblePhotos[1])
        model.extendSelection(1)
        model.extendSelection(1)
        XCTAssertEqual(model.selectedPhotoIDs, Set(ids[1...3]))
        XCTAssertEqual(model.selectedID, ids[3])
        model.extendSelection(-3)
        XCTAssertEqual(model.selectedPhotoIDs, Set(ids[0...1]), "처음 고른 사진을 넘어가면 반대쪽으로 넓힌다")
        model.extendSelection(-5)
        XCTAssertEqual(model.selectedID, ids[0], "목록 끝에서 멈춘다")
    }

    func testAggregateMarksToggleMixedAndUndoAsOneStep() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let photos = model.visiblePhotos
        model.select(photos[0])
        model.setRating(2)
        model.handleTileClick(photos[1], clickCount: 1, modifiers: .command)

        XCTAssertEqual(model.markTargetPhotos.map(\.id), [photos[0].id, photos[1].id])
        XCTAssertNil(model.commonMarkRating)
        XCTAssertTrue(model.hasMixedMarks)
        model.toggleMarkRating(2)
        XCTAssertEqual(model.markTargetPhotos.map(\.rating), [2, 2])
        XCTAssertEqual(model.commonMarkRating, 2)
        model.toggleMarkRating(2)
        XCTAssertEqual(model.markTargetPhotos.map(\.rating), [0, 0])
        model.undo()
        XCTAssertEqual(model.markTargetPhotos.map(\.rating), [2, 2], "한 번에 실행 취소한다")

        model.setFlag(.pick)
        XCTAssertTrue(model.canClearMarkFlags)
        model.toggleMarkColorLabel(.red)
        XCTAssertEqual(model.markTargetPhotos.map(\.colorLabel), [.red, .red])
        model.toggleMarkColorLabel(.red)
        XCTAssertEqual(model.markTargetPhotos.map(\.colorLabel), [nil, nil])

        model.setMode(.edit)
        XCTAssertEqual(model.markTargetPhotos.count, 1, "한 장 보기에서는 활성 사진만 대상이다")
    }

    func testEditedFilterReconcilesSelectionForEditAndGridUndo() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let photos = model.photos
        for photo in photos.prefix(2) {
            model.focusPhoto(photo)
            var edits = photo.edits
            edits.exposure = 0.5
            model.updateEdits(edits)
        }
        model.filter = .edited
        model.setMode(.edit)
        model.focusPhoto(photos[1])
        model.undo()
        XCTAssertEqual(model.selectedID, photos[0].id, "사진 보기에서는 남은 첫 사진을 선택한다")

        model.undo()
        XCTAssertTrue(model.visiblePhotos.isEmpty)
        XCTAssertNil(model.selectedID, "남은 사진이 없으면 빈 편집 상태가 된다")

        model.filter = .all
        model.focusPhoto(photos[0])
        var edits = photos[0].edits
        edits.exposure = 0.25
        model.updateEdits(edits)
        model.filter = .edited
        model.setMode(.grid)
        model.undo()
        XCTAssertTrue(model.visiblePhotos.isEmpty)
        XCTAssertNil(model.selectedID, "그리드는 첫 사진을 강제로 선택하지 않는다")
    }
}
