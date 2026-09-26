import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 보정이 바뀐 사진만 다시 내보내기.
@MainActor
final class ReexportTests: XCTestCase {
    func testChangedPhotosAreReexportedAndPreviousFilesTrashedOnlyWhenUntouched() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 3)
        let exports = root.appendingPathComponent("blog", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        model.moveToTrash = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let photos = model.photos
        model.selectAllVisible()
        model.export(scope: .selected, options: ExportOptions(maxPixel: 40, quality: 0.8), directory: exports)
        try await TestSupport.wait("export") { !model.isExporting }
        XCTAssertTrue(model.photos.allSatisfy { $0.lastExport != nil })
        XCTAssertTrue(model.changedSinceExport.isEmpty)

        model.focusPhoto(photos[0])
        var edits = photos[0].edits
        edits.exposure = 1
        model.updateEdits(edits)
        model.setRating(5)
        model.focusPhoto(photos[1])
        model.setKeywords("바다", for: photos[1].id)
        model.focusPhoto(photos[2])
        model.setRating(3)
        XCTAssertEqual(Set(model.changedSinceExport.map(\.id)), [photos[0].id, photos[1].id], "별점만 바꾼 사진은 빠진다")

        // 두 번째 사진의 이전 파일은 그사이 손댔으므로 휴지통으로 옮기지 않는다.
        let first = try XCTUnwrap(model.photo(withID: photos[0].id)?.lastExport)
        let second = try XCTUnwrap(model.photo(withID: photos[1].id)?.lastExport)
        try Data(contentsOf: URL(fileURLWithPath: second.path)).dropLast(1).write(to: URL(fileURLWithPath: second.path))
        model.reexport(model.changedSinceExport, trashPrevious: true)
        try await TestSupport.wait("re-export") { !model.isExporting }
        XCTAssertTrue(model.exportReport?.contains("2장 다시 내보냄") == true, model.exportReport ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(URL(fileURLWithPath: first.path).lastPathComponent).path))
        XCTAssertEqual(model.photo(withID: photos[0].id)?.lastExport?.path, first.path, "휴지통으로 옮긴 자리에 같은 이름으로")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "손댄 이전 파일은 그대로")
        XCTAssertNotEqual(model.photo(withID: photos[1].id)?.lastExport?.path, second.path, "번호를 붙여 새로 쓴다")
        XCTAssertTrue(model.changedSinceExport.isEmpty)

        try model.flushSave()
        let restarted = LibraryModel()
        restarted.start()
        try await TestSupport.wait("restart") { restarted.catalogLoaded }
        XCTAssertEqual(restarted.photo(withID: photos[0].id)?.lastExport?.baseName, first.baseName, "기록은 카탈로그에 남는다")
    }

    func testPreviousFileStaysWhenTheNewOneCannotBeMade() async throws {
        let (model, root, urls) = try await TestSupport.startedModel(self, photos: 1)
        let exports = root.appendingPathComponent("blog", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        model.moveToTrash = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        model.export(scope: .current, options: ExportOptions(maxPixel: 40, quality: 0.8), directory: exports)
        try await TestSupport.wait("export") { !model.isExporting }
        let photo = try XCTUnwrap(model.photos.first)
        let previous = try XCTUnwrap(photo.lastExport)
        var edits = photo.edits
        edits.exposure = 1
        model.updateEdits(edits)
        XCTAssertEqual(model.changedSinceExport.map(\.id), [photo.id])

        // 원본을 옮겨 현상할 수 없게 한다. 이전 파일은 휴지통으로 가지 않고 기록도 그대로다.
        try FileManager.default.moveItem(at: urls[0], to: root.appendingPathComponent("moved.jpg"))
        model.reexport([try XCTUnwrap(model.photos.first)], trashPrevious: true)
        try await TestSupport.wait("re-export") { !model.isExporting }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(model.photos.first?.lastExport, previous)
        XCTAssertTrue(model.exportReport?.contains("실패 1장") == true, model.exportReport ?? "")

        model.refreshMissingOriginals()
        try await TestSupport.wait("missing") { model.isMissing(photo) }
        XCTAssertTrue(model.changedSinceExport.isEmpty, "원본이 없는 사진은 다시 내보낼 목록에서 빠진다")
    }
}
