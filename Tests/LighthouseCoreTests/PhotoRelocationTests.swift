import XCTest
@testable import LighthouseCore

final class PhotoRelocationTests: XCTestCase {
    func testFindsFileInChosenFolderOrUnderAParent() {
        let existing: Set<String> = ["/Volumes/New/Trip/Day1/P1.RW2", "/Volumes/New/Trip/Day2/P9.RW2"]
        let exists = { existing.contains($0) }

        let direct = PhotoRelocation.mapping(for: "/Volumes/Old/Trip/Day1/P1.RW2", in: "/Volumes/New/Trip/Day1", fileExists: exists)
        XCTAssertEqual(direct?.from, "/Volumes/Old/Trip/Day1")
        XCTAssertEqual(direct?.to, "/Volumes/New/Trip/Day1")

        let parent = PhotoRelocation.mapping(for: "/Volumes/Old/Trip/Day1/P1.RW2", in: "/Volumes/New/Trip", fileExists: exists)
        XCTAssertEqual(parent?.from, "/Volumes/Old/Trip")
        XCTAssertEqual(parent?.to, "/Volumes/New/Trip")
        XCTAssertEqual(PhotoRelocation.relocated("/Volumes/Old/Trip/Day2/P9.RW2", from: parent!.from, to: parent!.to),
                       "/Volumes/New/Trip/Day2/P9.RW2", "같은 옛 폴더 아래의 다른 날짜 폴더도 따라간다")
        XCTAssertNil(PhotoRelocation.mapping(for: "/Volumes/Old/Trip/Day1/P2.RW2", in: "/Volumes/New/Trip", fileExists: exists))
    }

    func testRelocatesOnlyPathsUnderTheOldPrefix() {
        XCTAssertNil(PhotoRelocation.relocated("/Volumes/Old/Tripod/P1.RW2", from: "/Volumes/Old/Trip", to: "/New"),
                     "이름이 비슷한 형제 폴더는 대응하지 않는다")
        XCTAssertEqual(PhotoRelocation.relocated("/a/b.jpg", from: "/", to: "/Volumes/X"), "/Volumes/X/a/b.jpg")
    }
}
