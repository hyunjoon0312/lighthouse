import Foundation
import XCTest
@testable import LighthouseCore

final class ColorLabelTests: XCTestCase {
    func testLabelIsStoredOnlyWhenSetAndTravelsWithMarks() throws {
        var photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(photo), as: UTF8.self).contains("colorLabel"),
                       "라벨이 없으면 카탈로그에 쓰지 않는다")
        photo.colorLabel = .green
        let decoded = try JSONDecoder().decode(PhotoAsset.self, from: JSONEncoder().encode(photo))
        XCTAssertEqual(decoded.colorLabel, .green)
        XCTAssertEqual(decoded.marks.colorLabel, .green)
        var marks = decoded.marks
        marks.colorLabel = nil
        photo.marks = marks
        XCTAssertNil(photo.colorLabel)
    }

    func testKeysNamesAndCriteria() {
        XCTAssertEqual(["6", "7", "8", "9", "5"].map(PhotoColorLabel.forKey), [.red, .yellow, .green, .blue, nil])
        XCTAssertEqual(PhotoColorLabel.allCases.map(\.xmpName), ["Red", "Yellow", "Green", "Blue", "Purple"])
        var labelled = PhotoAsset(url: URL(fileURLWithPath: "/photos/P2.RW2"))
        labelled.colorLabel = .blue
        var criteria = PhotoCriteria()
        criteria.colorLabel = .blue
        XCTAssertTrue(criteria.matches(labelled))
        XCTAssertFalse(criteria.matches(PhotoAsset(url: URL(fileURLWithPath: "/photos/P3.RW2"))))
        XCTAssertEqual(criteria.summary(), ["파랑 라벨"])
    }
}
