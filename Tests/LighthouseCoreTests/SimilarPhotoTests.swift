import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class SimilarPhotoTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeImage(to url: URL, type: UTType, variant: Int = 0, solid: Bool = false) throws {
        let width = 96, height = 64
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = solid ? 120 : UInt8((x * 2 + y * 3 + variant * ((x / 16) % 2)) % 256)
                if variant == 90 {
                    pixels[offset] = 255 - UInt8((x * 2 + y * 3) % 256)
                    pixels[offset + 1] = (x / 8 + y / 8) % 2 == 0 ? 20 : 230
                    pixels[offset + 2] = 255 - UInt8((x + y * 4) % 256)
                } else {
                    pixels[offset] = value
                    pixels[offset + 1] = solid ? value : UInt8((x * 3 + y + variant) % 256)
                    pixels[offset + 2] = solid ? value : UInt8((x + y * 4 + variant) % 256)
                }
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4,
                                              space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.82 }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testExactDifferentNamesAndVirtualCopiesAreGroupedOnce() throws {
        let root = try temporaryDirectory()
        let firstURL = root.appendingPathComponent("first.png")
        let secondURL = root.appendingPathComponent("second.png")
        try writeImage(to: firstURL, type: .png)
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        let first = PhotoAsset(url: firstURL), second = PhotoAsset(url: secondURL)
        let copy = first.virtualCopy(among: [first])

        let result = try SimilarPhotoFinder.analyze(photos: [copy, second, first], pipeline: ImagePipeline())
        let group = try XCTUnwrap(result.groups.first { $0.kind == .exact })
        XCTAssertEqual(Set(group.photoIDs), [first.id, second.id])
        XCTAssertFalse(group.photoIDs.contains(copy.id))
        let again = try SimilarPhotoFinder.analyze(photos: [second, first], pipeline: ImagePipeline())
        XCTAssertEqual(again.groups.first { $0.kind == .exact }?.id, group.id)
    }

    func testRecompressedImageIsSimilarAndUnrelatedOrSolidImagesAreExcluded() throws {
        let root = try temporaryDirectory()
        let png = root.appendingPathComponent("source.png")
        let jpeg = root.appendingPathComponent("source.jpg")
        let other = root.appendingPathComponent("other.png")
        let solidA = root.appendingPathComponent("solid-a.png")
        let solidB = root.appendingPathComponent("solid-b.png")
        try writeImage(to: png, type: .png)
        try writeImage(to: jpeg, type: .jpeg)
        try writeImage(to: other, type: .png, variant: 90)
        try writeImage(to: solidA, type: .png, solid: true)
        try writeImage(to: solidB, type: .png, solid: true)
        let photos = [png, jpeg, other, solidA, solidB].map { PhotoAsset(url: $0) }

        let result = try SimilarPhotoFinder.analyze(photos: photos, pipeline: ImagePipeline())
        let group = try XCTUnwrap(result.groups.first { $0.kind == .similar })
        XCTAssertEqual(Set(group.photoIDs), Set(photos.prefix(2).map(\.id)))
        XCTAssertFalse(result.groups.contains { $0.kind == .similar && Set($0.photoIDs).contains(photos[3].id) })
        XCTAssertFalse(result.groups.contains { $0.kind == .similar && Set($0.photoIDs).contains(photos[4].id) })
    }

    func testImageDecodeFailuresDoNotHideExactMatches() throws {
        let root = try temporaryDirectory()
        let a = root.appendingPathComponent("a.bin"), b = root.appendingPathComponent("b.bin")
        try Data(repeating: 7, count: 4096).write(to: a)
        try Data(repeating: 7, count: 4096).write(to: b)
        let photos = [PhotoAsset(url: a), PhotoAsset(url: b)]
        let result = try SimilarPhotoFinder.analyze(photos: photos, pipeline: ImagePipeline())
        XCTAssertEqual(Set(try XCTUnwrap(result.groups.first { $0.kind == .exact }).photoIDs), Set(photos.map(\.id)))
        XCTAssertEqual(result.failures.count, 2)
    }

    func testCancellationIsReportedWithoutAutomaticGrouping() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("image.png")
        try writeImage(to: url, type: .png)
        let result = try SimilarPhotoFinder.analyze(photos: [PhotoAsset(url: url)], pipeline: ImagePipeline(),
                                                    isCancelled: { true })
        XCTAssertTrue(result.isCancelled)
        XCTAssertTrue(result.groups.isEmpty)
    }
}
