import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LighthouseCore

/// RAW HDR 하이라이트. 실제 S9 RW2로 확인하며 표본이 없으면 건너뛴다.
final class HDRTests: XCTestCase {
    private var rawSample: URL? {
        if let path = ProcessInfo.processInfo.environment["LIGHTHOUSE_SAMPLE_RW2"], !path.isEmpty {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent(".artifacts/samples/LUMIX-S9.RW2")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 선형 확장 sRGB 밝기.
    private func luminance(_ image: CIImage) -> [Float] {
        let extent = image.extent.integral
        var data = [Float](repeating: 0, count: Int(extent.width * extent.height) * 4)
        CIContext().render(image, toBitmap: &data, rowBytes: Int(extent.width) * 16, bounds: extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return stride(from: 0, to: data.count, by: 4).map { 0.2126 * data[$0] + 0.7152 * data[$0 + 1] + 0.0722 * data[$0 + 2] }
    }

    func testZeroAmountIsNotWrittenSoOlderCatalogsAndThumbnailKeysStay() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var edits = EditSettings(exposure: 0.5, cropAspect: 1.5)
        XCTAssertFalse(String(decoding: try encoder.encode(edits), as: UTF8.self).contains("hdrAmount"))
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(edits)) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["exposure", "contrast", "saturation", "temperatureShift", "tintShift", "highlights", "shadows",
                              "sharpness", "rotationQuarterTurns", "cropAspect", "localAdjustments", "curves", "colorRanges",
                              "grain", "straightenDegrees", "retouchStrokes", "rawDevelop", "vibrance", "clarity", "vignette"],
                       "예전과 같은 항목(비어 있는 LUT·크롭은 쓰지 않는다)")
        edits.hdrAmount = 1.2
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: encoder.encode(edits)), edits)
    }

    /// 복제·스팟 복구한 자리는 가져온 곳의 HDR 배율을 쓴다. 지운 밝은 물체 모양으로 빛나거나 밝은 하늘에 어두운 점이 남지 않는다.
    func testRetouchedAreasTakeTheGainOfTheirSource() throws {
        guard let url = rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let pipeline = ImagePipeline(cachesDevelopment: true)
        var edits = EditSettings(exposure: 1.5)
        edits.hdrAmount = 1
        func render(_ edits: EditSettings, hdr: Bool) throws -> (values: [Float], width: Int, height: Int) {
            let image = try pipeline.renderPreview(url: url, edits: edits, maxPixel: 600, hdr: hdr).image
            return (luminance(CIImage(cgImage: image)), image.width, image.height)
        }
        let sdr = try render(edits, hdr: false), hdr = try render(edits, hdr: true)
        let width = sdr.width, height = sdr.height
        func mean(_ values: [Float], _ x: Int, _ y: Int) -> Float {
            var total: Float = 0
            for row in (y - 2)...(y + 2) { for column in (x - 2)...(x + 2) { total += values[row * width + column] } }
            return total / 25
        }
        // 배율이 가장 큰 곳(밝은 곳)과, 배율이 1인 어두운 곳.
        var bright = (x: 0, y: 0, ratio: Float(0)), dark = (x: 0, y: 0, value: Float(9))
        for y in stride(from: 10, to: height - 10, by: 3) {
            for x in stride(from: 10, to: width - 10, by: 3) {
                let ratio = mean(hdr.values, x, y) / max(0.001, mean(sdr.values, x, y))
                if ratio > bright.ratio { bright = (x, y, ratio) }
                let value = mean(sdr.values, x, y)
                if value > 0.02, value < dark.value { dark = (x, y, value) }
            }
        }
        XCTAssertGreaterThan(bright.ratio, 1.5)
        func point(_ x: Int, _ y: Int) -> MaskPoint { MaskPoint(x: Double(x) / Double(width), y: Double(y) / Double(height)) }
        func ratio(at spot: (x: Int, y: Int), stroke: RetouchStroke) throws -> Float {
            var retouched = edits
            retouched.retouchStrokes = [stroke]
            let sdr = try render(retouched, hdr: false), hdr = try render(retouched, hdr: true)
            return mean(hdr.values, spot.x, spot.y) / max(0.001, mean(sdr.values, spot.x, spot.y))
        }
        let toDark = MaskPoint(x: point(dark.x, dark.y).x - point(bright.x, bright.y).x,
                               y: point(dark.x, dark.y).y - point(bright.x, bright.y).y)
        for mode in RetouchMode.allCases {
            let covered = try ratio(at: (bright.x, bright.y),
                                    stroke: RetouchStroke(mode: mode, points: [point(bright.x, bright.y)], sourceOffset: toDark))
            XCTAssertLessThan(covered, 1.1, "\(mode): 어두운 곳으로 덮은 밝은 부분은 더 빛나지 않는다")
        }
        let fromBright = MaskPoint(x: -toDark.x, y: -toDark.y)
        let copied = try ratio(at: (dark.x, dark.y),
                               stroke: RetouchStroke(mode: .clone, points: [point(dark.x, dark.y)], sourceOffset: fromBright))
        XCTAssertGreaterThan(copied, 1.4, "밝은 곳을 복제해 온 자리는 그곳의 배율을 쓴다")
    }

    func testPreviewLiftsOnlyHighlightsAboveSDRWhite() throws {
        guard let url = rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let pipeline = ImagePipeline(cachesDevelopment: true)
        var edits = EditSettings(exposure: 1.5)
        edits.hdrAmount = 1
        let sdr = try pipeline.renderPreview(url: url, edits: edits, maxPixel: 600).image
        let hdr = try pipeline.renderPreview(url: url, edits: edits, maxPixel: 600, hdr: true).image
        XCTAssertEqual(hdr.bitsPerComponent, 16)
        XCTAssertEqual(hdr.colorSpace?.name, CGColorSpace.extendedLinearDisplayP3)
        let standard = luminance(CIImage(cgImage: sdr)), extended = luminance(CIImage(cgImage: hdr))
        XCTAssertEqual(standard.count, extended.count)
        XCTAssertGreaterThan(extended.max() ?? 0, 1.5, "밝은 부분은 SDR 흰색보다 밝다")
        let mids = zip(standard, extended).filter { $0.0 > 0.05 && $0.0 < 0.3 }.map { $0.1 / $0.0 }.sorted()
        XCTAssertEqual(Double(mids[mids.count / 2]), 1, accuracy: 0.01, "중간 톤은 그대로")

        edits.hdrAmount = 0
        XCTAssertEqual(try pipeline.renderPreview(url: url, edits: edits, maxPixel: 600, hdr: true).image.bitsPerComponent, 8,
                       "HDR을 쓰지 않으면 SDR")
        edits.hdrAmount = 1
        edits.exposure = 1.6
        let dragging = try pipeline.renderPreview(url: url, edits: edits, maxPixel: 600, allowApproximation: true, hdr: true)
        XCTAssertTrue(dragging.isApproximate)
        XCTAssertEqual(dragging.image.bitsPerComponent, 8, "슬라이더를 끄는 동안 근사로 그릴 때는 SDR")
    }

    func testExportWritesGainMapWithMetadataAndSDRBase() throws {
        guard let url = rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let pipeline = ImagePipeline()
        var edits = EditSettings(exposure: 1.5)
        edits.hdrAmount = 1
        for format in [ExportFormat.jpeg, .heif] {
            let options = ExportOptions(maxPixel: 1200, quality: 0.85, format: format)
            let start = Date()
            let hdr = try pipeline.prepareExport(url: url, edits: edits, options: options, keywords: ["바다"], caption: "HDR")
            let seconds = Date().timeIntervalSince(start)
            var plainOptions = options
            plainOptions.includesHDR = false
            let plain = try pipeline.prepareExport(url: url, edits: edits, options: plainOptions)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(hdr.data as CFData, nil))
            let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) ??
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
            XCTAssertNotNil(gainMap, "\(format) 게인 맵")
            let expanded = try XCTUnwrap(CIImage(data: hdr.data, options: [.expandToHDR: true]))
            XCTAssertGreaterThan(luminance(expanded.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))).max() ?? 0, 1.2,
                                 "\(format) HDR로 읽으면 SDR 흰색보다 밝다")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "DC-S9", "\(format) 촬영 정보")
            let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            XCTAssertEqual(iptc?[kCGImagePropertyIPTCKeywords] as? [String], ["바다"], "\(format) 키워드")
            let sdrBase = luminance(CIImage(cgImage: hdr.image)), plainBase = luminance(CIImage(cgImage: plain.image))
            XCTAssertEqual(sdrBase.count, plainBase.count)
            let difference = zip(sdrBase, plainBase).map { abs($0 - $1) }.reduce(0, +) / Float(max(1, sdrBase.count))
            XCTAssertLessThan(difference, 0.01, "\(format) HDR을 모르는 곳에서 보이는 기본 이미지는 일반 내보내기와 같다")
            print(String(format: "  %@ HDR %.0fKB (plain %.0fKB) %.2fs", format.title, Double(hdr.data.count) / 1024,
                         Double(plain.data.count) / 1024, seconds))
        }
    }
}
