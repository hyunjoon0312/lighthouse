import Foundation
import XCTest
@testable import LighthouseCore

final class PhotoCopierTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDateFolderLayout() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 23, minute: 30))!
        let root = URL(fileURLWithPath: "/Photos", isDirectory: true)
        XCTAssertEqual(PhotoCopier.folder(for: date, in: root, organizeByDate: true, calendar: calendar).path,
                       "/Photos/2026/2026-09-05")
        XCTAssertEqual(PhotoCopier.folder(for: nil, in: root, organizeByDate: true).path, "/Photos")
        XCTAssertEqual(PhotoCopier.folder(for: date, in: root, organizeByDate: false).path, "/Photos")
    }

    func testCopyKeepsSourceSkipsIdenticalAndRenamesDifferent() throws {
        let card = try temporaryDirectory()
        let library = try temporaryDirectory().appendingPathComponent("2026/2026-09-05", isDirectory: true)
        let source = card.appendingPathComponent("P1000001.RW2")
        let original = Data((0..<200_000).map { UInt8($0 % 251) })
        try original.write(to: source)

        let first = try PhotoCopier.copy(source, into: library)
        XCTAssertEqual(first, .copied(library.appendingPathComponent("P1000001.RW2")))
        XCTAssertEqual(try Data(contentsOf: first.url), original)
        XCTAssertEqual(try Data(contentsOf: source), original)

        let again = try PhotoCopier.copy(source, into: library)
        XCTAssertEqual(again, .alreadyPresent(first.url))

        let otherCard = try temporaryDirectory()
        let different = otherCard.appendingPathComponent("P1000001.RW2")
        try Data(original.reversed()).write(to: different)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)],
                                              ofItemAtPath: different.path)
        let renamed = try PhotoCopier.copy(different, into: library)
        XCTAssertEqual(renamed, .copied(library.appendingPathComponent("P1000001-2.RW2")))
        XCTAssertEqual(try Data(contentsOf: first.url), original)
        XCTAssertEqual(try PhotoCopier.copy(different, into: library), .alreadyPresent(renamed.url))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.path)
            .filter { $0.hasSuffix(".lighthouse-part") }
        XCTAssertEqual(leftovers, [])
        XCTAssertThrowsError(try PhotoCopier.copy(card.appendingPathComponent("missing.RW2"), into: library))
    }

    func testSameSizeAndModificationTimeCountsAsCopiedWithoutReading() throws {
        let card = try temporaryDirectory()
        let library = try temporaryDirectory()
        let source = card.appendingPathComponent("P1000002.RW2")
        try Data(repeating: 7, count: 50_000).write(to: source)
        let taken = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: taken], ofItemAtPath: source.path)
        let copied = try PhotoCopier.copy(source, into: library)
        let copiedDate = try FileManager.default.attributesOfItem(atPath: copied.url.path)[.modificationDate] as? Date
        XCTAssertEqual(copiedDate, taken, "복사는 수정 시각을 옮긴다")

        // 크기와 수정 시각이 같으면 내용을 읽지 않고 같은 파일로 본다(카메라 파일은 찍은 뒤 바뀌지 않는다).
        try Data(repeating: 9, count: 50_000).write(to: copied.url)
        try FileManager.default.setAttributes([.modificationDate: taken], ofItemAtPath: copied.url.path)
        XCTAssertEqual(try PhotoCopier.copy(source, into: library), .alreadyPresent(copied.url))

        // 수정 시각이 다르면 내용을 비교해 다른 파일로 복사한다.
        try FileManager.default.setAttributes([.modificationDate: taken.addingTimeInterval(1)], ofItemAtPath: copied.url.path)
        XCTAssertEqual(try PhotoCopier.copy(source, into: library),
                       .copied(library.appendingPathComponent("P1000002-2.RW2")))
    }
}
