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

    func testBacksUpOncePerDayWithLinkedMasksAndRestores() throws {
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
                                                linkingMasksFrom: store.maskDirectory, now: day(0)))
        var changed = photo
        changed.rating = 5
        XCTAssertFalse(try backup.backUpIfNeeded(photos: [changed], copying: [folders], now: day(0)), "같은 날에는 한 번만")

        let saved = try XCTUnwrap(backup.backups().first)
        XCTAssertEqual(saved.lastPathComponent, CatalogBackup.folderName(for: day(0)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.path).sorted(),
                       ["Masks", "catalog.json", "folders.json"], "없는 프리셋 파일은 건너뛴다")
        XCTAssertFalse(try String(decoding: Data(contentsOf: saved.appendingPathComponent("catalog.json")), as: UTF8.self)
            .contains("pngData"), "마스크를 카탈로그 안에 넣지 않는다")
        // 보관본의 마스크는 원래 마스크 파일을 하드 링크해 디스크를 더 쓰지 않는다.
        let id = MaskFileStore.contentID(png)
        func inode(_ directory: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(id).png").path)[.systemFileNumber] as? Int
        }
        XCTAssertEqual(try XCTUnwrap(inode(saved.appendingPathComponent("Masks"))), try XCTUnwrap(inode(store.maskDirectory)))

        // 원래 마스크가 지워져도 보관본은 남고, 날짜 폴더의 파일과 Masks 폴더만 옮기면 열린다.
        try store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.maskDirectory.appendingPathComponent("\(id).png").path))
        let restored = try temporaryDirectory()
        for name in ["catalog.json", "Masks"] {
            try FileManager.default.copyItem(at: saved.appendingPathComponent(name), to: restored.appendingPathComponent(name))
        }
        XCTAssertEqual(try CatalogStore(url: restored.appendingPathComponent("catalog.json")).load(), [photo])
    }

    func testBackupWritesMasksThatCannotBeLinked() throws {
        let data = try temporaryDirectory()
        let store = CatalogStore(url: data.appendingPathComponent("catalog.json"))
        var photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P2.RW2"))
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 4, 5, 6])
        photo.edits.localAdjustments = [LocalAdjustment(exposure: 0.5, baseMask: RasterMask(width: 4, height: 4, pngData: png))]
        try store.save([photo])
        // 원래 마스크 파일이 망가졌으면 링크하지 않고 메모리의 마스크로 새로 쓴다.
        let live = store.maskDirectory.appendingPathComponent("\(MaskFileStore.contentID(png)).png")
        try Data(repeating: 0, count: png.count).write(to: live)
        let backup = CatalogBackup(directory: data.appendingPathComponent("Backups"))
        XCTAssertTrue(try backup.backUpIfNeeded(photos: [photo], copying: [], linkingMasksFrom: store.maskDirectory, now: day(0)))
        let saved = try XCTUnwrap(backup.backups().first)
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("Masks").appendingPathComponent(live.lastPathComponent)), png)
        XCTAssertEqual(try CatalogStore(url: saved.appendingPathComponent("catalog.json")).load(), [photo])

        XCTAssertTrue(try backup.backUpIfNeeded(photos: [photo], copying: [], now: day(1)), "원래 마스크 폴더를 모를 때도 쓴다")
        XCTAssertEqual(try CatalogStore(url: try XCTUnwrap(backup.backups().first).appendingPathComponent("catalog.json")).load(),
                       [photo])
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
