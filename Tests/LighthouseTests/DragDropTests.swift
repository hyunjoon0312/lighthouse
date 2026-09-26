import CoreTransferable
import Foundation
@testable import Lighthouse
import LighthouseCore
import UniformTypeIdentifiers
import XCTest

/// Finder에서 끌어 놓아 가져오기와 사진을 내 폴더로 끌어 넣기.
@MainActor
final class DragDropTests: XCTestCase {
    func testDroppedFilesImportAndDraggedPhotosJoinFolder() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 3)
        let extra = root.appendingPathComponent("dropped", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try TestSupport.writeJPEG(extra.appendingPathComponent("a.jpg"))
        XCTAssertFalse(model.importDropped([URL(string: "https://example.com/a.jpg")!]), "파일이 아닌 주소는 받지 않는다")
        XCTAssertTrue(model.importDropped([extra]))
        try await TestSupport.wait("drop import") { !model.isImporting && model.photos.count == 4 }

        let photos = model.visiblePhotos
        model.select(photos[0])
        model.handleTileClick(photos[2], clickCount: 1, modifiers: .command)
        let payload = model.dragPayload(for: photos[2])
        XCTAssertEqual(Set(LibraryModel.draggedPhotoIDs([payload])), [photos[0].id, photos[2].id],
                       "선택한 사진 중 하나를 끌면 선택한 사진 전체")
        XCTAssertEqual(LibraryModel.draggedPhotoIDs([model.dragPayload(for: photos[1])]), [photos[1].id],
                       "선택하지 않은 사진을 끌면 그 사진만")

        // 앱 전용 형식 하나만 올린다. 글자·파일 형식이 없어 다른 앱에 놓아도 텍스트 클리핑 등이 생기지 않는다.
        let provider = NSItemProvider()
        provider.register(payload)
        XCTAssertEqual(provider.registeredContentTypes, [.lighthousePhotos])
        XCTAssertFalse(UTType.lighthousePhotos.conforms(to: .text))
        let loaded: PhotoDragItem = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: PhotoDragItem.self) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(Set(loaded.ids), [photos[0].id, photos[2].id])

        model.presentCreateFolder()
        let request = try XCTUnwrap(model.folderSheetRequest)
        XCTAssertNil(model.commitFolderSheet(request, name: "블로그", includeSelected: false))
        let folder = try XCTUnwrap(model.photoFolders.first)
        XCTAssertTrue(model.addPhotos(LibraryModel.draggedPhotoIDs([payload]) + [UUID()], to: folder.id))
        XCTAssertEqual(model.photoFolders.first?.photoIDs, [photos[0].id, photos[2].id], "카탈로그에 없는 ID는 넣지 않는다")
    }
}
