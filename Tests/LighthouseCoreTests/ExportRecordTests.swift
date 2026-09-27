import Foundation
import XCTest
@testable import LighthouseCore

final class ExportRecordTests: XCTestCase {
    func testDigestFollowsFileContentOnly() {
        var photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        let digest = ExportRecord.digest(of: photo)
        photo.rating = 5
        photo.colorLabel = .red
        photo.snapshots = [EditSnapshot(name: "a", edits: EditSettings(exposure: 1))]
        XCTAssertEqual(ExportRecord.digest(of: photo), digest, "별점·라벨·스냅숏은 파일에 들어가지 않는다")
        var edited = photo
        edited.edits.exposure = 0.3
        XCTAssertNotEqual(ExportRecord.digest(of: edited), digest)
        var described = photo
        described.caption = "바다"
        XCTAssertNotEqual(ExportRecord.digest(of: described), digest)
        var masked = photo
        masked.edits.localAdjustments = [LocalAdjustment(exposure: 1, baseMask: RasterMask(width: 1, height: 1, pngData: Data([1, 2])))]
        var otherMask = masked
        otherMask.edits.localAdjustments[0].baseMask = RasterMask(width: 1, height: 1, pngData: Data([1, 3]))
        XCTAssertNotEqual(ExportRecord.digest(of: masked), ExportRecord.digest(of: otherMask), "마스크 내용도 센다")
    }

    func testRecordNoticesChangedFileAndRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([0xff, 0xd8, 1, 2, 3]).write(to: file)
        var photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(photo), as: UTF8.self).contains("lastExport"))
        let record = try XCTUnwrap(ExportRecord.make(photo: photo, file: file, baseName: "P1-edited",
                                                     options: ExportOptions(maxPixel: 2048)))
        XCTAssertEqual(record.fileSHA256, "d37e2a668a41b86e565ba4d9a0263a48cf80cfd3401b07aa17b6562b75c19394")
        XCTAssertTrue(record.fileIsUntouched)
        XCTAssertFalse(record.isChanged(photo))
        photo.lastExport = record
        XCTAssertEqual(try JSONDecoder().decode(PhotoAsset.self, from: JSONEncoder().encode(photo)).lastExport, record)
        try Data([0xff, 0xd8, 9]).write(to: file)
        XCTAssertFalse(record.fileIsUntouched, "그 뒤 바뀐 파일은 앱이 쓴 그대로가 아니다")
        XCTAssertNil(ExportRecord.make(photo: photo, file: file.appendingPathExtension("없음"), baseName: "x",
                                       options: ExportOptions()))
    }

    func testOldRecordWithoutFileFingerprintDecodesButIsNotTrusted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3]).write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let oldRecord = ExportRecord(exportedAt: Date(), path: file.path, baseName: "old",
                                     options: ExportOptions(), digest: "edit-digest",
                                     fileSize: size, fileModified: modified)

        let encoded = try JSONEncoder().encode(oldRecord)
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])["fileSHA256"])
        let decoded = try JSONDecoder().decode(ExportRecord.self, from: encoded)

        XCTAssertNil(decoded.fileSHA256)
        XCTAssertFalse(decoded.fileIsUntouched)
    }

    func testMalformedFileFingerprintsAreNotTrusted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3]).write(to: file)
        let photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        let valid = try XCTUnwrap(ExportRecord.make(photo: photo, file: file, baseName: "P1",
                                                    options: ExportOptions()))

        for malformed in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            var record = valid
            record.fileSHA256 = malformed
            XCTAssertFalse(record.fileIsUntouched, "잘못된 파일 해시는 안전한 원본으로 믿지 않는다")
        }
    }

    func testSameSizeAndModificationTimeWithDifferentBytesIsNotUntouched() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3, 4]).write(to: file)
        let photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        let record = try XCTUnwrap(ExportRecord.make(photo: photo, file: file, baseName: "P1",
                                                     options: ExportOptions()))

        try Data([4, 3, 2, 1]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: record.fileModified], ofItemAtPath: file.path)
        let changedAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((changedAttributes[.size] as? NSNumber)?.intValue, record.fileSize)
        XCTAssertEqual(try XCTUnwrap(changedAttributes[.modificationDate] as? Date)
            .timeIntervalSince(record.fileModified), 0, accuracy: 0.001)
        XCTAssertFalse(record.fileIsUntouched)
    }

    func testMakeRejectsMissingAndUnreadableOutput() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        let photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))

        XCTAssertNil(ExportRecord.make(photo: photo, file: temporaryDirectory.appendingPathComponent("missing.jpg"),
                                       baseName: "missing", options: ExportOptions()))
        XCTAssertNil(ExportRecord.make(photo: photo, file: temporaryDirectory,
                                       baseName: "unreadable", options: ExportOptions()))
    }
}
