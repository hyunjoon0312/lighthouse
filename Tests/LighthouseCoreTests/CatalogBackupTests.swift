import Foundation
import XCTest
@testable import LighthouseCore

final class CatalogBackupTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 86_400)
    }

    func testBacksUpOncePerDayWithMasksInsideAndRestores() throws {
        let data = try temporaryDirectory()
        let store = CatalogStore(url: data.appendingPathComponent("catalog.json"))
        var photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        photo.edits.localAdjustments = [LocalAdjustment(exposure: 0.5, baseMask: RasterMask(width: 4, height: 4, pngData: png))]
        try store.save([photo])
        let folders = data.appendingPathComponent("folders.json")
        try Data("{\"folders\":[]}".utf8).write(to: folders)
        let backup = CatalogBackup(directory: data.appendingPathComponent("Backups"))

        XCTAssertTrue(try backup.backUpIfNeeded(photos: [photo], copying: [folders, data.appendingPathComponent("presets.json")],
                                                now: day(0)))
        var changed = photo
        changed.rating = 5
        XCTAssertFalse(try backup.backUpIfNeeded(photos: [changed], copying: [folders], now: day(0)), "같은 날에는 한 번만")

        let saved = try XCTUnwrap(backup.backups().first)
        XCTAssertEqual(saved.lastPathComponent, CatalogBackup.folderName(for: day(0)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.path).sorted(), ["catalog.json", "folders.json"],
                       "없는 프리셋 파일은 건너뛴다")
        // 보관본 폴더만 따로 옮겨도 마스크 파일 없이 열린다.
        let restored = try temporaryDirectory()
        try FileManager.default.copyItem(at: saved.appendingPathComponent("catalog.json"),
                                         to: restored.appendingPathComponent("catalog.json"))
        XCTAssertEqual(try CatalogStore(url: restored.appendingPathComponent("catalog.json")).load(), [photo])
    }

    func testKeepsSevenMostRecentDaysAndLeavesOtherFolders() throws {
        let data = try temporaryDirectory()
        let directory = data.appendingPathComponent("Backups")
        let backup = CatalogBackup(directory: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("내 메모"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".\(CatalogBackup.folderName(for: day(0)))-stale"),
                                                withIntermediateDirectories: true)
        for offset in 0..<10 {
            XCTAssertTrue(try backup.backUpIfNeeded(photos: [], copying: [], now: day(offset)))
        }
        XCTAssertEqual(backup.backups().map(\.lastPathComponent), (3..<10).reversed().map { CatalogBackup.folderName(for: day($0)) })
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains("내 메모"), "날짜 이름이 아닌 폴더는 지우지 않는다")
        XCTAssertFalse(names.contains { $0.hasPrefix(".") }, "멈춘 임시 폴더는 정리한다")
    }
}
