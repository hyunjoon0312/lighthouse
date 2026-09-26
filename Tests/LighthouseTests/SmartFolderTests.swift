import Foundation
import ImageIO
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 촬영 정보 조건, 스마트 폴더, 예전 카탈로그의 초점거리 채우기.
@MainActor
final class SmartFolderTests: XCTestCase {
    private static let lenses = ["LUMIX S 18mm", "LUMIX S 20-60mm", "LUMIX S 20-60mm", "LUMIX S 50mm"]
    private static let focals = [18.0, 24, 60, 50]

    func testCriteriaSmartFoldersAndFocalBackfill() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 4) { index in
            [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: Self.lenses[index],
                                              kCGImagePropertyExifFocalLength: Self.focals[index],
                                              kCGImagePropertyExifISOSpeedRatings: [100 * (index + 1)]],
             kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Panasonic",
                                              kCGImagePropertyTIFFModel: index == 3 ? "DC-S5" : "DC-S9"]]
        }
        XCTAssertEqual(model.photos.map(\.metadata.focalLength), Self.focals)
        XCTAssertEqual(model.cameraChoices, ["Panasonic DC-S5", "Panasonic DC-S9"])

        model.criteria.lens = "LUMIX S 20-60mm"
        XCTAssertEqual(model.visiblePhotos.count, 2)
        model.criteria.maximumFocalLength = 35
        XCTAssertEqual(model.visiblePhotos.map(\.metadata.focalLength), [24])
        model.criteria = PhotoCriteria()
        model.criteria.camera = "Panasonic DC-S9"
        model.criteria.minimumISO = 200
        model.setRatingForTest(on: model.photos[2], 3)
        model.minimumRating = 2
        XCTAssertEqual(model.visiblePhotos.map(\.id), [model.photos[2].id])

        XCTAssertNil(model.saveSmartFolder(name: "S9 고감도"))
        let folder = try XCTUnwrap(model.smartFolders.first)
        XCTAssertEqual(model.filter, .smart(folder.id))
        XCTAssertTrue(model.criteria.isEmpty && model.minimumRating == 0, "걸었던 조건은 폴더로 옮겨 간다")
        XCTAssertEqual(model.visiblePhotos.map(\.id), [model.photos[2].id], "저장한 뒤에도 같은 사진")
        XCTAssertEqual(model.counts.smart[folder.id], 1)
        XCTAssertNotNil(model.saveSmartFolder(name: "빈 조건"), "조건이 없으면 저장하지 않는다")
        model.criteria.lens = "LUMIX S 50mm"
        XCTAssertNotNil(model.saveSmartFolder(name: "s9 고감도"), "대소문자만 다른 이름은 거부")
        model.criteria = PhotoCriteria()
        model.filter = .all
        model.setRatingForTest(on: model.photos[1], 5)
        XCTAssertEqual(model.counts.smart[folder.id], 2, "조건에 새로 맞는 사진이 자동으로 들어온다")

        // 다시 열어도 스마트 폴더가 남고, 초점거리를 모르던 예전 카탈로그는 원본에서 채운다.
        try model.flushSave()
        let catalogURL = root.appendingPathComponent("data/catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        json["photos"] = (json["photos"] as! [[String: Any]]).map { entry in
            var entry = entry
            var metadata = entry["metadata"] as! [String: Any]
            metadata.removeValue(forKey: "focalLength")
            entry["metadata"] = metadata
            return entry
        }
        try JSONSerialization.data(withJSONObject: json).write(to: catalogURL)
        let restarted = LibraryModel()
        restarted.start()
        try await TestSupport.wait("restart") { restarted.catalogLoaded }
        XCTAssertEqual(restarted.smartFolders.map(\.name), ["S9 고감도"])
        try await TestSupport.wait("focal backfill") { restarted.photos.map(\.metadata.focalLength) == Self.focals }
        restarted.filter = .smart(folder.id)
        XCTAssertEqual(restarted.visiblePhotos.count, 2)
        XCTAssertNil(restarted.renameSmartFolder(folder.id, to: "S9"))
        restarted.deleteSmartFolder(folder.id)
        XCTAssertEqual(restarted.filter, .all)
        XCTAssertTrue(try SmartFolderStore(url: SmartFolderStore.defaultURL).load().isEmpty)
    }
}

extension LibraryModel {
    func setRatingForTest(on photo: PhotoAsset, _ rating: Int) {
        focusPhoto(photo)
        setRating(rating)
    }
}
