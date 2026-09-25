import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class PhotoDescriptionTests: XCTestCase {
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

    func testExportWritesKeywordsAndCaptionToIPTC() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let jpeg = try ImagePipeline().prepareJPEG(url: url, edits: .neutral, maxPixel: nil, quality: 0.8,
                                                   keywords: ["바다", "노을"], caption: "제주 협재")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg.data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let iptc = try XCTUnwrap(properties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords] as? [String], ["바다", "노을"])
        XCTAssertEqual(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, "제주 협재")

        let bare = try ImagePipeline().prepareJPEG(url: url, edits: .neutral, maxPixel: nil, quality: 0.8)
        let bareProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(bare.data as CFData, nil)!, 0, nil)
            as? [CFString: Any]
        XCTAssertNil((bareProperties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCKeywords])
    }
}
