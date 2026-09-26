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
        XCTAssertTrue(record.fileIsUntouched)
        XCTAssertFalse(record.isChanged(photo))
        photo.lastExport = record
        XCTAssertEqual(try JSONDecoder().decode(PhotoAsset.self, from: JSONEncoder().encode(photo)).lastExport, record)
        try Data([0xff, 0xd8, 9]).write(to: file)
        XCTAssertFalse(record.fileIsUntouched, "그 뒤 바뀐 파일은 앱이 쓴 그대로가 아니다")
        XCTAssertNil(ExportRecord.make(photo: photo, file: file.appendingPathExtension("없음"), baseName: "x",
                                       options: ExportOptions()))
    }
}
