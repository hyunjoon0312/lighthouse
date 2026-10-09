import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LighthouseCore

final class ColorGradingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let sample = ColorGrading(
        shadows: ColorGradeZone(hue: 220, saturation: 0.4, luminance: -0.2),
        global: ColorGradeZone(hue: 30, saturation: 0.1),
        blending: 0.7, balance: -0.3
    )

    // MARK: 모델·저장

    func testColorGradingDefaultsOmitKeyRoundTripsAndRejectsInvalidValues() throws {
        var object = try jsonObject(EditSettings())
        XCTAssertNil(object["colorGrading"], "중립이면 키를 쓰지 않는다")
        XCTAssertEqual(try decode(object).colorGrading, .neutral)

        let edits = EditSettings(colorGrading: sample)
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edits)), edits)
        XCTAssertTrue(edits.isModified)

        let blendOnly = EditSettings(colorGrading: ColorGrading(blending: 0.8))
        XCTAssertTrue(blendOnly.colorGrading.isNeutral, "혼합만으로는 효과가 없다")
        XCTAssertNotNil(try jsonObject(blendOnly)["colorGrading"], "그래도 값은 저장한다")
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(blendOnly)), blendOnly)

        object["colorGrading"] = ["shadows": ["hue": 200]]
        let partial = try decode(object).colorGrading
        XCTAssertEqual(partial.shadows, ColorGradeZone(hue: 200))
        XCTAssertEqual(partial.midtones, ColorGradeZone())
        XCTAssertEqual(partial.blending, 0.5)
        XCTAssertEqual(partial.balance, 0)

        let invalid: [Any] = [
            NSNull(), "warm", ["blending": 1.5], ["balance": NSNull()], ["balance": -1.01],
            ["shadows": ["hue": 360]], ["shadows": ["hue": -1]], ["shadows": ["saturation": -0.1]],
            ["global": ["luminance": 2]], ["midtones": NSNull()], ["highlights": ["hue": "red"]],
        ]
        for value in invalid {
            object["colorGrading"] = value
            XCTAssertThrowsError(try decode(object), "\(value)")
        }
    }

    func testLegacyCatalogJSONReencodesIdentically() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let legacy = try encoder.encode(EditSettings(exposure: 0.3, contrast: 1.2))
        let reencoded = try encoder.encode(JSONDecoder().decode(EditSettings.self, from: legacy))
        XCTAssertEqual(reencoded, legacy, "기존 카탈로그와 썸네일 키가 바뀌지 않는다")
    }

    func testGlobalMergeCopiesGradingAndChangeSummaryNamesIt() {
        let source = EditSettings(colorGrading: sample)
        XCTAssertEqual(EditSettings().merging(from: source, components: .global).colorGrading, sample)
        XCTAssertEqual(EditSettings().merging(from: source, components: .geometry).colorGrading, .neutral)
        XCTAssertEqual(source.changeSummary(from: EditSettings()), "컬러 그레이딩")
    }

    func testRegionKeyPathsAddressEachZone() {
        var grading = ColorGrading.neutral
        for (index, region) in ColorGradeRegion.allCases.enumerated() {
            grading[keyPath: region.keyPath].hue = Double(index * 10 + 10)
        }
        XCTAssertEqual([grading.shadows.hue, grading.midtones.hue, grading.highlights.hue, grading.global.hue],
                       [10, 20, 30, 40])
    }

    // MARK: 렌더

    func testNeutralGradingIsIdentityAndSkipsCube() throws {
        let rgb = SIMD3(0.2, 0.5, 0.9)
        let quiet = ColorGrading(blending: 0.9, balance: 0.5)
        XCTAssertEqual(try AdvancedColorProcessor.transformRGB(rgb, curves: .identity, ranges: [], grading: quiet), rgb)
        let source = grayscaleRamp()
        XCTAssertIdentical(try AdvancedColorProcessor.applyColor(to: source, curves: .identity, ranges: [],
                                                                 grading: quiet), source)
    }

    func testZoneDirectionsAffectOnlyTheirTonalRange() throws {
        let shadows = ColorGrading(shadows: ColorGradeZone(hue: 220, saturation: 0.5))
        XCTAssertGreaterThan(try graded(0.1, shadows).z, try graded(0.1, shadows).x + 0.1)
        assertClose(try graded(0.9, shadows), SIMD3(repeating: 0.9), 0.001)

        let highlights = ColorGrading(highlights: ColorGradeZone(hue: 40, saturation: 0.5))
        XCTAssertGreaterThan(try graded(0.9, highlights).x, try graded(0.9, highlights).z + 0.1)
        assertClose(try graded(0.1, highlights), SIMD3(repeating: 0.1), 0.001)

        let midtones = ColorGrading(midtones: ColorGradeZone(hue: 120, saturation: 0.5))
        XCTAssertGreaterThan(try graded(0.5, midtones).y, try graded(0.5, midtones).x + 0.05)
        assertClose(try graded(0.02, midtones), SIMD3(repeating: 0.02), 0.001)
        assertClose(try graded(0.98, midtones), SIMD3(repeating: 0.98), 0.001)

        let global = ColorGrading(global: ColorGradeZone(hue: 0, saturation: 0.5))
        for gray in [0.1, 0.5, 0.9] {
            XCTAssertGreaterThan(try graded(gray, global).x, try graded(gray, global).z + 0.02, "\(gray)")
        }
    }

    func testTintPreservesLuminanceAndPureBlackWhite() throws {
        let strong = ColorGrading(
            shadows: ColorGradeZone(hue: 220, saturation: 1), midtones: ColorGradeZone(hue: 120, saturation: 1),
            highlights: ColorGradeZone(hue: 40, saturation: 1), global: ColorGradeZone(hue: 300, saturation: 1)
        )
        for gray in [0, 0.02, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0] {
            let output = try graded(gray, strong)
            XCTAssertEqual(luma(output), gray, accuracy: 1e-9, "\(gray)")
            XCTAssertTrue((0...1).contains(output.x) && (0...1).contains(output.y) && (0...1).contains(output.z))
        }
        XCTAssertEqual(try graded(0, strong), SIMD3(repeating: 0))
        XCTAssertEqual(try graded(1, strong), SIMD3(repeating: 1))
        let colored = SIMD3(0.8, 0.2, 0.1)
        let output = try AdvancedColorProcessor.transformRGB(colored, curves: .identity, ranges: [], grading: strong)
        XCTAssertEqual(luma(output), luma(colored), accuracy: 1e-9)
    }

    func testLuminanceDirectionsKeepEndpoints() throws {
        let darker = ColorGrading(shadows: ColorGradeZone(luminance: -1))
        let brighter = ColorGrading(shadows: ColorGradeZone(luminance: 1))
        XCTAssertLessThan(luma(try graded(0.1, darker)), 0.1)
        XCTAssertGreaterThan(luma(try graded(0.1, brighter)), 0.1)
        let midLift = ColorGrading(midtones: ColorGradeZone(luminance: 1))
        XCTAssertGreaterThan(luma(try graded(0.5, midLift)), 0.55)
        for grading in [darker, brighter, midLift] {
            XCTAssertEqual(try graded(0, grading), SIMD3(repeating: 0))
            XCTAssertEqual(try graded(1, grading), SIMD3(repeating: 1))
        }
    }

    func testStrongLuminanceWithHardBlendingKeepsToneOrder() throws {
        let settings = [
            ColorGrading(shadows: ColorGradeZone(luminance: 1), blending: 0),
            ColorGrading(midtones: ColorGradeZone(luminance: 1), blending: 0),
            ColorGrading(midtones: ColorGradeZone(luminance: -1), blending: 0),
            ColorGrading(highlights: ColorGradeZone(luminance: -1), blending: 0),
            ColorGrading(shadows: ColorGradeZone(luminance: 1), blending: 0, balance: -1),
        ]
        for grading in settings {
            var previous = -1.0
            for step in 0...400 {
                let output = luma(try graded(Double(step) / 400, grading))
                guard output >= previous - 1e-12 else {
                    XCTFail("밝은 입력이 더 어두워졌다: \(grading) at \(step), \(previous) → \(output)")
                    break
                }
                previous = output
            }
        }
    }

    func testBalanceAndBlendingMoveZoneBoundaries() throws {
        func shadowTint(_ gray: Double, blending: Double = 0.5, balance: Double = 0) throws -> Double {
            let output = try graded(gray, ColorGrading(shadows: ColorGradeZone(hue: 220, saturation: 0.5),
                                                       blending: blending, balance: balance))
            return output.z - output.x
        }
        let neutralBalance = try shadowTint(0.3)
        XCTAssertLessThan(try shadowTint(0.3, balance: 1), neutralBalance, "균형 +는 하이라이트 쪽을 넓힌다")
        XCTAssertGreaterThan(try shadowTint(0.3, balance: -1), neutralBalance, "균형 -는 그림자 쪽을 넓힌다")

        let hard = try shadowTint(0.5, blending: 0)
        let medium = try shadowTint(0.5, blending: 0.5)
        let soft = try shadowTint(0.5, blending: 1)
        XCTAssertEqual(hard, 0, accuracy: 1e-9, "혼합 0이면 중간 밝기에 그림자 색이 번지지 않는다")
        XCTAssertGreaterThan(medium, hard)
        XCTAssertGreaterThan(soft, medium)
    }

    func testInvalidGradingThrows() {
        let invalid = [
            ColorGrading(shadows: ColorGradeZone(hue: 360)),
            ColorGrading(global: ColorGradeZone(saturation: 1.2)),
            ColorGrading(midtones: ColorGradeZone(luminance: .nan)),
            ColorGrading(blending: -0.1),
            ColorGrading(balance: .infinity),
        ]
        for grading in invalid {
            XCTAssertThrowsError(try AdvancedColorProcessor.transformRGB(
                SIMD3(repeating: 0.5), curves: .identity, ranges: [], grading: grading
            )) { XCTAssertEqual($0 as? AdvancedColorProcessingError, .invalidColorGrading) }
            XCTAssertThrowsError(try AdvancedColorProcessor.applyColor(
                to: grayscaleRamp(), curves: .identity, ranges: [], grading: grading
            ))
        }
    }

    func testCubeMatchesPerPixelTransform() throws {
        let grading = ColorGrading(shadows: ColorGradeZone(hue: 220, saturation: 0.6, luminance: -0.3),
                                   highlights: ColorGradeZone(hue: 40, saturation: 0.5, luminance: 0.2))
        let bytes = try rgba8(AdvancedColorProcessor.applyColor(to: grayscaleRamp(), curves: .identity,
                                                                ranges: [], grading: grading))
        for (index, gray) in [0, 64, 128, 192, 255].enumerated() {
            let expected = try graded(Double(gray) / 255, grading) * 255
            XCTAssertEqual(Double(bytes[index * 4]), expected.x, accuracy: 2, "\(gray) R")
            XCTAssertEqual(Double(bytes[index * 4 + 1]), expected.y, accuracy: 2, "\(gray) G")
            XCTAssertEqual(Double(bytes[index * 4 + 2]), expected.z, accuracy: 2, "\(gray) B")
        }
    }

    func testMonochromeToningMatchesPreviewAndExport() throws {
        let url = try temporaryPNG()
        // 테스트 PNG의 두 픽셀은 흑백 변환 뒤 중간 밝기(약 0.52)이므로 중간톤 틴트로 확인한다.
        let edits = EditSettings(colorProfile: .monochrome, colorGrading: ColorGrading(
            midtones: ColorGradeZone(hue: 220, saturation: 1)
        ))
        let preview = try ImagePipeline(cachesDevelopment: true).renderPreview(url: url, edits: edits, maxPixel: nil,
                                                                               allowApproximation: true)
        let exact = try ImagePipeline().render(url: url, edits: edits, maxPixel: nil)
        XCTAssertFalse(preview.isApproximate)
        XCTAssertEqual(try rgba8(preview.image), try rgba8(exact))
        let bytes = try rgba8(exact)
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            XCTAssertGreaterThan(Int(bytes[pixel + 2]), Int(bytes[pixel]) + 5, "흑백 위에 중간톤 파랑이 보인다")
        }
    }

    // MARK: 프리셋 가져오기

    private let gradingWarning = "컬러 그레이딩은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다."

    func testImportsAllFourteenKeysFromXMPAttributes() throws {
        let preset = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Grade" crs:SplitToningShadowHue="220" crs:SplitToningShadowSaturation="40"
          crs:SplitToningHighlightHue="360" crs:SplitToningHighlightSaturation="25" crs:SplitToningBalance="-30"
          crs:ColorGradeMidtoneHue="120" crs:ColorGradeMidtoneSat="10" crs:ColorGradeShadowLum="-20"
          crs:ColorGradeMidtoneLum="5" crs:ColorGradeHighlightLum="15" crs:ColorGradeGlobalHue="30"
          crs:ColorGradeGlobalSat="8" crs:ColorGradeGlobalLum="-4" crs:ColorGradeBlending="70"/>
        """), fileName: "grade.xmp")
        let expected = ColorGrading(
            shadows: ColorGradeZone(hue: 220, saturation: 0.4, luminance: -0.2),
            midtones: ColorGradeZone(hue: 120, saturation: 0.1, luminance: 0.05),
            highlights: ColorGradeZone(hue: 0, saturation: 0.25, luminance: 0.15),
            global: ColorGradeZone(hue: 30, saturation: 0.08, luminance: -0.04),
            blending: 0.7, balance: -0.3
        )
        XCTAssertEqual(preset.applied(to: EditSettings()).colorGrading, expected)
        let payload = try XCTUnwrap(preset.lightroom)
        XCTAssertEqual(payload.scalars.count, 14)
        XCTAssertFalse(payload.warnings.contains { $0.contains("제외: SplitToning") || $0.contains("제외: ColorGrade") })
        XCTAssertTrue(payload.warnings.contains(gradingWarning))
    }

    func testImportsColorGradingFromXMPElementsAndLRTemplate() throws {
        let elements = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Grade Elements">
          <crs:SplitToningShadowHue>200</crs:SplitToningShadowHue>
          <crs:ColorGradeBlending>80</crs:ColorGradeBlending>
        </rdf:Description>
        """), fileName: "elements.xmp")
        let fromElements = elements.applied(to: EditSettings()).colorGrading
        XCTAssertEqual(fromElements.shadows.hue, 200)
        XCTAssertEqual(fromElements.blending, 0.8)

        let template = try LightroomPresetImporter.parse(data: Data("""
        s = { title = "Grade Template", type = "Develop", value = { settings = {
          SplitToningHighlightHue = 40, SplitToningHighlightSaturation = 30, ColorGradeGlobalLum = 10,
        } } }
        """.utf8), fileName: "grade.lrtemplate")
        let fromTemplate = template.applied(to: EditSettings()).colorGrading
        XCTAssertEqual(fromTemplate.highlights, ColorGradeZone(hue: 40, saturation: 0.3))
        XCTAssertEqual(fromTemplate.global.luminance, 0.1)
        XCTAssertTrue(try XCTUnwrap(template.lightroom).warnings.contains(gradingWarning))
    }

    func testColorGradingImportRejectsInvalidValuesAndKeepsUnknownKeysExcluded() throws {
        let invalid: [(String, LightroomPresetImportError)] = [
            (#"<rdf:Description crs:SplitToningShadowHue="361"/>"#, .invalidValue("SplitToningShadowHue")),
            (#"<rdf:Description crs:ColorGradeBlending="abc"/>"#, .invalidValue("ColorGradeBlending")),
            (#"<rdf:Description crs:ColorGradeShadowLum="-101"/>"#, .invalidValue("ColorGradeShadowLum")),
            (#"<rdf:Description crs:ColorGradeBlending="40"><crs:ColorGradeBlending>60</crs:ColorGradeBlending></rdf:Description>"#,
             .conflictingValue("ColorGradeBlending")),
        ]
        for (description, expected) in invalid {
            XCTAssertThrowsError(try LightroomPresetImporter.parse(data: xmp(description), fileName: "bad.xmp"),
                                 description) { XCTAssertEqual($0 as? LightroomPresetImportError, expected, description) }
        }
        let unknown = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:ColorGradeShadowHue="10" crs:Exposure2012="0.5"/>
        """), fileName: "unknown.xmp")
        let warnings = try XCTUnwrap(unknown.lightroom).warnings
        XCTAssertTrue(warnings.contains("지원하지 않아 제외: ColorGradeShadowHue"))
        XCTAssertFalse(warnings.contains(gradingWarning), "지원 키가 없으면 근사 경고를 붙이지 않는다")
    }

    func testPartialColorGradingPreservesUnspecifiedValues() {
        let target = EditSettings(colorGrading: ColorGrading(
            shadows: ColorGradeZone(hue: 10, saturation: 0.3, luminance: 0.1),
            highlights: ColorGradeZone(hue: 50, saturation: 0.2), blending: 0.8, balance: 0.2
        ))
        let hueOnly = EditPreset(name: "Hue", lightroom: LightroomPresetPayload(
            format: "xmp", scalars: ["SplitToningShadowHue": 200], curves: [:], warnings: []
        ))
        var expected = target.colorGrading
        expected.shadows.hue = 200
        XCTAssertEqual(hueOnly.applied(to: target).colorGrading, expected)

        let zeroBlend = EditPreset(name: "Zero", lightroom: LightroomPresetPayload(
            format: "xmp", scalars: ["ColorGradeBlending": 0], curves: [:], warnings: []
        ))
        XCTAssertEqual(zeroBlend.applied(to: target).colorGrading.blending, 0, "명시한 0은 적용한다")
    }

    func testNeutralSlowFilmStyleKeysLeaveGradingNeutral() throws {
        let preset = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Slow Neutral" crs:SplitToningShadowHue="0" crs:SplitToningShadowSaturation="0"
          crs:SplitToningHighlightHue="0" crs:SplitToningHighlightSaturation="0" crs:SplitToningBalance="0"
          crs:ColorGradeMidtoneHue="0" crs:ColorGradeMidtoneSat="0" crs:ColorGradeShadowLum="0"
          crs:ColorGradeMidtoneLum="0" crs:ColorGradeHighlightLum="0" crs:ColorGradeBlending="50"
          crs:ColorGradeGlobalHue="0" crs:ColorGradeGlobalSat="0" crs:ColorGradeGlobalLum="0"/>
        """), fileName: "slow.xmp")
        XCTAssertEqual(preset.applied(to: EditSettings()).colorGrading, .neutral)
    }

    // MARK: 도우미

    private func jsonObject(_ edits: EditSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edits)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> EditSettings {
        try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func graded(_ gray: Double, _ grading: ColorGrading) throws -> SIMD3<Double> {
        try AdvancedColorProcessor.transformRGB(SIMD3(repeating: gray), curves: .identity, ranges: [],
                                                grading: grading)
    }

    private func luma(_ rgb: SIMD3<Double>) -> Double {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    private func assertClose(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>, _ accuracy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    private func grayscaleRamp() -> CIImage {
        let data = Data([0, 0, 0, 255, 64, 64, 64, 255, 128, 128, 128, 255,
                         192, 192, 192, 255, 255, 255, 255, 255])
        return CIImage(bitmapData: data, bytesPerRow: 20, size: CGSize(width: 5, height: 1),
                       format: .RGBA8, colorSpace: colorSpace)
    }

    private func rgba8(_ image: CIImage) throws -> Data {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                           bounds: image.extent, format: .RGBA8, colorSpace: colorSpace)
        }
        return data
    }

    private func rgba8(_ image: CGImage) throws -> Data {
        try rgba8(CIImage(cgImage: image))
    }

    private func temporaryPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let bytes = Data([255, 32, 16, 255, 16, 128, 240, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: 8, space: colorSpace,
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
