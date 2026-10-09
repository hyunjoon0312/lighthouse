import AppKit
import CryptoKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class TextureDehazeWhiteBalanceFlowTests: XCTestCase {
    func testWhiteBalanceChoiceIsOneUndoStep() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        var start = try XCTUnwrap(model.selection).edits
        start.temperatureShift = 400
        start.texture = 0.3
        model.updateEdits(start)
        model.updateEdits(WhiteBalancePreset.tungsten.applied(to: start))
        let chosen = try XCTUnwrap(model.selection).edits
        XCTAssertEqual(chosen.whiteBalance, WhiteBalancePreset.tungsten.base)
        XCTAssertEqual(chosen.temperatureShift, 0)
        XCTAssertEqual(chosen.texture, 0.3)
        model.undo()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits, start)
    }

    /// RAW와 JPEG를 함께 골라 같은 프리셋을 적용하면 RAW는 켈빈 기준값, JPEG는 이동량을 받는다.
    /// 실제 S9 RAW로 텅스텐 기준값이 주광보다 푸르게 그려지는지도 본다. 표본이 없으면 건너뛴다.
    func testPresetWhiteBalanceDiffersForRAWAndJPEGAndRendersCooler() async throws {
        guard let sample = TestSupport.rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let (model, root, urls) = try await TestSupport.startedModel(self, photos: 1)
        let raw = root.appendingPathComponent("S9-wb.RW2")
        try FileManager.default.copyItem(at: sample, to: raw)
        model.importURLs([raw])
        try await TestSupport.wait("raw import") { !model.isImporting && model.photos.count == 2 }
        let originalHashes = try (urls + [raw]).map(Self.sha256)

        let preset = try LightroomPresetImporter.parse(data: Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            <rdf:Description crs:Name="Tungsten Clear" crs:WhiteBalance="Tungsten" crs:Temperature="2850" crs:Tint="0"
              crs:IncrementalTemperature="-40" crs:Dehaze="25" crs:Texture="10"/>
          </rdf:RDF>
        </x:xmpmeta>
        """.utf8), fileName: "tungsten.xmp")
        model.selectAllVisible()
        model.applyPreset(preset)
        let rawPhoto = try XCTUnwrap(model.photos.first { $0.isRAW })
        let jpegPhoto = try XCTUnwrap(model.photos.first { !$0.isRAW })
        XCTAssertEqual(rawPhoto.edits.whiteBalance, WhiteBalanceBase(temperature: 2850, tint: 0))
        XCTAssertEqual(rawPhoto.edits.temperatureShift, 0)
        XCTAssertNil(jpegPhoto.edits.whiteBalance)
        XCTAssertEqual(jpegPhoto.edits.temperatureShift, -1000)
        XCTAssertEqual([rawPhoto.edits.dehaze, jpegPhoto.edits.dehaze], [0.25, 0.25])
        model.undo()
        XCTAssertTrue(model.photos.allSatisfy { $0.edits == EditSettings() }, "다중 적용을 한 번에 되돌린다")

        let pipeline = ImagePipeline()
        func blueRatio(_ preset: WhiteBalancePreset) throws -> Double {
            let image = try pipeline.render(url: raw, edits: preset.applied(to: EditSettings()), maxPixel: 400)
            let mean = try Self.meanRGB(image)
            return mean.z / max(mean.x, 1e-6)
        }
        let daylight = try blueRatio(.daylight)
        let tungsten = try blueRatio(.tungsten)
        XCTAssertGreaterThan(tungsten, daylight * 1.2, "낮은 켈빈 기준값은 사진을 푸르게 만든다")
        XCTAssertEqual(try (urls + [raw]).map(Self.sha256), originalHashes, "원본 bytes를 바꾸지 않는다")
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func meanRGB(_ image: CGImage) throws -> SIMD3<Double> {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = SIMD3<Double>(repeating: 0)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            total += SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2]))
        }
        return total / Double(width * height)
    }
}
