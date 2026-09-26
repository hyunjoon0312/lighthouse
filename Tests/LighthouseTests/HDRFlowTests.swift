import AppKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// HDR 하이라이트를 켠 RAW의 편집 미리보기와 썸네일. S9 표본이 없으면 건너뛴다.
@MainActor
final class HDRFlowTests: XCTestCase {
    func testPreviewIsHDROnCapableScreenAndThumbnailStaysSDR() async throws {
        guard let sample = TestSupport.rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let raw = root.appendingPathComponent("S9-hdr.RW2")
        try FileManager.default.copyItem(at: sample, to: raw)
        model.importURLs([raw])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 1 }
        model.focusPhoto(model.photos[0])
        model.setMode(.edit)
        try await TestSupport.wait("first render") { !model.rendering && model.rendered != nil }
        var edits = model.photos[0].edits
        edits.exposure = 1.5
        edits.hdrAmount = 1
        model.updateEdits(edits)
        try await TestSupport.wait("hdr render") {
            !model.rendering && (model.rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.bitsPerComponent ?? 0) ==
                (LibraryModel.hdrDisplayAvailable ? 16 : 8)
        }
        XCTAssertNotNil(model.histogram)
        model.setMode(.grid)
        model.requestThumbnail(for: model.photos[0])
        try await TestSupport.wait("thumbnail") { model.thumbnail(for: model.photos[0]) != nil }
        let thumbnail = try XCTUnwrap(model.thumbnail(for: model.photos[0])?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(thumbnail.bitsPerComponent, 8, "썸네일은 SDR")
        print("  HDR display available: \(LibraryModel.hdrDisplayAvailable)")
    }
}
