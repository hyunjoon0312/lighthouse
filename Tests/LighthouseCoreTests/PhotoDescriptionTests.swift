import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class PhotoDescriptionTests: XCTestCase {
    private func originalJPEG() throws -> (url: URL, data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCKeywords: ["원본 키워드"],
                kCGImagePropertyIPTCCaptionAbstract: "원본 설명",
                kCGImagePropertyIPTCObjectName: "보존되는 제목"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "preserved EXIF"
            ]
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, try Data(contentsOf: url))
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testKeywordsAreTrimmedAndDeduplicatedIgnoringCase() {
        XCTAssertEqual(PhotoKeywords.parse(" 풍경, Sea,  sea ,,여행\n밤;밤 "), ["풍경", "Sea", "여행", "밤"])
        XCTAssertEqual(PhotoKeywords.merge(["바다"], ["바다", "노을"]), ["바다", "노을"])
        XCTAssertEqual(PhotoKeywords.parse(String(repeating: "가", count: 80)).first?.count, PhotoKeywords.maximumLength)
        XCTAssertEqual(PhotoKeywords.parse((0..<100).map(String.init).joined(separator: ",")).count, PhotoKeywords.maximumCount)
    }

    func testCatalogKeepsDescriptionAndOmitsEmptyFields() throws {
        var described = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1.RW2"))
        described.keywords = ["바다", "노을"]
        described.caption = "제주 협재"
        let plain = PhotoAsset(url: URL(fileURLWithPath: "/photos/P2.RW2"))
        let data = try JSONEncoder().encode([described, plain])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\"keywords\"").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "\"caption\"").count - 1, 1)
        XCTAssertEqual(try JSONDecoder().decode([PhotoAsset].self, from: data), [described, plain])
        XCTAssertEqual(described.marks, PhotoMarks(rating: 0, flag: .none, keywords: ["바다", "노을"], caption: "제주 협재"))
    }

    func testExportTreatsKeywordsAndCaptionAsAuthoritative() throws {
        let original = try originalJPEG()
        let originalProperties = try properties(of: original.data)
        XCTAssertEqual((originalProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[
            kCGImagePropertyExifUserComment
        ] as? String, "preserved EXIF")
        let pipeline = ImagePipeline()

        let empty = try pipeline.prepareJPEG(url: original.url, edits: .neutral, maxPixel: nil, quality: 0.8)
        let emptyProperties = try properties(of: empty.data)
        let emptyIPTC = try XCTUnwrap(emptyProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        XCTAssertNil(emptyIPTC[kCGImagePropertyIPTCKeywords])
        XCTAssertNil(emptyIPTC[kCGImagePropertyIPTCCaptionAbstract])
        XCTAssertEqual(emptyIPTC[kCGImagePropertyIPTCObjectName] as? String, "보존되는 제목")
        XCTAssertEqual((emptyProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[
            kCGImagePropertyExifUserComment
        ] as? String, "preserved EXIF")

        let captionOnly = try pipeline.prepareJPEG(url: original.url, edits: .neutral, maxPixel: nil, quality: 0.8,
                                                   keywords: [], caption: "새 설명")
        let captionIPTC = try XCTUnwrap(try properties(of: captionOnly.data)[kCGImagePropertyIPTCDictionary]
            as? [CFString: Any])
        XCTAssertNil(captionIPTC[kCGImagePropertyIPTCKeywords])
        XCTAssertEqual(captionIPTC[kCGImagePropertyIPTCCaptionAbstract] as? String, "새 설명")

        let keywordsOnly = try pipeline.prepareJPEG(url: original.url, edits: .neutral, maxPixel: nil, quality: 0.8,
                                                    keywords: ["바다", "노을"], caption: "")
        let keywordsIPTC = try XCTUnwrap(try properties(of: keywordsOnly.data)[kCGImagePropertyIPTCDictionary]
            as? [CFString: Any])
        XCTAssertEqual(keywordsIPTC[kCGImagePropertyIPTCKeywords] as? [String], ["바다", "노을"])
        XCTAssertNil(keywordsIPTC[kCGImagePropertyIPTCCaptionAbstract])

        let replaced = try pipeline.prepareJPEG(url: original.url, edits: .neutral, maxPixel: nil, quality: 0.8,
                                                keywords: ["여행"], caption: "새 캡션")
        let replacedIPTC = try XCTUnwrap(try properties(of: replaced.data)[kCGImagePropertyIPTCDictionary]
            as? [CFString: Any])
        XCTAssertEqual(replacedIPTC[kCGImagePropertyIPTCKeywords] as? [String], ["여행"])
        XCTAssertEqual(replacedIPTC[kCGImagePropertyIPTCCaptionAbstract] as? String, "새 캡션")
        XCTAssertEqual(try Data(contentsOf: original.url), original.data)
    }
}
