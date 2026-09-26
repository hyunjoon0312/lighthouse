import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 켜 둔 동안 표시가 바뀌면 사이드카를 고쳐 쓴다.
@MainActor
final class XMPSidecarFlowTests: XCTestCase {
    func testSidecarsFollowMarksOnlyWhenEnabled() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let photos = model.photos
        let first = XMPSidecar.url(for: photos[0]), second = XMPSidecar.url(for: photos[1])
        model.focusPhoto(photos[0])
        model.setRating(2)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "꺼져 있으면 쓰지 않는다")

        model.writesXMPSidecars = true
        try await TestSupport.wait("all sidecars") {
            FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path)
        }
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("xmp:Rating=\"2\""))
        model.setColorLabel(.green)
        try await TestSupport.wait("updated sidecar") {
            (try? String(contentsOf: first, encoding: .utf8))?.contains("xmp:Label=\"Green\"") == true
        }
        model.undo()
        try await TestSupport.wait("undone sidecar") {
            (try? String(contentsOf: first, encoding: .utf8))?.contains("xmp:Label") == false
        }

        model.createVirtualCopy()
        let raw = PhotoAsset(url: photos[1].url.deletingPathExtension().appendingPathExtension("RW2"))
        model.photos.append(raw)
        let targets = Set(model.sidecarTargets(Set(model.photos.map(\.id))).map(\.id))
        XCTAssertEqual(targets, [photos[0].id, raw.id], "사본과 RAW 짝 JPEG는 빼고 RAW에 쓴다")
        model.writesXMPSidecars = false
    }
}
