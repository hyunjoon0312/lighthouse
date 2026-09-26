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
