import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 카탈로그에서 빼기를 실행 취소로 되돌리기.
@MainActor
final class CatalogRemovalUndoTests: XCTestCase {
    func testUndoRestoresOrderMarksEditsAndFoldersAndRestartPrunesThumbnails() async throws {
        let (model, _, urls) = try await TestSupport.startedModel(self, photos: 4)
        let original = model.photos
        model.focusPhoto(original[1])
        model.setRating(4)
        var edits = original[1].edits
        edits.exposure = 0.7
        model.updateEdits(edits)
        model.presentCreateFolder()
        XCTAssertNil(model.commitFolderSheet(model.folderSheetRequest!, name: "여행", includeSelected: false))
        let folder = model.photoFolders[0]
        model.filter = .all
        model.addPhotos([original[1].id, original[3].id], to: folder.id)
        for photo in model.photos { model.requestThumbnail(for: photo) }
        try await TestSupport.wait("thumbnails") { model.photos.allSatisfy { model.thumbnail(for: $0) != nil } }

        model.select(original[1])
        model.handleTileClick(original[2], clickCount: 1, modifiers: .command)
        model.requestRemoveFromCatalog()
        let removal = try XCTUnwrap(model.catalogRemoval)
        model.catalogRemoval = nil
        model.removeFromCatalog(Set(removal.photos.map(\.id)))
        XCTAssertEqual(model.photos.map(\.id), [original[0].id, original[3].id])
        XCTAssertEqual(model.photoFolders[0].photoIDs, [original[3].id])

        model.undo()
        XCTAssertEqual(model.photos.map(\.id), original.map(\.id), "빼기 전 순서로 돌아온다")
        XCTAssertEqual(model.photos[1].rating, 4)
        XCTAssertEqual(model.photos[1].edits.exposure, 0.7)
        XCTAssertEqual(model.photoFolders[0].photoIDs, [original[1].id, original[3].id], "내 폴더에도 돌아온다")
        model.requestThumbnail(for: model.photos[1])
        try await TestSupport.wait("restored thumbnail") { model.thumbnail(for: model.photos[1]) != nil }

        model.redo()
        XCTAssertEqual(model.photos.map(\.id), [original[0].id, original[3].id], "다시 실행하면 다시 뺀다")
        model.undo()
        model.undo()
        XCTAssertEqual(model.photos[1].edits.exposure, 0, "되돌린 사진의 앞선 보정도 되돌린다")

        // 같은 파일을 그사이 다시 가져왔으면 겹치지 않게 건너뛴다.
        model.removeFromCatalog([original[0].id])
        model.importURLs([urls[0]])
        try await TestSupport.wait("reimport") { !model.isImporting && model.photos.count == 4 }
        model.undo()
        XCTAssertEqual(model.photos.filter { $0.path == original[0].path }.count, 1)
        XCTAssertNil(model.photo(withID: original[0].id))
        XCTAssertEqual(model.operationMessage, "되돌릴 사진이 이미 카탈로그에 있습니다.")

        // 앱을 다시 열면 카탈로그에 없는 사진의 썸네일 폴더를 지운다.
        try model.flushSave()
        let thumbnails = ThumbnailStore().directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnails.appendingPathComponent(original[0].id.uuidString).path))
        let restarted = LibraryModel()
        restarted.start()
        try await TestSupport.wait("restart prune") {
            restarted.catalogLoaded &&
                !FileManager.default.fileExists(atPath: thumbnails.appendingPathComponent(original[0].id.uuidString).path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnails.appendingPathComponent(original[3].id.uuidString).path))
    }

    /// 사진 보기에서 보고 있던 사진을 빼면 같은 파일의 남은 항목, 없으면 그 뒤(끝이면 앞) 사진으로 옮긴다.
    func testRemovingTheViewedPhotoMovesToItsSiblingOrNeighbor() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let photos = model.visiblePhotos
        model.select(photos[0])
        model.setMode(.edit)
        model.createVirtualCopy()
        let copy = try XCTUnwrap(model.visiblePhotos.first(where: \.isVirtualCopy))
        model.focusPhoto(copy)
        model.removeFromCatalog([copy.id])
        XCTAssertEqual(model.selectedID, photos[0].id, "사본을 지우면 원래 항목")
        model.focusPhoto(photos[1])
        model.removeFromCatalog([photos[1].id])
        XCTAssertEqual(model.selectedID, photos[2].id, "그 뒤 사진")
        model.undo()
        XCTAssertEqual(model.selectedID, photos[1].id, "되돌리면 되돌린 사진을 보여 준다")
        model.redo()
        XCTAssertEqual(model.selectedID, photos[2].id)
        model.removeFromCatalog([photos[2].id])
        XCTAssertEqual(model.selectedID, photos[0].id, "끝이었으면 그 앞 사진")
    }
}
