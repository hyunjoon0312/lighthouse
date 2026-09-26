import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class PhotoCriteriaTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func photo(_ name: String, camera: String? = "Panasonic DC-S9", lens: String? = "LUMIX S 20-60mm",
                       focal: Double? = 35, iso: Int? = 400, captured: String? = "2026-09-20 10:00",
                       rating: Int = 0, flag: PhotoFlag = .none) -> PhotoAsset {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var asset = PhotoAsset(url: URL(fileURLWithPath: "/photos/\(name).RW2"),
                               metadata: PhotoMetadata(camera: camera, lens: lens, iso: iso,
                                                       capturedAt: captured.flatMap(formatter.date(from:)),
                                                       focalLength: focal))
        asset.rating = rating
        asset.flag = flag
        return asset
    }

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    func testEachConditionAndMissingInformation() {
        var criteria = PhotoCriteria()
        XCTAssertTrue(criteria.isEmpty)
        XCTAssertTrue(criteria.matches(photo("a", camera: nil, focal: nil, iso: nil, captured: nil)))

        criteria.camera = "Panasonic DC-S9"
        XCTAssertTrue(criteria.matches(photo("a")))
        XCTAssertFalse(criteria.matches(photo("b", camera: "Other")))
        criteria = PhotoCriteria()
        criteria.minimumFocalLength = 20
        criteria.maximumFocalLength = 35
        XCTAssertTrue(criteria.matches(photo("a", focal: 35)), "경계값을 포함한다")
        XCTAssertFalse(criteria.matches(photo("b", focal: 50)))
        XCTAssertFalse(criteria.matches(photo("c", focal: nil)), "초점거리가 없는 사진은 빠진다")
        criteria = PhotoCriteria()
        criteria.maximumISO = 800
        XCTAssertTrue(criteria.matches(photo("a", iso: 800)))
        XCTAssertFalse(criteria.matches(photo("b", iso: 1600)))
        criteria = PhotoCriteria()
        criteria.flag = PhotoFlag.none
        XCTAssertTrue(criteria.matches(photo("a")))
        XCTAssertFalse(criteria.matches(photo("b", flag: .pick)), "표시 없음은 표시한 사진을 뺀다")
        criteria = PhotoCriteria()
        criteria.minimumRating = 3
        criteria.text = "  b  "
        XCTAssertTrue(criteria.matches(photo("b", rating: 4)))
        XCTAssertFalse(criteria.matches(photo("a", rating: 4)))
        XCTAssertFalse(criteria.matches(photo("b", rating: 2)))
    }

    func testDayRangeCoversWholeDays() {
        var criteria = PhotoCriteria()
        criteria.firstDay = day("2026-09-20").addingTimeInterval(15 * 3600)
        criteria.lastDay = day("2026-09-21")
        XCTAssertTrue(criteria.matches(photo("a", captured: "2026-09-20 00:05"), calendar: calendar), "시작일 0시부터")
        XCTAssertTrue(criteria.matches(photo("b", captured: "2026-09-21 23:59"), calendar: calendar), "마지막 날 끝까지")
        XCTAssertFalse(criteria.matches(photo("c", captured: "2026-09-22 00:00"), calendar: calendar))
        XCTAssertFalse(criteria.matches(photo("d", captured: "2026-09-19 23:59"), calendar: calendar))
        XCTAssertFalse(criteria.matches(photo("e", captured: nil), calendar: calendar))
    }

    func testSummaryAndTolerantDecoding() throws {
        var criteria = PhotoCriteria()
        criteria.camera = "Panasonic DC-S9"
        criteria.minimumFocalLength = 20
        criteria.maximumFocalLength = 35.5
        criteria.maximumISO = 800
        criteria.flag = .pick
        criteria.firstDay = day("2026-09-20")
        XCTAssertEqual(criteria.summary(calendar: calendar),
                       ["선택됨", "Panasonic DC-S9", "20–35.5mm", "ISO ~800", "2026-09-20~"])
        XCTAssertEqual(try JSONDecoder().decode(PhotoCriteria.self, from: Data("{}".utf8)), PhotoCriteria())
        XCTAssertEqual(try JSONDecoder().decode(PhotoCriteria.self, from: JSONEncoder().encode(criteria)), criteria)
    }

    func testSmartFolderStoreRoundTripAndValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SmartFolderStore(url: directory.appendingPathComponent("smart-folders.json"))
        XCTAssertEqual(try store.load(), [], "파일이 없으면 빈 목록")
        var criteria = PhotoCriteria()
        criteria.lens = "LUMIX S 18mm"
        let folders = [SmartFolder(name: "  18mm  ", criteria: criteria)]
        try store.save(folders)
        XCTAssertEqual(try store.load().first?.name, "18mm")
        XCTAssertEqual(try store.load().first?.criteria, criteria)
        XCTAssertThrowsError(try store.save(folders + [SmartFolder(name: "18MM", criteria: criteria)]))
        XCTAssertThrowsError(try store.save([SmartFolder(name: "   ", criteria: criteria)]))
    }

    func testMetadataReadsFocalLength() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFocalLength: 35]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(try ImagePipeline().metadata(for: url).focalLength, 35)
    }
}
