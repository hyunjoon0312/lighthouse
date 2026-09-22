import CryptoKit
import Foundation
import XCTest
@testable import LighthouseCore

final class LUTLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func cube(title: String? = nil, value: String = "0") -> Data {
        let titleLine = title.map { "TITLE \"\($0)\"\n" } ?? ""
        return Data((titleLine + "LUT_3D_SIZE 2\n" + Array(repeating: "\(value) 0 0", count: 8).joined(separator: "\n") + "\n").utf8)
    }

    private func writeSource(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func id(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeLegacy(_ data: Data, into directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = id(for: data)
        try data.write(to: directory.appendingPathComponent(identifier + ".cube"))
        return identifier
    }

    func testMultipleImportsNamesDedupAndRestart() throws {
        let root = try directory()
        let libraryDirectory = root.appendingPathComponent("data/LUTs")
        let store = LUTStore(directory: libraryDirectory)
        XCTAssertTrue(try store.library().isEmpty)
        let firstData = cube(title: "Film", value: "0")
        let first = try store.importCube(from: writeSource(firstData, named: "original.cube", in: root))
        let second = try store.importCube(from: writeSource(cube(title: "Film", value: "0.2"),
                                                         named: "second.cube", in: root))
        let nameless = try store.importCube(from: writeSource(cube(value: "0.4"),
                                                           named: "Pastel.cube", in: root))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.name, "Film")
        XCTAssertEqual(second.name, "Film")
        XCTAssertEqual(nameless.name, "Pastel")
        let again = try store.importCube(from: writeSource(firstData, named: "renamed.cube", in: root))
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.name, "Film")
        let reopened = LUTStore(directory: libraryDirectory)
        let items = try reopened.library()
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.error == nil })
        XCTAssertEqual(items.filter { $0.name == "Film" }.map(\.id), [first.id, second.id].sorted())
        XCTAssertEqual(items.first(where: { $0.id == nameless.id })?.name, "Pastel")
        XCTAssertEqual(try reopened.library(), items)
    }

    func testLegacyTitleKnownNameAndHashFallbackWithoutWriting() throws {
        let root = try directory()
        let store = LUTStore(directory: root.appendingPathComponent("LUTs"))
        let titledID = try writeLegacy(cube(title: "Old Title"), into: store.directory)
        let knownID = try writeLegacy(cube(value: "0.3"), into: store.directory)
        let hashID = try writeLegacy(cube(value: "0.6"), into: store.directory)
        let items = try store.library(knownNames: [titledID: "Catalog Name", knownID: "Previous Name"])
        XCTAssertEqual(items.first(where: { $0.id == titledID })?.name, "Old Title")
        XCTAssertEqual(items.first(where: { $0.id == knownID })?.name, "Previous Name")
        XCTAssertEqual(items.first(where: { $0.id == hashID })?.name, "이름 없는 LUT · \(hashID.prefix(8))")
        for id in [titledID, knownID, hashID] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(id + ".json").path))
        }
    }

    func testDamagedCubeAndInvalidSidecarIsolation() throws {
        let root = try directory()
        let store = LUTStore(directory: root.appendingPathComponent("LUTs"))
        let good = try store.importCube(from: writeSource(cube(title: "Good"), named: "good.cube", in: root))
        let bad = try store.importCube(from: writeSource(cube(title: "Bad", value: "0.7"), named: "bad.cube", in: root))
        let badCube = store.directory.appendingPathComponent(bad.id + ".cube")
        try Data("broken".utf8).write(to: badCube)
        let wrongSidecar = Data(#"{"version":2,"id":"wrong","name":"Wrong"}"#.utf8)
        let goodSidecar = store.directory.appendingPathComponent(good.id + ".json")
        try wrongSidecar.write(to: goodSidecar)
        let items = try store.library(knownNames: [bad.id: "Catalog Bad"])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first(where: { $0.id == good.id })?.name, "Good")
        XCTAssertNil(items.first(where: { $0.id == good.id })?.error)
        XCTAssertEqual(items.first(where: { $0.id == bad.id })?.name, "Bad")
        XCTAssertNotNil(items.first(where: { $0.id == bad.id })?.error)
        XCTAssertEqual(try Data(contentsOf: goodSidecar), wrongSidecar)
        let repaired = try store.importCube(from: root.appendingPathComponent("good.cube"))
        XCTAssertEqual(repaired.name, "Good")
        XCTAssertEqual(try store.library().first(where: { $0.id == good.id })?.error, nil)
        XCTAssertNotEqual(try Data(contentsOf: goodSidecar), wrongSidecar)
    }

    func testInvalidFilesDirectoryErrorAndCatalogIndependence() throws {
        let root = try directory()
        let store = LUTStore(directory: root.appendingPathComponent("LUTs"))
        let adjustment = try store.importCube(from: writeSource(cube(title: "Saved"),
                                                               named: "saved.cube", in: root))
        try cube(value: "0.2").write(to: store.directory.appendingPathComponent("not-a-hash.cube"))
        try cube(value: "0.2").write(to: store.directory.appendingPathComponent(".hidden.cube"))
        try cube(value: "0.2").write(to: store.directory.appendingPathComponent(String(repeating: "A", count: 64) + ".cube"))
        try cube(value: "0.2").write(to: store.directory.appendingPathComponent(String(repeating: "a", count: 64) + ".txt"))
        let linkedID = id(for: cube(value: "0.9"))
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent(linkedID + ".cube"),
                                                   withDestinationURL: store.directory.appendingPathComponent(adjustment.id + ".cube"))
        XCTAssertEqual(try store.library().map(\.id), [adjustment.id])

        var photo = PhotoAsset(url: root.appendingPathComponent("photo.png"))
        photo.edits.lut = adjustment
        let catalog = CatalogStore(url: root.appendingPathComponent("catalog.json"))
        try catalog.save([photo])
        photo.edits.lut = nil
        try catalog.save([photo])
        XCTAssertNil(try catalog.load().first?.edits.lut)
        XCTAssertEqual(try store.library().map(\.id), [adjustment.id])

        let fileAsDirectory = root.appendingPathComponent("ordinary-file")
        try Data("x".utf8).write(to: fileAsDirectory)
        XCTAssertThrowsError(try LUTStore(directory: fileAsDirectory).library())
    }
}
