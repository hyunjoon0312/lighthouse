import AppKit
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 사진 보기의 얼굴 확대: 사진을 고르면 얼굴을 모으고, 얼굴을 누르면 보정 구도(회전·크롭)를 거친 그 자리를 100%로 보인다.
@MainActor
final class FaceCloseupFlowTests: XCTestCase {
    /// 얼굴이 없는 사진은 빈 결과라 줄을 보이지 않고, 끄면 결과를 지운다.
    func testPhotosWithoutFacesShowNothingAndTurningOffClears() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        model.select(model.visiblePhotos[0])
        model.setMode(.edit)
        XCTAssertTrue(model.showsFaceCloseups, "기본으로 켜져 있다")
        model.refreshFaceCloseups()
        try await TestSupport.wait("closeups") { model.faceCloseups?.path == model.selection?.path }
        XCTAssertEqual(model.faceCloseups?.faces, [])
        model.showsFaceCloseups = false
        XCTAssertNil(model.faceCloseups)
        model.refreshFaceCloseups()
        XCTAssertNil(model.faceCloseups, "꺼져 있으면 분석하지 않는다")
    }

    /// 얼굴을 누르면 그 얼굴 가운데를 100%로 보이고, 이미 100%면 끄지 않고 그 자리로 옮긴다.
    /// 크롭한 사진은 크롭 안의 위치로 바꾼다.
    func testShowingAFaceZoomsToItThroughTheCrop() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        model.select(model.visiblePhotos[0])
        model.setMode(.edit)
        let photo = try XCTUnwrap(model.selection)
        model.faceCloseups = FaceCloseupResult(
            path: photo.path, imageSize: CGSize(width: 64, height: 48),
            faces: [FaceCloseup(bounds: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2), eyesClosed: false, sharpness: 100)],
            crops: [NSImage(size: NSSize(width: 10, height: 10))], softFaces: [])
        model.showFace(0)
        XCTAssertTrue(model.actualSize)
        XCTAssertEqual(model.zoomAnchor.x, 0.7, accuracy: 0.001)
        XCTAssertEqual(model.zoomAnchor.y, 0.3, accuracy: 0.001)

        var edits = photo.edits
        edits.cropRect = NormalizedCrop(x: 0.5, y: 0, width: 0.5, height: 1)
        model.updateEdits(edits)
        let request = model.zoomRequest
        model.showFace(0)
        XCTAssertTrue(model.actualSize, "이미 100%면 끄지 않는다")
        XCTAssertEqual(model.zoomAnchor.x, 0.4, accuracy: 0.001, "오른쪽 절반 크롭 안에서 얼굴 가운데(0.7)는 0.4")
        XCTAssertEqual(model.zoomRequest, request + 1, "보기에 그 자리로 옮기라고 알린다")
    }

    /// 실제 얼굴 표본(`LIGHTHOUSE_FACE_FIXTURES`): 두 사람 사진에서 얼굴 둘을 모으고 얼굴마다 확대 그림을 자른다.
    func testFixtureFacesAreCollectedWithCrops() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTHOUSE_FACE_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("LIGHTHOUSE_FACE_FIXTURES를 지정하면 로컬 얼굴 표본을 검사합니다.")
        }
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let url = root.appendingPathComponent("photos/two-people.jpg")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path).appendingPathComponent("two-people.jpg"), to: url)
        model.importURLs([url])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 1 }
        model.select(model.visiblePhotos[0])
        model.setMode(.edit)
        model.refreshFaceCloseups()
        try await TestSupport.wait("closeups", timeout: 20) { model.faceCloseups?.path == url.path }
        let result = try XCTUnwrap(model.faceCloseups)
        XCTAssertEqual(result.faces.count, 2)
        XCTAssertEqual(result.crops.count, 2)
        XCTAssertTrue(result.crops.allSatisfy { $0.size.width >= 100 && $0.size.width == $0.size.height }, "정사각형 확대 그림")
        XCTAssertTrue(result.crops.allSatisfy { $0.size.width <= 224 }, "112pt 칸에 맞춰 줄여 기억한다(큰 얼굴도 수 MB가 되지 않게)")
        XCTAssertEqual(result.softFaces, [])
        XCTAssertEqual(result.faces.map(\.eyesClosed), [false, false])
    }
}
