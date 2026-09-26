import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 켜 둔 동안 표시가 바뀌면 사이드카를 고쳐 쓴다.
@MainActor
final class XMPSidecarFlowTests: XCTestCase {
    func testSidecarsFollowMarksOnlyWhenEnabled() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 1)
        // 사이드카는 원본을 읽지 않으므로 RAW 항목은 이름만 있어도 된다.
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let marked = PhotoAsset(url: folder.appendingPathComponent("P1000001.RW2"))
        let plain = PhotoAsset(url: folder.appendingPathComponent("P1000002.RW2"))
        let jpeg = try XCTUnwrap(model.photos.first)
        model.photos += [marked, plain]
        let first = XMPSidecar.url(for: marked), second = XMPSidecar.url(for: plain)
        model.focusPhoto(marked)
        model.setRating(2)
        model.focusPhoto(jpeg)
        model.setRating(4)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "꺼져 있으면 쓰지 않는다")

        model.writesXMPSidecars = true
        try await TestSupport.wait("all sidecars") { FileManager.default.fileExists(atPath: first.path) }
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("xmp:Rating=\"2\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path), "표시가 없는 사진 옆에는 만들지 않는다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecar.url(for: jpeg).path), "JPEG에는 쓰지 않는다")
        model.focusPhoto(marked)
        model.setColorLabel(.green)
        try await TestSupport.wait("updated sidecar") {
            (try? String(contentsOf: first, encoding: .utf8))?.contains("xmp:Label=\"Green\"") == true
        }
        model.undo()
        try await TestSupport.wait("undone sidecar") {
            (try? String(contentsOf: first, encoding: .utf8))?.contains("xmp:Label") == false
        }
        model.focusPhoto(plain)
        model.setRating(1)
        try await TestSupport.wait("new sidecar") { FileManager.default.fileExists(atPath: second.path) }

        model.focusPhoto(marked)
        model.createVirtualCopy()
        XCTAssertEqual(Set(model.sidecarTargets(Set(model.photos.map(\.id))).map(\.id)), [marked.id, plain.id],
                       "사본과 JPEG는 빼고 RAW에만 쓴다")
        model.writesXMPSidecars = false
    }
}
