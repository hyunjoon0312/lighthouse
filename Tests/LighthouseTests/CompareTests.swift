import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 비교 보기에서 지금 사진을 새 기준으로 삼고 다음 사진으로 넘어간다.
@MainActor
final class CompareTests: XCTestCase {
    func testCurrentPhotoBecomesThePinAndTheNextOneIsShown() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let photos = model.visiblePhotos
        model.select(photos[0])
        model.setMode(.compare)
        XCTAssertEqual(model.pinnedID, photos[0].id)
        model.move(1)
        model.makeCurrentPinned()
        XCTAssertEqual(model.pinnedID, photos[1].id)
        XCTAssertEqual(model.selectedID, photos[2].id)
        model.makeCurrentPinned()
        XCTAssertEqual(model.pinnedID, photos[2].id, "마지막 사진이면 기준만 바뀐다")
        XCTAssertEqual(model.selectedID, photos[2].id)
    }
}
