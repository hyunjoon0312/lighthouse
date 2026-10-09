import AppKit
import CryptoKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class CameraProfileFlowTests: XCTestCase {
    func testCalibrationDragIsOneUndoStep() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let start = try XCTUnwrap(model.selection).edits
        for value in [0.1, 0.2, 0.35] {
            var next = try XCTUnwrap(model.selection).edits
            next.calibration.blueSaturation = value
            model.updateEdits(next, continuous: true)
        }
        model.endContinuousEdit()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits.calibration.blueSaturation, 0.35)
        model.undo()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits, start)
    }

    /// 실제 S9 RAW에 설치된 DCP를 고르고 그려 본다. 표본이나 DCP가 없으면 건너뛴다.
    func testChoosingInstalledProfileRendersAndUndoes() async throws {
        guard let sample = TestSupport.rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let raw = root.appendingPathComponent("S9-profile.RW2")
        try FileManager.default.copyItem(at: sample, to: raw)
        let originalHash = SHA256.hash(data: try Data(contentsOf: raw)).description
        model.importURLs([raw])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 1 }
        guard model.pipeline.cameraProfileNames(for: raw).contains("Camera Vivid") else {
            throw XCTSkip("이 Mac에 S9용 Adobe DCP가 없습니다.")
        }
        model.focusPhoto(model.photos[0])
        model.setMode(.edit)
        try await TestSupport.wait("first render") { !model.rendering && model.rendered != nil }
        let before = model.rendered?.tiffRepresentation
        var edits = model.photos[0].edits
        edits.cameraProfile = "Camera Vivid"
        model.updateEdits(edits)
        try await TestSupport.wait("profile render") {
            !model.rendering && model.rendered != nil && model.rendered?.tiffRepresentation != before
        }
        XCTAssertEqual(model.photos[0].edits.changeSummary(from: EditSettings()), "카메라 프로필")
        model.undo()
        XCTAssertNil(model.photos[0].edits.cameraProfile)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: raw)).description, originalHash, "원본 bytes를 바꾸지 않는다")
    }
}
