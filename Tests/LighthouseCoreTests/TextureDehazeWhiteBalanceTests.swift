import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LighthouseCore

final class TextureDehazeWhiteBalanceTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: 모델·저장

    func testNewSettingsDefaultOmitKeysRoundTripAndRejectInvalidValues() throws {
        let object = try jsonObject(EditSettings())
        for key in ["texture", "dehaze", "whiteBalance"] {
            XCTAssertNil(object[key], "\(key)가 기본값이면 키를 쓰지 않는다")
        }
        let decoded = try decode(object)
        XCTAssertEqual(decoded.texture, 0)
        XCTAssertEqual(decoded.dehaze, 0)
        XCTAssertNil(decoded.whiteBalance)

        let edits = EditSettings(texture: 0.4, dehaze: -0.3,
                                 whiteBalance: WhiteBalanceBase(temperature: 5500, tint: 10))
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edits)), edits)
        XCTAssertTrue(edits.isModified)

        let invalid: [(String, Any)] = [
            ("texture", 1.01), ("texture", "soft"), ("dehaze", -1.5), ("dehaze", NSNull()),
            ("whiteBalance", ["temperature": 1999, "tint": 0]), ("whiteBalance", ["temperature": 5000, "tint": 151]),
            ("whiteBalance", ["temperature": 5000]), ("whiteBalance", "daylight"),
        ]
        for (key, value) in invalid {
            var broken = object
            broken[key] = value
            XCTAssertThrowsError(try decode(broken), "\(key)=\(value)")
        }
    }

    func testGlobalMergeCopiesNewSettingsAndChangeSummaryNamesThem() {
        let source = EditSettings(texture: 0.2, dehaze: 0.5, whiteBalance: WhiteBalancePreset.tungsten.base)
        let merged = EditSettings().merging(from: source, components: .global)
        XCTAssertEqual(merged.texture, 0.2)
        XCTAssertEqual(merged.dehaze, 0.5)
        XCTAssertEqual(merged.whiteBalance, WhiteBalanceBase(temperature: 2850, tint: 0))
        XCTAssertNil(EditSettings().merging(from: source, components: .geometry).whiteBalance)
        XCTAssertEqual(EditSettings(texture: 0.1).changeSummary(from: EditSettings()), "텍스처")
        XCTAssertEqual(EditSettings(dehaze: 0.1).changeSummary(from: EditSettings()), "디헤이즈")
        XCTAssertEqual(source.changeSummary(from: EditSettings(texture: 0.2, dehaze: 0.5)), "화이트밸런스")
    }

    func testWhiteBalancePresetsMatchTheirBases() {
        XCTAssertNil(WhiteBalancePreset.asShot.base)
        XCTAssertEqual(WhiteBalancePreset.daylight.base, WhiteBalanceBase(temperature: 5500, tint: 10))
        XCTAssertEqual(WhiteBalancePreset.fluorescent.base, WhiteBalanceBase(temperature: 3800, tint: 21))
        for preset in WhiteBalancePreset.allCases {
            XCTAssertEqual(WhiteBalancePreset.matching(preset.base), preset)
        }
        XCTAssertNil(WhiteBalancePreset.matching(WhiteBalanceBase(temperature: 5200, tint: 8)), "목록에 없으면 사용자 지정")

        let start = EditSettings(exposure: 0.2, temperatureShift: 300, tintShift: 4)
        let chosen = WhiteBalancePreset.shade.applied(to: start)
        XCTAssertEqual(chosen, EditSettings(exposure: 0.2, whiteBalance: WhiteBalanceBase(temperature: 7500, tint: 10)),
                       "고른 값에서 이동 없이 다시 시작한다")
        XCTAssertEqual(WhiteBalancePreset.asShot.applied(to: chosen), EditSettings(exposure: 0.2))
    }

    func testRAWNeutralUsesBaseOrAsShotPlusShiftAndClamps() {
        func neutral(_ edits: EditSettings) -> [Float] {
            let value = ImagePipeline.rawNeutral(asShotTemperature: 5000, asShotTint: 3, edits: edits)
            return [value.temperature, value.tint]
        }
        XCTAssertEqual(neutral(EditSettings()), [5000, 3])
        XCTAssertEqual(neutral(EditSettings(temperatureShift: 400, tintShift: -5)), [5400, -2])
        XCTAssertEqual(neutral(EditSettings(temperatureShift: 400, tintShift: -5,
                                            whiteBalance: WhiteBalanceBase(temperature: 2850, tint: 0))), [3250, -5])
        XCTAssertEqual(neutral(EditSettings(temperatureShift: 2500, tintShift: 100,
                                            whiteBalance: WhiteBalanceBase(temperature: 49_000, tint: 140))), [50_000, 150])
        XCTAssertEqual(neutral(EditSettings(temperatureShift: -2500,
                                            whiteBalance: WhiteBalanceBase(temperature: 2000, tint: 0))), [2000, 0])
    }

    // MARK: 렌더

    func testWhiteBalanceBaseIsIgnoredForNonRAWFiles() throws {
        let url = try temporaryPNG(width: 32, height: 32) { _, _ in SIMD3(0.6, 0.5, 0.4) }
        let plain = try rgba8(ImagePipeline().render(url: url, edits: EditSettings(), maxPixel: nil))
        let based = try rgba8(ImagePipeline().render(
            url: url, edits: EditSettings(whiteBalance: WhiteBalancePreset.tungsten.base), maxPixel: nil))
        XCTAssertEqual(plain, based)
    }

    func testPositiveDehazeDeepensHazeKeepingBlackAndWhite() throws {
        let url = try bandsPNG()
        let before = try bandColors(url, EditSettings())
        let after = try bandColors(url, EditSettings(dehaze: 1))
        XCTAssertLessThanOrEqual(maxDifference(after.black, before.black), 1.5 / 255, "검정은 그대로")
        XCTAssertLessThanOrEqual(maxDifference(after.white, before.white), 1.5 / 255, "흰색은 그대로")
        XCTAssertLessThan(luma(after.haze), luma(before.haze) - 0.05, "뿌연 밝은 곳이 짙어진다")
        XCTAssertGreaterThan(spread(after.haze), spread(before.haze) + 0.03, "색이 진해진다")
        let half = try bandColors(url, EditSettings(dehaze: 0.5))
        XCTAssertLessThan(luma(after.haze), luma(half.haze), "강도에 따라 단조롭게 짙어진다")
        XCTAssertLessThan(luma(half.haze), luma(before.haze))
    }

    func testNegativeDehazeAddsVeilAndLowersContrast() throws {
        let url = try bandsPNG()
        let before = try bandColors(url, EditSettings())
        let after = try bandColors(url, EditSettings(dehaze: -1))
        XCTAssertGreaterThan(luma(after.black), luma(before.black) + 0.1, "검정이 들뜬다")
        XCTAssertLessThan(luma(after.white), luma(before.white) - 0.03, "흰색이 내려온다")
        XCTAssertLessThan(spread(after.haze), spread(before.haze), "색이 옅어진다")
    }

    func testTextureScalesFineDetailAmplitude() throws {
        let url = try temporaryPNG(width: 1000, height: 1000) { x, _ in
            SIMD3(repeating: (x / 2).isMultiple(of: 2) ? 0.45 : 0.55)
        }
        let neutral = try stripeAmplitude(url, EditSettings())
        let stronger = try stripeAmplitude(url, EditSettings(texture: 1))
        let softer = try stripeAmplitude(url, EditSettings(texture: -1))
        XCTAssertGreaterThan(stronger, neutral * 1.15, "양수는 잔 무늬를 키운다")
        XCTAssertLessThan(softer, neutral * 0.85, "음수는 잔 무늬를 줄인다")
    }

    func testZeroAmountsKeepPixelsAndPreviewMatchesExport() throws {
        let url = try bandsPNG()
        let neutral = try rgba8(ImagePipeline().render(url: url, edits: EditSettings(), maxPixel: nil))
        let zero = try rgba8(ImagePipeline().render(url: url, edits: EditSettings(texture: 0, dehaze: 0), maxPixel: nil))
        XCTAssertEqual(zero, neutral)

        let edits = EditSettings(texture: 0.6, dehaze: 0.7)
        let preview = try ImagePipeline(cachesDevelopment: true).renderPreview(url: url, edits: edits, maxPixel: nil,
                                                                               allowApproximation: true)
        let exact = try ImagePipeline().render(url: url, edits: edits, maxPixel: nil)
        XCTAssertFalse(preview.isApproximate)
        XCTAssertEqual(try rgba8(preview.image), try rgba8(exact))
        XCTAssertNotEqual(try rgba8(exact), neutral)
    }

    // MARK: 프리셋 가져오기

    private let whiteBalanceWarning = "화이트밸런스는 macOS RAW 현상의 색온도로 근사하며 Adobe 결과와 다를 수 있습니다."

    func testImportsTextureDehazeAndWhiteBalanceFromXMPAndLRTemplate() throws {
        let xmpPreset = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Clear" crs:Texture="30" crs:Dehaze="-20" crs:WhiteBalance="Custom"
          crs:Temperature="5200" crs:Tint="+8" crs:IncrementalTemperature="12" crs:IncrementalTint="-6"/>
        """), fileName: "clear.xmp")
        let payload = try XCTUnwrap(xmpPreset.lightroom)
        XCTAssertEqual(payload.whiteBalance, "Custom")
        XCTAssertEqual(payload.scalars["Texture"], 30)
        XCTAssertFalse(payload.warnings.contains { $0.hasPrefix("지원하지 않아 제외") }, "\(payload.warnings)")
        XCTAssertTrue(payload.warnings.contains(whiteBalanceWarning))

        let raw = xmpPreset.applied(to: EditSettings(temperatureShift: 300, tintShift: 4), isRAW: true)
        XCTAssertEqual(raw.texture, 0.3, accuracy: 1e-12)
        XCTAssertEqual(raw.dehaze, -0.2, accuracy: 1e-12)
        XCTAssertEqual(raw.whiteBalance, WhiteBalanceBase(temperature: 5200, tint: 8))
        XCTAssertEqual([raw.temperatureShift, raw.tintShift], [0, 0], "RAW는 켈빈 기준값에서 다시 시작한다")

        let jpeg = xmpPreset.applied(to: EditSettings(temperatureShift: 300, tintShift: 4), isRAW: false)
        XCTAssertNil(jpeg.whiteBalance, "JPEG에는 켈빈 값을 쓰지 않는다")
        XCTAssertEqual([jpeg.temperatureShift, jpeg.tintShift], [300, -6])

        let template = try LightroomPresetImporter.parse(data: Data("""
        s = { title = "Warm", type = "Develop", value = { settings = {
            WhiteBalance = "Tungsten", Texture = -15, Dehaze = 40, IncrementalTemperature = -100,
        }, }, }
        """.utf8), fileName: "warm.lrtemplate")
        let warm = template.applied(to: EditSettings(), isRAW: true)
        XCTAssertEqual(warm.whiteBalance, WhiteBalancePreset.tungsten.base, "켈빈 값이 없으면 이름 있는 값의 기준값을 쓴다")
        XCTAssertEqual(warm.dehaze, 0.4, accuracy: 1e-12)
        XCTAssertEqual(template.applied(to: EditSettings(), isRAW: false).temperatureShift, -2500)
    }

    func testAsShotResetsAndAutoIsNotApplied() throws {
        let asShot = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Shot" crs:WhiteBalance="As Shot" crs:Texture="5"/>
        """), fileName: "shot.xmp")
        let start = EditSettings(temperatureShift: 300, tintShift: 4, whiteBalance: WhiteBalancePreset.shade.base)
        let rawShot = asShot.applied(to: start, isRAW: true)
        XCTAssertNil(rawShot.whiteBalance)
        XCTAssertEqual([rawShot.temperatureShift, rawShot.tintShift], [0, 0])
        XCTAssertEqual(asShot.applied(to: start, isRAW: false).temperatureShift, 0)

        let auto = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Auto" crs:WhiteBalance="Auto" crs:Temperature="6100" crs:Tint="2" crs:Dehaze="10"/>
        """), fileName: "auto.xmp")
        let warnings = try XCTUnwrap(auto.lightroom).warnings
        XCTAssertTrue(warnings.contains("자동 화이트밸런스는 적용하지 않습니다."), "\(warnings)")
        let rawAuto = auto.applied(to: start, isRAW: true)
        XCTAssertEqual(rawAuto.whiteBalance, start.whiteBalance)
        XCTAssertEqual(rawAuto.temperatureShift, 300)
        XCTAssertEqual(rawAuto.dehaze, 0.1, accuracy: 1e-12)

        let untouched = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Only" crs:Dehaze="10"/>
        """), fileName: "only.xmp")
        XCTAssertEqual(untouched.applied(to: start, isRAW: true).whiteBalance, start.whiteBalance, "없는 값은 유지")
        XCTAssertFalse(try XCTUnwrap(untouched.lightroom).warnings.contains(whiteBalanceWarning))
    }

    func testWhiteBalanceImportRejectsInvalidValues() throws {
        for (attributes, kind) in [
            ("crs:Temperature=\"1500\"", "Temperature"), ("crs:Tint=\"200\"", "Tint"),
            ("crs:Texture=\"101\"", "Texture"), ("crs:IncrementalTint=\"x\"", "IncrementalTint"),
        ] {
            XCTAssertThrowsError(try LightroomPresetImporter.parse(data: xmp("""
            <rdf:Description crs:Name="Bad" crs:Dehaze="5" \(attributes)/>
            """), fileName: "bad.xmp")) { error in
                XCTAssertEqual(error as? LightroomPresetImportError, .invalidValue(kind))
            }
        }
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Twice" crs:WhiteBalance="Daylight"><crs:WhiteBalance>Shade</crs:WhiteBalance></rdf:Description>
        """), fileName: "twice.xmp")) { error in
            XCTAssertEqual(error as? LightroomPresetImportError, .conflictingValue("WhiteBalance"))
        }
        let odd = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Odd" crs:WhiteBalance="Underwater" crs:Dehaze="5"/>
        """), fileName: "odd.xmp")
        let payload = try XCTUnwrap(odd.lightroom)
        XCTAssertNil(payload.whiteBalance)
        XCTAssertTrue(payload.warnings.contains("지원하지 않아 제외: WhiteBalance (Underwater)"), "\(payload.warnings)")
    }

    // MARK: 도우미

    private func jsonObject(_ edits: EditSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edits)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> EditSettings {
        try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func luma(_ rgb: SIMD3<Double>) -> Double { 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z }
    private func spread(_ rgb: SIMD3<Double>) -> Double { rgb.max() - rgb.min() }
    private func maxDifference(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        [abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)].max()!
    }

    /// 64px 폭의 세로 띠 네 개: 검정, 흰색, 뿌연 하늘색, 짙은 녹색.
    private func bandsPNG() throws -> URL {
        let bands: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.70, 0.76, 0.85), SIMD3(0.15, 0.25, 0.12)]
        return try temporaryPNG(width: 256, height: 64) { x, _ in bands[x / 64] }
    }

    private func bandColors(_ url: URL, _ edits: EditSettings)
        throws -> (black: SIMD3<Double>, white: SIMD3<Double>, haze: SIMD3<Double>) {
        let bytes = try rgba8(ImagePipeline().render(url: url, edits: edits, maxPixel: nil))
        func pixel(_ x: Int) -> SIMD3<Double> {
            let offset = (32 * 256 + x) * 4
            return SIMD3(Double(bytes[offset]), Double(bytes[offset + 1]), Double(bytes[offset + 2])) / 255
        }
        return (pixel(32), pixel(96), pixel(160))
    }

    private func stripeAmplitude(_ url: URL, _ edits: EditSettings) throws -> Double {
        let bytes = try rgba8(ImagePipeline().render(url: url, edits: edits, maxPixel: nil))
        var total = 0.0
        var count = 0
        for x in 400..<600 {
            let a = Int(bytes[(500 * 1000 + x) * 4 + 1]), b = Int(bytes[(500 * 1000 + x + 1) * 4 + 1])
            total += Double(abs(a - b))
            count += 1
        }
        return total / Double(count)
    }

    private func rgba8(_ image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    private func temporaryPNG(width: Int, height: Int, color: (Int, Int) -> SIMD3<Double>) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = color(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((rgb.x * 255).rounded())
                bytes[offset + 1] = UInt8((rgb.y * 255).rounded())
                bytes[offset + 2] = UInt8((rgb.z * 255).rounded())
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func xmp(_ descriptions: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            \(descriptions)
          </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }
}
