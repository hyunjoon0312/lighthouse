import Foundation
import XCTest
@testable import LighthouseCore

final class PhotoFolderTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMembershipAcrossFoldersRestartAndOriginalPreservation() throws {
        let root = try directory()
        let source = root.appendingPathComponent("original.rw2")
        let bytes = Data([0, 1, 2, 3, 255, 42])
        try bytes.write(to: source)
        let store = PhotoFolderStore(url: root.appendingPathComponent("data/folders.json"))
        XCTAssertEqual(try store.load(), [])
        let shared = UUID(), other = UUID(), absentFromCatalog = UUID()
        var first = PhotoFolder(name: "  여행 / 2026  ")
        first.add([shared, other, shared])
        first.add([absentFromCatalog])
        var second = PhotoFolder(name: "가족")
        second.add([shared])
        first.remove([other])
        XCTAssertEqual(first.photoIDs, [shared, absentFromCatalog])
        XCTAssertEqual(second.photoIDs, [shared])
        try store.save([first, second])
        let reopened = try PhotoFolderStore(url: store.url).load()
        XCTAssertEqual(reopened.map(\.name), ["여행 / 2026", "가족"])
        XCTAssertEqual(reopened[0].photoIDs, [shared, absentFromCatalog])
        XCTAssertEqual(reopened[1].photoIDs, [shared])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        second.remove([shared])
        XCTAssertEqual(first.photoIDs, [shared, absentFromCatalog])
        XCTAssertEqual(second.photoIDs, [])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let encoded = try XCTUnwrap((json["folders"] as? [[String: Any]])?.first?["photoIDs"] as? [String])
        XCTAssertEqual(encoded, encoded.sorted())
    }

    func testRejectsMalformedDuplicateAndInvalidNamesOnLoadAndSave() throws {
        let root = try directory()
        let store = PhotoFolderStore(url: root.appendingPathComponent("folders.json"))
        let id = UUID()
        let good = PhotoFolder(id: id, name: "Trips")
        try store.save([good])
        let original = try Data(contentsOf: store.url)

        XCTAssertThrowsError(try store.save([good, PhotoFolder(id: id, name: "Different")]))
        XCTAssertThrowsError(try store.save([good, PhotoFolder(name: "trips")]))
        XCTAssertThrowsError(try store.save([PhotoFolder(name: "   ")]))
        XCTAssertThrowsError(try store.save([PhotoFolder(name: String(repeating: "a", count: 81))]))
        XCTAssertEqual(try Data(contentsOf: store.url), original)

        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try Data(#"{"version":2,"folders":[]}"#.utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try json(["version": 1, "folders": [folder(id: id, name: "A"), folder(id: id, name: "B")]])
            .write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try json(["version": 1, "folders": [folder(name: "A"), folder(name: "a")]])
            .write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try json(["version": 1, "folders": [folder(name: "   ")]])
            .write(to: store.url)
        XCTAssertThrowsError(try store.load())
        try json(["version": 1, "folders": [folder(name: String(repeating: "x", count: 81))]])
            .write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testDuplicatePhotoIDsDecodeToOneAndOtherReadErrorPropagates() throws {
        let root = try directory()
        let store = PhotoFolderStore(url: root.appendingPathComponent("folders.json"))
        let photoID = UUID()
        let entry: [String: Any] = ["id": UUID().uuidString, "name": "Collection",
                                    "photoIDs": [photoID.uuidString, photoID.uuidString]]
        try json(["version": 1, "folders": [entry]]).write(to: store.url)
        XCTAssertEqual(try store.load().first?.photoIDs, [photoID])
        XCTAssertThrowsError(try PhotoFolderStore(url: root).load())
    }

    private func folder(id: UUID = UUID(), name: String) -> [String: Any] {
        ["id": id.uuidString, "name": name, "photoIDs": []]
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
