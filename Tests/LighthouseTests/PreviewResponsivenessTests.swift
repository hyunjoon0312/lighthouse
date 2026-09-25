import AppKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 실제 S9 RW2로 편집 화면의 반응을 검사한다. 표본이 없으면 건너뛴다.
@MainActor
final class PreviewResponsivenessTests: XCTestCase {
    private var model: LibraryModel!

    override func setUp() async throws {
        try await super.setUp()
        guard let sample = TestSupport.rawSample else {
            throw XCTSkip("RAW 표본이 없습니다. LIGHTHOUSE_SAMPLE_RW2에 S9 RW2 경로를 지정하세요.")
        }
        TestSupport.resetModelDefaults()
        _ = NSApplication.shared
        let root = try TestSupport.temporaryDirectory(self)
        setenv("LIGHTHOUSE_DATA_DIR", root.appendingPathComponent("data").path, 1)
        let raw = root.appendingPathComponent("S9-copy.RW2")
        try FileManager.default.copyItem(at: sample, to: raw)
        model = LibraryModel()
        model.start()
        try await wait("catalog") { self.model.catalogLoaded }
        model.importURLs([raw])
        try await wait("import") { !self.model.isImporting && !self.model.photos.isEmpty }
        model.focusPhoto(model.photos[0])
        model.setMode(.edit)
        try await wait("first render") { !self.model.rendering && self.model.rendered != nil && self.model.imageError == nil }
    }

    private func wait(_ label: String, timeout: Double = 60, _ ready: @escaping () -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if ready() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("시간 초과: \(label)")
        throw TestSupport.Timeout(label: label)
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func shownPreview() -> CGImage {
        model.rendered!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    /// RAW 노출·색온도를 끄는 동안 근사 화면이 이어서 보이고, 놓으면 정확한 렌더와 같아진다.
    func testRAWDragShowsFramesAndSettlesExactly() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        var shownDuringDrag = 0
        var last = model.rendered
        for step in 1...20 {
            var edits = model.selection!.edits
            edits.exposure = Double(step) * 0.04
            edits.temperatureShift = Double(step) * 40
            model.updateEdits(edits, continuous: true)
            try await Task.sleep(nanoseconds: 33_000_000)
            if model.rendered !== last { shownDuringDrag += 1; last = model.rendered }
        }
        model.endContinuousEdit()
        try await wait("exact render") { !self.model.rendering }
        XCTAssertGreaterThanOrEqual(shownDuringDrag, 2, "드래그 중 새 화면이 이어서 보인다")
        let photo = model.selection!
        let exact = try ImagePipeline().renderPreview(url: photo.url, edits: photo.edits, maxPixel: 2200).image
        XCTAssertEqual(bytes(exact), bytes(shownPreview()), "놓은 뒤 화면은 정확한 렌더와 같다")
        model.undo()
        XCTAssertEqual(model.selection!.edits.exposure, 0, "드래그 한 번은 실행 취소 한 단계")
        model.redo()

        // 키보드처럼 끝 신호가 없는 변경도 잠시 뒤 정확히 다시 그린다.
        var edits = model.selection!.edits
        edits.exposure += 0.3
        model.updateEdits(edits, continuous: true)
        try await wait("approximate") { !self.model.rendering }
        try await Task.sleep(nanoseconds: 400_000_000)
        try await wait("follow-up") { !self.model.rendering }
        let exact2 = try ImagePipeline().renderPreview(url: photo.url, edits: model.selection!.edits, maxPixel: 2200).image
        XCTAssertEqual(bytes(exact2), bytes(shownPreview()), "끝 신호가 없어도 잠시 뒤 정확한 렌더로 바뀐다")
    }

    /// 그라데이션 조절점을 끄는 동안 마스크 표시가 밀리지 않고, 끝나면 최종 마스크와 같다.
    func testGradientDragMaskDoesNotLag() async throws {
        model.addGradientLocal(radial: false)
        try await wait("gradient mask") { !self.model.rendering && self.model.maskImage != nil }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        for step in 0..<30 {
            model.moveGradientHandle(.end, toDisplay: MaskPoint(x: 0.5, y: 0.45 + Double(step) * 0.01))
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        model.endContinuousEdit()
        let dragEnd = Date()
        var last = model.maskImage
        var lastChange = 0.0
        while Date().timeIntervalSince(dragEnd) < 3 {
            if model.maskImage !== last { last = model.maskImage; lastChange = Date().timeIntervalSince(dragEnd) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertLessThan(lastChange, 1.0, "드래그가 끝난 뒤 늦게 도착하는 마스크가 없다")
        let photo = model.selection!
        let expected = try ImagePipeline().renderMask(adjustment: model.selectedLocal!, sourceWidth: photo.metadata.width,
                                                      sourceHeight: photo.metadata.height, edits: photo.edits, maxPixel: 1600)
        let shown = model.maskImage!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        XCTAssertEqual(bytes(expected), bytes(shown), "보이는 마스크가 최종 조절점의 마스크와 같다")
    }
}
