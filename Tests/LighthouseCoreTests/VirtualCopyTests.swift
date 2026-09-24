import CoreGraphics
import Foundation
import XCTest
@testable import LighthouseCore

final class VirtualCopyTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCopyKeepsFileAndEditsAndTakesNextFreeNumber() {
        var master = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"),
                                metadata: PhotoMetadata(width: 60, height: 40, capturedAt: Date()))
        master.rating = 4
        master.flag = .pick
        master.edits = EditSettings(exposure: 0.7)
        var third = master.virtualCopy(among: [master])
        third.copyName = "사본 3"
        let other = PhotoAsset(url: URL(fileURLWithPath: "/photos/P2.RW2")).virtualCopy(among: [])
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let copy = master.virtualCopy(among: [master, third, other], at: date)

        XCTAssertNotEqual(copy.id, master.id)
        XCTAssertEqual(copy.path, master.path)
        XCTAssertEqual(copy.copyName, "사본 1")
        XCTAssertEqual(copy.edits, master.edits)
        XCTAssertEqual(copy.rating, 4)
        XCTAssertEqual(copy.flag, .pick)
        XCTAssertEqual(copy.importedAt, date)
        XCTAssertTrue(copy.isVirtualCopy)
        XCTAssertFalse(master.isVirtualCopy)
        XCTAssertEqual(copy.displayName, "P1.RW2 · 사본 1")
        XCTAssertEqual(master.displayName, "P1.RW2")
        let fromCopy = copy.virtualCopy(among: [master, third, other, copy])
        XCTAssertEqual(fromCopy.copyName, "사본 2", "사본에서 만든 사본도 같은 파일 기준으로 번호를 매긴다")
        XCTAssertEqual(other.copyName, "사본 1", "다른 파일의 사본 번호는 따로 센다")
    }

    func testCatalogKeepsCopiesOfSameFileAndReadsLegacyEntries() throws {
        let directory = try temporaryDirectory()
        let store = CatalogStore(url: directory.appendingPathComponent("catalog.json"))
        var master = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.JPG"))
        master.edits = EditSettings(exposure: 0.3)
        var copy = master.virtualCopy(among: [master])
        copy.edits = EditSettings(saturation: 0)
        copy.rating = 2
        try store.save([master, copy])
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\"copyName\"").count - 1, 1, "원래 항목에는 copyName을 쓰지 않는다")
        XCTAssertEqual(try store.load(), [master, copy])

        let legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        var photos = legacy["photos"] as! [[String: Any]]
        photos[1].removeValue(forKey: "copyName")
        try JSONSerialization.data(withJSONObject: ["version": 1, "photos": photos]).write(to: store.url)
        XCTAssertNil(try store.load()[1].copyName)
    }

    func testCopiesStayInOneBurstShotAndThumbnailFolderIsRemoved() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let master = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"),
                                metadata: PhotoMetadata(camera: "S9", capturedAt: base))
        let copy = master.virtualCopy(among: [master])
        XCTAssertTrue(BurstGrouping.groups(for: [master, copy]).isEmpty, "사본은 연속 촬영 컷이 아니다")
        let next = PhotoAsset(url: URL(fileURLWithPath: "/photos/P2.RW2"),
                              metadata: PhotoMetadata(camera: "S9", capturedAt: base.addingTimeInterval(0.2)))
        XCTAssertEqual(BurstGrouping.groups(for: [master, copy, next]).first?.shots, [[master.id, copy.id], [next.id]])

        let store = ThumbnailStore(directory: try temporaryDirectory())
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        store.store(context.makeImage()!, photoID: copy.id, key: "k")
        store.store(context.makeImage()!, photoID: master.id, key: "k")
        store.remove(photoID: copy.id)
        XCTAssertNil(store.load(photoID: copy.id, key: "k"))
        XCTAssertNotNil(store.load(photoID: master.id, key: "k"), "원래 항목의 썸네일은 남는다")
    }
}
