import AppKit
import Combine
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 메뉴는 세션의 라이브러리에서 읽은 값이 바뀔 때 다시 계산된다(`@Observable`). 세션 자체는 라이브러리를 바꿀 때만 알린다.
@MainActor
final class LibrarySessionObservationTests: XCTestCase {
    func testMenuValuesFollowImportAutomaticCorrectionAndUndo() async throws {
        TestSupport.resetModelDefaults()
        _ = NSApplication.shared
        let root = try TestSupport.temporaryDirectory(self)
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let photoURL = root.appendingPathComponent("photo.jpg")
        try TestSupport.writeJPEG(photoURL, color: (40, 120, 160))
        let session = LibrarySession(initialDirectory: dataDirectory)
        session.library.start()
        try await TestSupport.wait("session catalog") {
            session.library.catalogLoaded && session.library.foldersLoaded
        }

        // 메뉴가 읽는 값: 선택한 사진과 실행 취소·다시 실행 가능 여부.
        let library = session.library
        let selectionMenu = ObservationCounter { _ = library.selection }
        let undoMenu = ObservationCounter { _ = (library.canUndo, library.canRedo) }

        library.importURLs([photoURL])
        try await TestSupport.wait("session import") { !library.isImporting && library.photos.count == 1 }
        XCTAssertNotNil(library.selection)
        XCTAssertGreaterThan(selectionMenu.count, 0, "가져오기로 바뀐 선택을 메뉴가 따라간다")

        let editsBeforeAutomaticCorrection = try XCTUnwrap(library.selection).edits
        undoMenu.reset()
        library.autoAdjust()
        try await TestSupport.wait("session automatic correction") { !library.isAutoAdjusting }
        XCTAssertNotEqual(try XCTUnwrap(library.selection).edits, editsBeforeAutomaticCorrection)
        XCTAssertTrue(library.canUndo)
        XCTAssertGreaterThan(undoMenu.count, 0, "자동 보정 뒤 실행 취소 메뉴가 켜진다")

        // 방금 바뀐 뒤 다시 지켜보기 시작할 틈을 준다.
        try await Task.sleep(nanoseconds: 50_000_000)
        undoMenu.reset()
        library.undo()
        XCTAssertEqual(library.selection?.edits, editsBeforeAutomaticCorrection)
        XCTAssertGreaterThan(undoMenu.count, 0, "실행 취소 뒤 다시 실행 메뉴가 켜진다")
    }

    func testOnlyTheActiveLibraryDrivesTheMenusAfterSwitch() async throws {
        TestSupport.resetModelDefaults()
        _ = NSApplication.shared
        let root = try TestSupport.temporaryDirectory(self)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try makeLibrary(at: firstDirectory, photoName: "first.jpg")
        try makeLibrary(at: secondDirectory, photoName: "second.jpg")

        let session = LibrarySession(initialDirectory: firstDirectory)
        session.library.start()
        // 열자마자 LUT 목록 읽기가 뒤에서 이어지고, 그동안에는 라이브러리 전환을 막는다. 다 끝난 뒤 전환한다.
        try await TestSupport.wait("first library") {
            session.library.catalogLoaded && session.library.foldersLoaded && session.library.photos.count == 1
                && !session.library.hasConflictingWorkflow
        }
        let previousLibrary = session.library
        var sessionChanges = 0
        let observation = session.objectWillChange.sink { sessionChanges += 1 }
        defer { observation.cancel() }

        let opened = await session.openLibrary(at: secondDirectory)
        XCTAssertTrue(opened)
        try await TestSupport.wait("second library") {
            session.library.catalogLoaded && session.library.foldersLoaded && session.library.photos.count == 1
        }
        XCTAssertFalse(session.library === previousLibrary)
        XCTAssertGreaterThan(sessionChanges, 0, "라이브러리를 바꾸면 세션이 알려 메뉴가 새 라이브러리를 읽는다")

        // 메뉴는 세션의 지금 라이브러리에서 읽는다.
        let menu = ObservationCounter { _ = session.library.showShortcuts }
        sessionChanges = 0
        previousLibrary.showShortcuts = true
        XCTAssertEqual(menu.count, 0, "교체된 라이브러리의 변경은 메뉴에 닿지 않는다")
        XCTAssertEqual(sessionChanges, 0, "세션은 라이브러리 안의 변경을 따로 알리지 않는다")

        session.library.showShortcuts = true
        XCTAssertGreaterThan(menu.count, 0, "지금 라이브러리의 변경은 메뉴가 따라간다")
    }

    private func makeLibrary(at directory: URL, photoName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photoURL = directory.appendingPathComponent(photoName)
        try TestSupport.writeJPEG(photoURL)
        try CatalogStore(url: directory.appendingPathComponent("catalog.json"))
            .save([PhotoAsset(url: photoURL)])
    }
}
