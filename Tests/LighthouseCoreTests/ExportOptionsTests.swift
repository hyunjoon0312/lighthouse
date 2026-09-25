import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LighthouseCore

final class ExportOptionsTests: XCTestCase {
    func testFilenameTemplateTokensAndSanitizing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 7, minute: 8, second: 9))!
        let source = URL(fileURLWithPath: "/card/P1000123.RW2")
        XCTAssertEqual(ExportOptions.baseName(template: ExportOptions.defaultFilenameTemplate, sourceURL: source,
                                              capturedAt: date, sequence: 1, calendar: calendar), "P1000123-edited")
        XCTAssertEqual(ExportOptions.baseName(template: "{날짜}_{시간}_{번호}_{원본}", sourceURL: source,
                                              capturedAt: date, sequence: 12, calendar: calendar),
                       "2026-09-05_070809_012_P1000123")
        XCTAssertEqual(ExportOptions.baseName(template: "여행/서울:{번호}", sourceURL: source, capturedAt: nil,
                                              sequence: 3), "여행-서울-003")
        XCTAssertEqual(ExportOptions.baseName(template: " .. ", sourceURL: source, capturedAt: nil, sequence: 1),
                       "P1000123")
        XCTAssertEqual(ExportOptions.baseName(template: "{날짜}", sourceURL: source, capturedAt: nil, sequence: 1),
                       "날짜없음")

        XCTAssertEqual(ExportOptions.baseName(template: ExportOptions.defaultFilenameTemplate, sourceURL: source,
                                              capturedAt: nil, sequence: 1, copyName: "사본 2"),
                       "P1000123-edited-사본2", "규칙에 {사본}이 없으면 사본 이름을 끝에 붙인다")
        XCTAssertEqual(ExportOptions.baseName(template: "{원본}{사본}_{번호}", sourceURL: source, capturedAt: nil,
                                              sequence: 4, copyName: "사본 1"), "P1000123-사본1_004")
        XCTAssertEqual(ExportOptions.baseName(template: "{원본}{사본}_{번호}", sourceURL: source, capturedAt: nil,
                                              sequence: 4), "P1000123_004", "원래 항목은 빈칸")
        let long = ExportOptions.baseName(template: String(repeating: "가", count: 150), sourceURL: source,
                                          capturedAt: nil, sequence: 1)
        XCTAssertLessThanOrEqual(long.utf8.count, 200)
        XCTAssertEqual(long, String(repeating: "가", count: 66))
    }

    func testWatermarkDrawsOnlyNearChosenCorner() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try XCTUnwrap(context.makeImage())
        let marked = try XCTUnwrap(Watermark(text: "© Rian", position: .bottomRight, size: 0.08, opacity: 1).applied(to: image))
        XCTAssertEqual(marked.width, 400)
        func brightPixels(_ image: CGImage, in rect: CGRect) -> Int {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var count = 0
            for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * image.width + x) * 4
                if bytes[i] > 200 && bytes[i + 1] > 200 { count += 1 }
            } }
            return count
        }
        let bottomRightInMemory = CGRect(x: 200, y: 200, width: 200, height: 100)
        let topLeftInMemory = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertGreaterThan(brightPixels(marked, in: bottomRightInMemory), 50)
        XCTAssertEqual(brightPixels(marked, in: topLeftInMemory), 0)
        XCTAssertEqual(Watermark(text: "  ").applied(to: image), image)
    }

    func testPreparedJPEGWithWatermarkAndTemplateName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("in.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pipeline = ImagePipeline()
        let plain = try pipeline.prepareJPEG(url: input, edits: .neutral, maxPixel: nil, quality: 0.9)
        let marked = try pipeline.prepareJPEG(url: input, edits: .neutral, maxPixel: nil, quality: 0.9,
                                              watermark: Watermark(text: "LIGHTHOUSE", size: 0.1, opacity: 1))
        XCTAssertNotEqual(plain.data, marked.data)
        let first = try pipeline.writeJPEG(marked.data, baseName: "여행-001", to: directory)
        let second = try pipeline.writeJPEG(plain.data, baseName: "여행-001", to: directory)
        XCTAssertEqual(first.lastPathComponent, "여행-001.jpg")
        XCTAssertEqual(second.lastPathComponent, "여행-001-2.jpg")
        XCTAssertEqual(try Data(contentsOf: first), marked.data)
    }

    private func writeInput(_ directory: URL) throws -> URL {
        let input = directory.appendingPathComponent("in.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<120 {
            context.setFillColor(red: CGFloat(x) / 119, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 80))
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return input
    }

    func testEachFormatWritesItsContainerDepthAndColorSpace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try writeInput(directory)
        let pipeline = ImagePipeline()
        let cases: [(ExportFormat, ExportColorSpace, String, Int, String, Int)] = [
            (.jpeg, .sRGB, "public.jpeg", 8, "sRGB IEC61966-2.1", 1),
            (.heif, .displayP3, "public.heic", 10, "Display P3", 65535),
            (.tiff16, .displayP3, "public.tiff", 16, "Display P3", 65535),
        ]
        for (format, space, type, depth, profile, exifSpace) in cases {
            let options = ExportOptions(quality: 0.8, watermark: Watermark(text: "L"), format: format, colorSpace: space)
            let prepared = try pipeline.prepareExport(url: input, edits: .neutral, options: options, keywords: ["바다"])
            let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, type)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, depth, "\(format)")
            XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, profile, "\(format)")
            XCTAssertEqual((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifColorSpace] as? Int,
                           exifSpace, "\(format)")
            XCTAssertEqual((properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCKeywords] as? [String],
                           ["바다"], "\(format)")
            XCTAssertEqual(prepared.width, 120)
            if format == .tiff16 { XCTAssertEqual(prepared.image.bitsPerPixel, 48, "TIFF는 알파 없이 RGB만 저장한다") }
            let written = try pipeline.writeExport(prepared.data, format: format, baseName: "out", to: directory)
            XCTAssertEqual(written.pathExtension, format.fileExtension)
        }
        let jpeg = try pipeline.prepareExport(url: input, edits: .neutral, options: ExportOptions(quality: 0.8))
        XCTAssertThrowsError(try pipeline.writeExport(jpeg.data, format: .tiff16, baseName: "wrong", to: directory),
                             "형식과 다른 데이터는 쓰지 않는다")
        XCTAssertEqual(try pipeline.prepareJPEG(url: input, edits: .neutral, maxPixel: nil, quality: 0.8).data, jpeg.data,
                       "기본 설정은 예전 JPEG 경로와 같은 파일을 만든다")
    }

    func testOlderSavedOptionsReadAsJPEGInSRGB() throws {
        let legacy = Data(#"{"quality":0.9,"includeLocation":true,"filenameTemplate":"{원본}","maxPixel":2048}"#.utf8)
        let options = try JSONDecoder().decode(ExportOptions.self, from: legacy)
        XCTAssertEqual(options, ExportOptions(maxPixel: 2048, quality: 0.9, includeLocation: true, filenameTemplate: "{원본}"))
        let tiff = ExportOptions(format: .tiff16, colorSpace: .displayP3)
        XCTAssertEqual(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(tiff)), tiff)
    }
}
