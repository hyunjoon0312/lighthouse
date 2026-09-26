import AppKit
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 화면 맞춤에서 100%로 바꿀 때 원본 크기 렌더를 기다리는 동안 사진이 사라지지 않는다.
@MainActor
final class ActualSizeTests: XCTestCase {
    func testEnteringActualSizeShowsTheEnlargedPhotoUntilTheFullRenderArrives() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let url = root.appendingPathComponent("photos/large.jpg")
        try TestSupport.writeJPEG(url, width: 3000, height: 2000)
        model.importURLs([url])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 1 }
        model.focusPhoto(model.photos[0])
        model.updateEdits({ var edits = model.selection!.edits; edits.rotationQuarterTurns = 1; return edits }())
        model.setMode(.edit)
        try await TestSupport.wait("fit") { !model.rendering && model.rendered != nil }
        let fit = try XCTUnwrap(model.rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(fit.width, 1466, "화면 맞춤은 긴 변 2200px")

        model.toggleActualSize(at: CGPoint(x: 0.3, y: 0.4))
        let enlarged = try XCTUnwrap(model.rendered, "100%로 바꾼 즉시 사진이 사라지지 않는다")
        XCTAssertEqual(enlarged.size, CGSize(width: 2000, height: 3000), "회전을 반영한 원본 크기로 늘려 보인다")
        XCTAssertEqual(enlarged.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, fit.width)
        XCTAssertTrue(model.rendering)

        try await TestSupport.wait("full") { !model.rendering }
        let full = try XCTUnwrap(model.rendered)
        XCTAssertEqual(full.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 2000)
        XCTAssertEqual(full.size, enlarged.size, "선명한 그림으로 바뀌어도 크기가 같아 스크롤 위치가 그대로다")

        model.toggleActualSize()
        XCTAssertNotNil(model.rendered, "화면 맞춤으로 돌아올 때는 최근 그림을 바로 쓴다")
    }
}
