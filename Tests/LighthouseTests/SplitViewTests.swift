import AppKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 보정 전·후 나눠 보기.
@MainActor
final class SplitViewTests: XCTestCase {
    private func meanBrightness(_ image: NSImage) -> Double {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<64).map { Double(bytes[$0 * 4]) + Double(bytes[$0 * 4 + 1]) + Double(bytes[$0 * 4 + 2]) }
            .reduce(0, +) / 192
    }

    func testBeforeImageKeepsGeometryAndIgnoresToneChanges() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let photo = model.photos[0]
        model.focusPhoto(photo)
        var edits = photo.edits
        edits.exposure = 1.5
        edits.rotationQuarterTurns = 1
        model.updateEdits(edits)
        model.toggleSplit()
        XCTAssertEqual(model.mode, .edit)
        XCTAssertTrue(model.isSplitActive)
        try await TestSupport.wait("split before") { model.splitBefore != nil && !model.rendering && model.rendered != nil }
        let before = try XCTUnwrap(model.splitBefore)
        let after = try XCTUnwrap(model.rendered)
        XCTAssertEqual(before.size, after.size, "구도가 같아 겹친다")
        XCTAssertLessThan(before.size.width, before.size.height, "회전은 보정 전에도 적용한다")
        XCTAssertGreaterThan(meanBrightness(after), meanBrightness(before) + 20, "노출은 보정 후에만")

        edits.exposure = 0.5
        model.updateEdits(edits)
        XCTAssertTrue(model.splitBefore === before, "구도 밖의 보정은 보정 전 모습을 다시 그리지 않는다")
        edits.rotationQuarterTurns = 0
        model.updateEdits(edits)
        try await TestSupport.wait("rotated back") { (model.splitBefore?.size.width ?? 0) > (model.splitBefore?.size.height ?? 1) }

        model.toggleOriginal()
        XCTAssertFalse(model.isSplitActive, "원본 보기에서는 나누지 않는다")
        XCTAssertNil(model.splitBefore)
        model.toggleOriginal()
        model.toggleSplit()
        XCTAssertFalse(model.showsSplit)
    }
}
