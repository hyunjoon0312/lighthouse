import AppKit
import Combine
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class LibrarySessionObservationTests: XCTestCase {
    func testSessionRelaysImportAutomaticCorrectionAndUndoChanges() async throws {
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

        var notificationCount = 0
        let observation = session.objectWillChange.sink { notificationCount += 1 }

        session.library.importURLs([photoURL])
        try await TestSupport.wait("session import") {
            !session.library.isImporting && session.library.photos.count == 1
        }
        XCTAssertNotNil(session.library.selection)
        XCTAssertGreaterThan(notificationCount, 0, "가져오기로 바뀐 선택 상태를 세션이 알려야 한다")

        let editsBeforeAutomaticCorrection = try XCTUnwrap(session.library.selection).edits
        notificationCount = 0
        session.library.autoAdjust()
        try await TestSupport.wait("session automatic correction") { !session.library.isAutoAdjusting }
        let adjustedEdits = try XCTUnwrap(session.library.selection).edits
        XCTAssertNotEqual(adjustedEdits, editsBeforeAutomaticCorrection)
        XCTAssertTrue(session.library.canUndo)
        XCTAssertGreaterThan(notificationCount, 0, "자동 보정과 실행 취소 상태를 세션이 알려야 한다")

        notificationCount = 0
        session.library.undo()
        XCTAssertEqual(session.library.selection?.edits, editsBeforeAutomaticCorrection)
        XCTAssertGreaterThan(notificationCount, 0, "실행 취소 결과를 세션이 알려야 한다")
        withExtendedLifetime(observation) {}
    }

    func testSessionRelaysOnlyTheActiveLibraryAfterSwitch() async throws {
        TestSupport.resetModelDefaults()
        _ = NSApplication.shared
        let root = try TestSupport.temporaryDirectory(self)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try makeLibrary(at: firstDirectory, photoName: "first.jpg")
        try makeLibrary(at: secondDirectory, photoName: "second.jpg")

        let session = LibrarySession(initialDirectory: firstDirectory)
        session.library.start()
        try await TestSupport.wait("first library") {
            session.library.catalogLoaded && session.library.foldersLoaded && session.library.photos.count == 1
        }
        let previousLibrary = session.library
        var notificationCount = 0
        let observation = session.objectWillChange.sink { notificationCount += 1 }

        let opened = await session.openLibrary(at: secondDirectory)
        XCTAssertTrue(opened)
        try await TestSupport.wait("second library") {
            session.library.catalogLoaded && session.library.foldersLoaded && session.library.photos.count == 1
        }
        XCTAssertFalse(session.library === previousLibrary)

        notificationCount = 0
        previousLibrary.showShortcuts = true
        XCTAssertEqual(notificationCount, 0, "교체된 라이브러리의 변경은 세션에 전달하지 않아야 한다")

        session.library.showShortcuts = true
        XCTAssertGreaterThan(notificationCount, 0, "활성 라이브러리의 변경은 세션에 전달해야 한다")
        withExtendedLifetime(observation) {}
    }

    private func makeLibrary(at directory: URL, photoName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photoURL = directory.appendingPathComponent(photoName)
        try TestSupport.writeJPEG(photoURL)
        try CatalogStore(url: directory.appendingPathComponent("catalog.json"))
            .save([PhotoAsset(url: photoURL)])
    }
}
