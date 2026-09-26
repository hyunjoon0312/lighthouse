import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class AdvancedImagingTests: XCTestCase {
    func testBaseMaskInvertThenEraseUsesStoredPNG() throws {
        let pipeline = ImagePipeline()
        let baseImage = try makeImage(width: 20, height: 12) { x, _ in
            x < 10 ? (255, 255, 255, 255) : (0, 0, 0, 255)
        }
        let mask = RasterMask(width: 20, height: 12, pngData: try pngData(baseImage))
        let adjustment = LocalAdjustment(
            feather: 0,
            strokes: [MaskStroke(points: [MaskPoint(x: 0.75, y: 0.5)],
                                 radius: 0.12, isErasing: true)],
            baseMask: mask,
            isInverted: true
        )

        let rendered = try pipeline.renderMask(adjustment: adjustment,
                                               sourceWidth: 20, sourceHeight: 12,
                                               edits: .neutral, maxPixel: 20)
        XCTAssertLessThan(try gray(rendered, x: 3, y: 6), 10)
        XCTAssertGreaterThan(try gray(rendered, x: 19, y: 6), 245)
        XCTAssertLessThan(try gray(rendered, x: 15, y: 6), 10)
    }

    func testStoredMaskRejectsInvalidPNGAndDimensionMismatch() throws {
        let pipeline = ImagePipeline()
        let invalid = LocalAdjustment(baseMask: RasterMask(width: 2, height: 2,
                                                            pngData: Data([0, 1, 2])))
        XCTAssertThrowsError(try pipeline.renderMask(adjustment: invalid,
                                                     sourceWidth: 20, sourceHeight: 12,
                                                     edits: .neutral))

        let png = try pngData(makeImage(width: 3, height: 2) { _, _ in (255, 255, 255, 255) })
        let mismatch = LocalAdjustment(baseMask: RasterMask(width: 2, height: 2, pngData: png))
        XCTAssertThrowsError(try pipeline.renderMask(adjustment: mismatch,
                                                     sourceWidth: 20, sourceHeight: 12,
                                                     edits: .neutral))

        let input = try temporaryPNG(width: 20, height: 12) { _, _ in (80, 90, 100, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        XCTAssertThrowsError(try pipeline.render(
            url: input, edits: EditSettings(localAdjustments: [invalid]), maxPixel: nil
        ))
    }

    func testCloneCopiesRequestedSourceAndPreservesOtherPixels() throws {
        let input = try temporaryPNG(width: 64, height: 32) { x, _ in
            x < 32 ? (240, 20, 20, 255) : (20, 40, 230, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let stroke = RetouchStroke(
            mode: .clone,
            points: [MaskPoint(x: 0.75, y: 0.5)],
            radius: 0.10,
            sourceOffset: MaskPoint(x: -0.5, y: 0)
        )
        let output = try ImagePipeline().render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )

        let copied = try rgba(output, x: 48, y: 16)
        XCTAssertGreaterThan(copied.0, 220)
        XCTAssertLessThan(copied.2, 50)
        let untouched = try rgba(output, x: 60, y: 4)
        XCTAssertLessThan(untouched.0, 50)
        XCTAssertGreaterThan(untouched.2, 200)
    }

    func testPreviewOfNonRAWPhotoMatchesFullRender() throws {
        let input = try temporaryPNG(width: 96, height: 64) { x, y in
            (UInt8(x * 2), UInt8(y * 3), UInt8((x + y) % 256), 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline(cachesDevelopment: true)
        let edits = EditSettings(exposure: 0.3, sharpness: 0.6, clarity: 0.4)
        XCTAssertEqual(pipeline.decodeScale(url: input, edits: edits, maxPixel: 24), 1, "일반 사진은 줄여서 현상하지 않는다")
        let full = try rgbaBytes(pipeline.render(url: input, edits: edits, maxPixel: 24))
        let preview = try rgbaBytes(pipeline.renderPreview(url: input, edits: edits, maxPixel: 24).image)
        XCTAssertEqual(full, preview)
    }

    func testSeveralStrokesLandAtTheirRowsAndLeaveOtherPixelsIdentical() throws {
        let input = try temporaryPNG(width: 64, height: 64) { x, y in
            y < 32 ? (230, UInt8(x), 30, 255) : (30, UInt8(x), 220, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let original = try rgbaBytes(pipeline.render(url: input, edits: .neutral, maxPixel: nil))
        let strokes = [
            RetouchStroke(mode: .clone, points: [MaskPoint(x: 0.25, y: 0.2)], radius: 0.06,
                          sourceOffset: MaskPoint(x: 0, y: 0.6)),
            RetouchStroke(mode: .clone, points: [MaskPoint(x: 0.75, y: 0.8)], radius: 0.06,
                          sourceOffset: MaskPoint(x: 0, y: -0.6)),
        ]
        let output = try pipeline.render(url: input, edits: EditSettings(retouchStrokes: strokes), maxPixel: nil)

        XCTAssertGreaterThan(try rgba(output, x: 16, y: 13).2, 180, "위쪽 stroke는 아래쪽 파랑을 가져온다")
        XCTAssertGreaterThan(try rgba(output, x: 48, y: 51).0, 180, "아래쪽 stroke는 위쪽 빨강을 가져온다")
        let bytes = try rgbaBytes(output)
        for y in 0..<64 {
            for x in 0..<64 where max(abs(x - 16), abs(y - 13)) > 12 && max(abs(x - 48), abs(y - 51)) > 12 {
                let index = (y * 64 + x) * 4
                XCTAssertEqual(bytes[index..<index + 4], original[index..<index + 4], "(\(x), \(y))")
            }
        }
    }

    func testCloneWithSourceOutsideImageLeavesDestinationUnchanged() throws {
        let input = try temporaryPNG(width: 64, height: 32) { x, y in
            (UInt8(x * 3), UInt8(y * 5), 90, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let original = try pipeline.render(url: input, edits: .neutral, maxPixel: nil)
        let stroke = RetouchStroke(
            mode: .clone,
            points: [MaskPoint(x: 0.04, y: 0.5)],
            radius: 0.025,
            sourceOffset: MaskPoint(x: -0.25, y: 0)
        )
        let cloned = try pipeline.render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )
        let actual = try rgba(cloned, x: 2, y: 16)
        let expected = try rgba(original, x: 2, y: 16)
        XCTAssertEqual(actual.0, expected.0)
        XCTAssertEqual(actual.1, expected.1)
        XCTAssertEqual(actual.2, expected.2)
        XCTAssertEqual(actual.3, expected.3)
    }

    func testLongHealStrokeRejectsOverlappingCandidatePaths() throws {
        let input = try temporaryPNG(width: 64, height: 64) { _, _ in (128, 128, 128, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let stroke = RetouchStroke(
            mode: .heal,
            points: [MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.8, y: 0.8)],
            radius: 0.05
        )
        XCTAssertThrowsError(try ImagePipeline().render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )) { error in
            XCTAssertEqual(error as? RetouchProcessingError, .noHealingSource)
        }
    }

    func testHealReducesSmallSpotErrorAndKeepsDistantPixelsFinite() throws {
        let input = try temporaryPNG(width: 64, height: 64) { x, y in
            (29...35).contains(x) && (29...35).contains(y)
                ? (0, 0, 0, 255) : (160, 160, 160, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let original = try pipeline.render(url: input, edits: .neutral, maxPixel: nil)
        let stroke = RetouchStroke(mode: .heal,
                                   points: [MaskPoint(x: 0.5, y: 0.5)],
                                   radius: 0.055)
        let healed = try pipeline.render(
            url: input, edits: EditSettings(retouchStrokes: [stroke]), maxPixel: nil
        )
        let originalCenter = try rgba(original, x: 32, y: 32)
        let healedCenter = try rgba(healed, x: 32, y: 32)
        XCTAssertGreaterThan(healedCenter.0, originalCenter.0 + 20)
        XCTAssertGreaterThan(healedCenter.1, originalCenter.1 + 20)
        XCTAssertGreaterThan(healedCenter.2, originalCenter.2 + 20)

        let distant = try rgba(healed, x: 4, y: 4)
        XCTAssertGreaterThan(distant.0, 140)
        XCTAssertGreaterThan(distant.1, 140)
        XCTAssertGreaterThan(distant.2, 140)
        XCTAssertEqual(distant.3, 255)
    }

    func testStoredHealOffsetMatchesSearchedPatchAndSkipsSearch() throws {
        let input = try temporaryPNG(width: 64, height: 64) { x, y in
            (29...35).contains(x) && (29...35).contains(y)
                ? (0, 0, 0, 255) : (UInt8(100 + x), UInt8(120 + y / 2), 150, 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let prior = RetouchStroke(mode: .heal, points: [MaskPoint(x: 0.15, y: 0.15)], radius: 0.03)
        var edits = EditSettings(exposure: 0.2, retouchStrokes: [prior])
        edits.retouchStrokes[0].sourceOffset = try pipeline.healingSourceOffset(
            url: input, edits: EditSettings(exposure: 0.2), stroke: prior)
        var stroke = RetouchStroke(mode: .heal, points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.055)
        var searched = edits
        searched.retouchStrokes.append(stroke)
        stroke.sourceOffset = try pipeline.healingSourceOffset(url: input, edits: edits, stroke: stroke)
        var stored = edits
        stored.retouchStrokes.append(stroke)
        XCTAssertEqual(try rgbaBytes(pipeline.render(url: input, edits: searched, maxPixel: nil)),
                       try rgbaBytes(pipeline.render(url: input, edits: stored, maxPixel: nil)))

        let long = RetouchStroke(mode: .heal,
                                 points: [MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.8, y: 0.8)],
                                 radius: 0.05)
        XCTAssertThrowsError(try pipeline.healingSourceOffset(url: input, edits: .neutral, stroke: long)) { error in
            XCTAssertEqual(error as? RetouchProcessingError, .noHealingSource)
        }
        var storedLong = long
        storedLong.sourceOffset = MaskPoint(x: 0.1, y: -0.1)
        XCTAssertNoThrow(try pipeline.render(url: input, edits: EditSettings(retouchStrokes: [storedLong]),
                                             maxPixel: nil))
        storedLong.sourceOffset = MaskPoint(x: .nan, y: 0)
        XCTAssertThrowsError(try pipeline.render(url: input, edits: EditSettings(retouchStrokes: [storedLong]),
                                                 maxPixel: nil)) { error in
            XCTAssertEqual(error as? RetouchProcessingError, .invalidStroke)
        }
    }

    func testThumbnailFallsBackWhenEmbeddedThumbnailIsTooSmall() throws {
        let image = try makeImage(width: 1200, height: 800) { x, y in (UInt8(x % 256), UInt8(y % 256), 90, 255) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationEmbedThumbnail: true,
            kCGImageDestinationImageMaxPixelSize: 1200
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pipeline = ImagePipeline()
        let thumbnail = try pipeline.thumbnail(for: url, maxPixel: 360)
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), 360)
        XCTAssertEqual(min(thumbnail.width, thumbnail.height), 240)
        let small = try temporaryPNG(width: 40, height: 20) { _, _ in (10, 20, 30, 255) }
        defer { try? FileManager.default.removeItem(at: small) }
        let smallThumbnail = try pipeline.thumbnail(for: small, maxPixel: 360)
        XCTAssertEqual(smallThumbnail.width, 40)
        XCTAssertEqual(smallThumbnail.height, 20)
        XCTAssertNil(pipeline.embeddedPreview(for: url, maxPixel: 2200))
        XCTAssertNil(pipeline.embeddedPreview(for: small, maxPixel: 2200))
    }

    func testPreparedJPEGKeepsCaptureMetadataAndOptionalLocation() throws {
        let image = try makeImage(width: 48, height: 32) { x, y in (UInt8(x * 5), UInt8(y * 7), 60, 255) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:20 10:11:12",
                kCGImagePropertyExifLensModel: "LUMIX S 20-60/F3.5-5.6",
                kCGImagePropertyExifFNumber: 5.6
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Panasonic",
                kCGImagePropertyTIFFModel: "DC-S9",
                kCGImagePropertyTIFFOrientation: 6
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.5,
                kCGImagePropertyGPSLatitudeRef: "N"
            ]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pipeline = ImagePipeline()
        for includeLocation in [false, true] {
            let prepared = try pipeline.prepareJPEG(url: url, edits: .neutral, maxPixel: nil,
                                                    quality: 0.9, includeLocation: includeLocation)
            XCTAssertEqual(prepared.width, 32)
            XCTAssertEqual(prepared.height, 48)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:09:20 10:11:12")
            XCTAssertEqual(exif[kCGImagePropertyExifLensModel] as? String, "LUMIX S 20-60/F3.5-5.6")
            XCTAssertEqual((exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue, 32)
            XCTAssertEqual((exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue, 48)
            let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "DC-S9")
            XCTAssertEqual((tiff[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue ?? 1, 1)
            XCTAssertEqual(properties[kCGImagePropertyGPSDictionary] != nil, includeLocation)
        }
    }

    func testDevelopmentCacheMatchesUncachedRenderAndFollowsFileChanges() throws {
        let input = try temporaryPNG(width: 96, height: 64) { x, y in (UInt8(x * 2), UInt8(y * 3), 90, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let cached = ImagePipeline(cachesDevelopment: true)
        let plain = ImagePipeline()
        for contrast in [1.0, 1.2, 0.8] {
            let edits = EditSettings(exposure: 0.3, contrast: contrast, saturation: 1.1)
            XCTAssertEqual(try rgbaBytes(cached.render(url: input, edits: edits, maxPixel: 48)),
                           try rgbaBytes(plain.render(url: input, edits: edits, maxPixel: 48)))
        }
        try pngData(makeImage(width: 96, height: 64) { _, _ in (200, 20, 20, 255) }).write(to: input)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: input.path)
        let changed = try cached.render(url: input, edits: .neutral, maxPixel: nil)
        XCTAssertEqual(try rgbaBytes(changed), try rgbaBytes(plain.render(url: input, edits: .neutral, maxPixel: nil)))
        XCTAssertGreaterThan(try rgba(changed, x: 10, y: 10).0, 150)
    }

    func testThumbnailStoreKeepsOneVariantPerPhotoAndTracksEdits() throws {
        let input = try temporaryPNG(width: 40, height: 30) { _, _ in (50, 60, 70, 255) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ThumbnailStore(directory: directory)
        var photo = PhotoAsset(url: input)
        photo.edits.exposure = 0.5
        let first = try XCTUnwrap(ThumbnailStore.key(for: photo))
        XCTAssertEqual(ThumbnailStore.key(for: photo), first)
        XCTAssertNil(store.load(photoID: photo.id, key: first))
        let image = try makeImage(width: 20, height: 15) { _, _ in (200, 100, 50, 255) }
        store.store(image, photoID: photo.id, key: first)
        let loaded = try XCTUnwrap(store.load(photoID: photo.id, key: first))
        XCTAssertEqual(loaded.width, 20)
        XCTAssertEqual(loaded.height, 15)

        photo.edits.exposure = 0.6
        let second = try XCTUnwrap(ThumbnailStore.key(for: photo))
        XCTAssertNotEqual(first, second)
        store.store(image, photoID: photo.id, key: second)
        XCTAssertNil(store.load(photoID: photo.id, key: first))
        XCTAssertNotNil(store.load(photoID: photo.id, key: second))
        let folder = directory.appendingPathComponent(photo.id.uuidString)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [second + ".jpg"])

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: input.path)
        XCTAssertNotEqual(ThumbnailStore.key(for: photo), second)
        XCTAssertNil(ThumbnailStore.key(for: PhotoAsset(url: directory.appendingPathComponent("missing.png"))))
    }

    func testThumbnailStoreKeepsLatestThumbnailWhenOriginalIsGone() throws {
        let input = try temporaryPNG(width: 40, height: 30) { _, _ in (50, 60, 70, 255) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ThumbnailStore(directory: directory)
        let photo = PhotoAsset(url: input)
        XCTAssertNil(store.latest(photoID: photo.id))
        let key = try XCTUnwrap(ThumbnailStore.key(for: photo), "보정하지 않은 사진도 키가 있다")
        store.store(try makeImage(width: 20, height: 15) { _, _ in (200, 100, 50, 255) }, photoID: photo.id, key: key)

        try FileManager.default.removeItem(at: input)
        XCTAssertNil(ThumbnailStore.key(for: photo))
        let latest = try XCTUnwrap(store.latest(photoID: photo.id))
        XCTAssertEqual(latest.width, 20)
        XCTAssertEqual(latest.height, 15)
        XCTAssertNil(store.latest(photoID: UUID()))
    }

    func testHistogramCountsChannelsAndClipping() throws {
        let image = try makeImage(width: 10, height: 10) { x, _ in
            switch x {
            case 0..<2: (255, 255, 255, 255)
            case 2..<3: (255, 10, 10, 255)
            case 3..<5: (0, 0, 0, 255)
            default: (128, 64, 32, 255)
            }
        }
        let histogram = try XCTUnwrap(ImageHistogram.make(from: image))
        XCTAssertEqual(histogram.sampleCount, 100)
        XCTAssertEqual(histogram.red[255], 30)
        XCTAssertEqual(histogram.red[128], 50)
        XCTAssertEqual(histogram.green[64], 50)
        XCTAssertEqual(histogram.blue[32], 50)
        XCTAssertEqual(histogram.luminance.reduce(0, +), 100)
        XCTAssertEqual(histogram.highlightClipped, 0.3, accuracy: 1e-9)
        XCTAssertEqual(histogram.shadowClipped, 0.2, accuracy: 1e-9)

        let overlay = try XCTUnwrap(ImageHistogram.clippingOverlay(for: image))
        XCTAssertEqual(overlay.width, 10)
        let highlight = try rgba(overlay, x: 2, y: 5)
        XCTAssertEqual(highlight.3, 255)
        XCTAssertGreaterThan(highlight.0, 200)
        let shadow = try rgba(overlay, x: 4, y: 5)
        XCTAssertGreaterThan(shadow.2, 200)
        XCTAssertEqual(try rgba(overlay, x: 7, y: 5).3, 0)

        let large = try makeImage(width: 3000, height: 1500) { _, _ in (100, 100, 100, 255) }
        let sampled = try XCTUnwrap(ImageHistogram.make(from: large))
        XCTAssertEqual(sampled.sampleCount, 1024 * 512)
        XCTAssertEqual(sampled.red[100], sampled.sampleCount)
    }

    func testGradientMasksRampCombineAndInvert() throws {
        let topWhite = try makeImage(width: 4, height: 4) { _, y in y < 2 ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        XCTAssertEqual(try gray(topWhite, x: 0, y: 0), 255, "헬퍼는 y=0을 위쪽으로 읽어야 한다")
        let pipeline = ImagePipeline()
        func mask(_ adjustment: LocalAdjustment) throws -> CGImage {
            try pipeline.renderMask(adjustment: adjustment, sourceWidth: 40, sourceHeight: 40,
                                    edits: .neutral, maxPixel: 40)
        }
        let linear = try mask(LocalAdjustment(feather: 0, gradient: .linear(start: MaskPoint(x: 0.5, y: 0.25),
                                                                            end: MaskPoint(x: 0.5, y: 0.75))))
        XCTAssertGreaterThan(try gray(linear, x: 20, y: 2), 245)
        XCTAssertLessThan(try gray(linear, x: 20, y: 37), 10)
        let ramp = try (8...32).map { try gray(linear, x: 5, y: $0) }
        XCTAssertEqual(ramp, ramp.sorted(by: >))
        XCTAssertGreaterThan(try gray(linear, x: 20, y: 20), 40)
        XCTAssertLessThan(try gray(linear, x: 20, y: 20), 230)

        let hard = LocalAdjustment(feather: 0, gradient: .radial(center: MaskPoint(x: 0.5, y: 0.5),
                                                                 radiusX: 0.25, radiusY: 0.25, softness: 0))
        let hardMask = try mask(hard)
        XCTAssertGreaterThan(try gray(hardMask, x: 20, y: 20), 245)
        XCTAssertGreaterThan(try gray(hardMask, x: 28, y: 20), 245)
        XCTAssertLessThan(try gray(hardMask, x: 33, y: 20), 10)
        XCTAssertLessThan(try gray(hardMask, x: 2, y: 2), 10)
        var soft = hard
        soft.gradient = hard.gradient?.withSoftness(1)
        let softMask = try mask(soft)
        XCTAssertGreaterThan(try gray(softMask, x: 20, y: 20), 235)
        XCTAssertLessThan(try gray(softMask, x: 27, y: 20), try gray(hardMask, x: 27, y: 20))

        var inverted = hard
        inverted.isInverted = true
        inverted.strokes = [MaskStroke(points: [MaskPoint(x: 0.1, y: 0.1)], radius: 0.05, isErasing: true)]
        let invertedMask = try mask(inverted)
        XCTAssertLessThan(try gray(invertedMask, x: 20, y: 20), 10)
        XCTAssertGreaterThan(try gray(invertedMask, x: 38, y: 38), 245)
        XCTAssertLessThan(try gray(invertedMask, x: 4, y: 4), 10)

        let degenerate = LocalAdjustment(feather: 0, gradient: .linear(start: MaskPoint(x: 0.5, y: 0.5),
                                                                       end: MaskPoint(x: 0.5, y: 0.5)))
        XCTAssertLessThan(try gray(mask(degenerate), x: 20, y: 20), 10)
    }

    func testCachedPreviewMasksFollowShapeChangesAndMatchUncachedRender() throws {
        let input = try temporaryPNG(width: 160, height: 100) { x, y in
            ((x / 5 + y / 5) % 2 == 0 ? (180, 120, 80, 255) : (60, 90, 140, 255))
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let cached = ImagePipeline(cachesDevelopment: true)
        let plain = ImagePipeline()
        var area = LocalAdjustment(exposure: -1, feather: 0.02, isInverted: true,
                                   gradient: .radial(center: MaskPoint(x: 0.4, y: 0.5), radiusX: 0.2,
                                                     radiusY: 0.3, softness: 0.5))
        func check(_ label: String) throws {
            let edits = EditSettings(localAdjustments: [area])
            XCTAssertEqual(try rgbaBytes(cached.render(url: input, edits: edits, maxPixel: 60)),
                           try rgbaBytes(plain.render(url: input, edits: edits, maxPixel: 60)), label)
        }
        try check("처음")
        area.exposure = 0.7
        try check("효과만 바꿔 캐시한 마스크를 다시 씀")
        area.gradient = area.gradient?.moving(.center, to: MaskPoint(x: 0.7, y: 0.4))
        try check("모양을 바꾸면 새 마스크")
        area.isInverted = false
        try check("반전")

        let small = try plain.renderMask(adjustment: area, sourceWidth: 6000, sourceHeight: 4000,
                                         edits: .neutral, maxPixel: 300)
        XCTAssertEqual(small.width, 300)
        XCTAssertEqual(small.height, 200)
        XCTAssertGreaterThan(try gray(small, x: 210, y: 80), 245, "원형 안쪽")
        XCTAssertLessThan(try gray(small, x: 20, y: 180), 10, "원형 바깥")
    }

    func testPreviewApproximationOnlyAppliesToCachedRAWDevelopment() throws {
        let input = try temporaryPNG(width: 40, height: 30) { x, _ in (UInt8(x * 6), 120, 90, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let preview = ImagePipeline(cachesDevelopment: true)
        _ = try preview.renderPreview(url: input, edits: .neutral, maxPixel: nil, allowApproximation: false)
        let edits = EditSettings(exposure: 0.4, temperatureShift: 500)
        let result = try preview.renderPreview(url: input, edits: edits, maxPixel: nil, allowApproximation: true)
        XCTAssertFalse(result.isApproximate, "RAW가 아니면 현상 없이 바로 정확히 그린다")
        XCTAssertEqual(try rgbaBytes(result.image), try rgbaBytes(ImagePipeline().render(url: input, edits: edits, maxPixel: nil)))
    }

    func testMetalKernelsCompileAtRuntime() {
        XCTAssertNotNil(CoreImageKernels.clarity)
        XCTAssertNotNil(CoreImageKernels.grain)
        XCTAssertNotNil(CoreImageKernels.healCorrection)
        XCTAssertNotNil(CoreImageKernels.contrast)
    }

    func testGradientHandlesMoveInSourceSpace() {
        let linear = MaskGradient.linear(start: MaskPoint(x: 0.2, y: 0.2), end: MaskPoint(x: 0.4, y: 0.6))
        guard case .linear(let movedStart, let movedEnd) = linear.moving(.center, to: MaskPoint(x: 0.5, y: 0.5)) else {
            return XCTFail("직선 그라데이션이어야 한다")
        }
        XCTAssertEqual(movedStart.x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(movedStart.y, 0.3, accuracy: 1e-12)
        XCTAssertEqual(movedEnd.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(movedEnd.y, 0.7, accuracy: 1e-12)
        XCTAssertEqual(linear.moving(.end, to: MaskPoint(x: 0.9, y: 0.9)),
                       .linear(start: MaskPoint(x: 0.2, y: 0.2), end: MaskPoint(x: 0.9, y: 0.9)))
        XCTAssertEqual(linear.moving(.radiusX, to: MaskPoint(x: 0.9, y: 0.9)), linear)
        XCTAssertEqual(linear.moving(.start, to: MaskPoint(x: .nan, y: 0)), linear)
        let radial = MaskGradient.radial(center: MaskPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.3, softness: 0.5)
        XCTAssertEqual(radial.moving(.radiusX, to: MaskPoint(x: 0.1, y: 0.9)),
                       .radial(center: MaskPoint(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.3, softness: 0.5))
        XCTAssertEqual(radial.moving(.radiusY, to: MaskPoint(x: 0.5, y: 0.5)),
                       .radial(center: MaskPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.01, softness: 0.5))
        XCTAssertEqual(radial.handles.map(\.handle), [.center, .radiusX, .radiusY])
        XCTAssertEqual(radial.withSoftness(3).softness, 1)
        XCTAssertNil(linear.softness)
    }

    func testLocalTemperatureSaturationAndClarityStayInsideMask() throws {
        let input = try temporaryPNG(width: 80, height: 80) { x, y in
            ((x / 4 + y / 4) % 2 == 0 ? (180, 120, 80, 255) : (150, 100, 70, 255))
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let neutral = try pipeline.render(url: input, edits: .neutral, maxPixel: nil)
        func render(_ change: (inout LocalAdjustment) -> Void) throws -> CGImage {
            var area = LocalAdjustment(feather: 0, gradient: .radial(center: MaskPoint(x: 0.5, y: 0.5),
                                                                     radiusX: 0.25, radiusY: 0.25, softness: 0))
            change(&area)
            return try pipeline.render(url: input, edits: EditSettings(localAdjustments: [area]), maxPixel: nil)
        }
        func spread(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
            let pixel = try rgba(image, x: x, y: y)
            return Int(max(pixel.0, pixel.1, pixel.2)) - Int(min(pixel.0, pixel.1, pixel.2))
        }
        let warm = try render { $0.temperature = 1 }
        let cool = try render { $0.temperature = -1 }
        let warmCenter = try rgba(warm, x: 40, y: 40), coolCenter = try rgba(cool, x: 40, y: 40)
        XCTAssertGreaterThan(Int(warmCenter.0) - Int(warmCenter.2), Int(coolCenter.0) - Int(coolCenter.2) + 20)
        XCTAssertTrue(try rgba(warm, x: 2, y: 2) == rgba(neutral, x: 2, y: 2))

        let desaturated = try render { $0.saturation = -1 }
        XCTAssertLessThan(try spread(desaturated, 40, 40), 4)
        XCTAssertEqual(try spread(desaturated, 2, 2), try spread(neutral, 2, 2))

        let sky = LocalAdjustment(exposure: -1, feather: 0,
                                  gradient: .linear(start: MaskPoint(x: 0.5, y: 0), end: MaskPoint(x: 0.5, y: 0.5)))
        let darkTop = try pipeline.render(url: input, edits: EditSettings(localAdjustments: [sky]), maxPixel: nil)
        XCTAssertLessThan(try rgba(darkTop, x: 0, y: 0).0, try rgba(neutral, x: 0, y: 0).0 - 40)
        XCTAssertTrue(try rgba(darkTop, x: 0, y: 79) == rgba(neutral, x: 0, y: 79))

        let clearer = try render { $0.clarity = 1 }
        XCTAssertNotEqual(try rgbaBytes(clearer), try rgbaBytes(neutral))
        XCTAssertTrue(try rgba(clearer, x: 2, y: 2) == rgba(neutral, x: 2, y: 2))
        XCTAssertEqual(try rgbaBytes(render { _ in }), try rgbaBytes(neutral))
    }

    func testNonRAWTemperatureAndTintMatchRAWDirection() throws {
        let input = try temporaryPNG(width: 16, height: 16) { _, _ in (128, 128, 128, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        func pixel(_ edits: EditSettings) throws -> (Int, Int, Int) {
            let value = try rgba(pipeline.render(url: input, edits: edits, maxPixel: nil), x: 8, y: 8)
            return (Int(value.0), Int(value.1), Int(value.2))
        }
        let warm = try pixel(EditSettings(temperatureShift: 1000))
        let cool = try pixel(EditSettings(temperatureShift: -1000))
        XCTAssertGreaterThan(warm.0 - warm.2, 10)
        XCTAssertLessThan(cool.0 - cool.2, -10)
        let magenta = try pixel(EditSettings(tintShift: 50))
        let green = try pixel(EditSettings(tintShift: -50))
        XCTAssertGreaterThan((magenta.0 + magenta.2) / 2 - magenta.1, 5)
        XCTAssertLessThan((green.0 + green.2) / 2 - green.1, -5)
    }

    func testVibranceClarityAndVignetteRender() throws {
        let input = try temporaryPNG(width: 120, height: 80) { x, y in
            ((x / 10 + y / 10) % 2 == 0 ? (170, 120, 90, 255) : (110, 140, 150, 255))
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        let neutral = try pipeline.render(url: input, edits: .neutral, maxPixel: nil)
        for edits in [EditSettings(vibrance: 0.8), EditSettings(clarity: 0.8), EditSettings(clarity: -0.8)] {
            XCTAssertNotEqual(try rgbaBytes(pipeline.render(url: input, edits: edits, maxPixel: nil)),
                              try rgbaBytes(neutral))
        }
        func brightness(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
            let pixel = try rgba(image, x: x, y: y)
            return Int(pixel.0) + Int(pixel.1) + Int(pixel.2)
        }
        let darker = try pipeline.render(url: input, edits: EditSettings(vignette: -0.8), maxPixel: nil)
        let lighter = try pipeline.render(url: input, edits: EditSettings(vignette: 0.8), maxPixel: nil)
        XCTAssertLessThan(try brightness(darker, 1, 1), try brightness(neutral, 1, 1) - 30)
        XCTAssertGreaterThan(try brightness(lighter, 1, 1), try brightness(neutral, 1, 1) + 30)
        XCTAssertEqual(try brightness(darker, 60, 40), try brightness(neutral, 60, 40), accuracy: 2)
        XCTAssertEqual(try brightness(lighter, 60, 40), try brightness(neutral, 60, 40), accuracy: 2)
        let small = try pipeline.render(url: input, edits: EditSettings(vignette: -0.8), maxPixel: 60)
        let smallNeutral = try pipeline.render(url: input, edits: .neutral, maxPixel: 60)
        let fullDrop = try brightness(neutral, 1, 1) - brightness(darker, 1, 1)
        let smallDrop = try brightness(smallNeutral, 0, 0) - brightness(small, 0, 0)
        XCTAssertEqual(Double(smallDrop), Double(fullDrop), accuracy: Double(fullDrop) * 0.25)
    }

    func testStraightenedImageHasOpaqueSafeCornersAndFinalScale() throws {
        let input = try temporaryPNG(width: 80, height: 50) { _, _ in (80, 120, 160, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let output = try ImagePipeline().render(
            url: input,
            edits: EditSettings(straightenDegrees: 13,
                                cropRect: NormalizedCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            maxPixel: 32
        )
        XCTAssertLessThanOrEqual(max(output.width, output.height), 32)
        for point in [(0, 0), (output.width - 1, 0),
                      (0, output.height - 1), (output.width - 1, output.height - 1)] {
            XCTAssertEqual(try rgba(output, x: point.0, y: point.1).3, 255)
        }
    }

    func testGeometryUsesFloorDimensionsAndOpaqueSingleFinalCrop() throws {
        let input = try temporaryPNG(width: 81, height: 53) { x, y in
            (UInt8(x * 3), UInt8(y * 4), UInt8(x + y), 255)
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()

        let neutral = try pipeline.render(url: input, edits: .neutral, maxPixel: 40)
        XCTAssertEqual(neutral.width, 40)
        XCTAssertEqual(neutral.height, 26)
        try assertOpaque(neutral)

        let straightenEdits = EditSettings(straightenDegrees: 13)
        let straightened = try pipeline.render(url: input, edits: straightenEdits, maxPixel: nil)
        let straightenGeometry = PhotoGeometry(sourceWidth: 81, sourceHeight: 53,
                                               edits: straightenEdits)
        XCTAssertEqual(straightened.width, Int(floor(straightenGeometry.outputSize.width)))
        XCTAssertEqual(straightened.height, Int(floor(straightenGeometry.outputSize.height)))
        try assertOpaque(straightened)

        let cropEdits = EditSettings(
            straightenDegrees: -7,
            cropRect: NormalizedCrop(x: 0.137, y: 0.083, width: 0.613, height: 0.727)
        )
        let cropped = try pipeline.render(url: input, edits: cropEdits, maxPixel: 31)
        let cropGeometry = PhotoGeometry(sourceWidth: 81, sourceHeight: 53, edits: cropEdits)
        let cropScale = min(1, 31 / max(cropGeometry.outputSize.width,
                                        cropGeometry.outputSize.height))
        XCTAssertEqual(cropped.width, Int(floor(cropGeometry.outputSize.width * cropScale)))
        XCTAssertEqual(cropped.height, Int(floor(cropGeometry.outputSize.height * cropScale)))
        try assertOpaque(cropped)
        let first = try rgba(cropped, x: 0, y: 0)
        let last = try rgba(cropped, x: cropped.width - 1, y: cropped.height - 1)
        XCTAssertTrue(first.0 != last.0 || first.1 != last.1 || first.2 != last.2)
    }

    func testPreparedJPEGDecodesExactBytesAndWritePreservesExistingFile() throws {
        let input = try temporaryPNG(width: 48, height: 32) { x, y in
            (UInt8(x * 5), UInt8(y * 7), UInt8((x + y) * 3), 255)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: directory)
        }
        let pipeline = ImagePipeline()
        let low = try pipeline.prepareJPEG(url: input, edits: .neutral,
                                           maxPixel: 24, quality: 0.2)
        let high = try pipeline.prepareJPEG(url: input, edits: .neutral,
                                            maxPixel: 24, quality: 0.95)
        XCTAssertEqual(low.image.width, low.width)
        XCTAssertEqual(low.image.height, low.height)
        XCTAssertLessThanOrEqual(max(low.width, low.height), 24)
        XCTAssertNotEqual(low.data, high.data)

        let existing = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-edited.jpg")
        let sentinel = Data("existing".utf8)
        try sentinel.write(to: existing)
        let written = try pipeline.writeJPEG(high.data, sourceURL: input, to: directory)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try Data(contentsOf: written), high.data)
        XCTAssertTrue(written.lastPathComponent.hasSuffix("-edited-2.jpg"))
    }

    func testOutputSizeMatchesTheFullRender() throws {
        let input = try temporaryPNG(width: 90, height: 60) { x, y in (UInt8(x * 2), UInt8(y * 3), 90, 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        for edits in [EditSettings.neutral, EditSettings(rotationQuarterTurns: 1),
                      EditSettings(rotationQuarterTurns: 1, cropAspect: 1),
                      EditSettings(straightenDegrees: 7, cropRect: NormalizedCrop(x: 0.1, y: 0.2, width: 0.6, height: 0.5))] {
            let image = try pipeline.render(url: input, edits: edits, maxPixel: nil)
            XCTAssertEqual(pipeline.outputSize(url: input, edits: edits), CGSize(width: image.width, height: image.height))
        }
    }

    /// 예전에는 선형 값 0.5를 기준으로 늘려 대비 1.2에서 sRGB 40/255가 0이 되고, 0.8에서 검정이 89/255로 떴다.
    func testContrastBendsAroundMiddleGrayAndKeepsBlackAndWhite() throws {
        let input = try temporaryPNG(width: 256, height: 2) { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        defer { try? FileManager.default.removeItem(at: input) }
        let pipeline = ImagePipeline()
        func gray(_ contrast: Double, _ x: Int) throws -> Int {
            Int(try rgba(pipeline.render(url: input, edits: EditSettings(contrast: contrast), maxPixel: nil), x: x, y: 0).0)
        }
        for contrast in [0.5, 0.8, 1.2, 1.5] {
            XCTAssertLessThanOrEqual(try gray(contrast, 0), 1, "검정은 그대로 \(contrast)")
            XCTAssertGreaterThanOrEqual(try gray(contrast, 255), 254, "흰색은 그대로 \(contrast)")
            XCTAssertEqual(try gray(contrast, 128), 128, accuracy: 2, "중간 회색은 그대로 \(contrast)")
        }
        XCTAssertEqual(try gray(1.2, 40), 31, accuracy: 3, "어두운 쪽은 잘리지 않고 조금 어두워진다")
        XCTAssertEqual(try gray(1.2, 215), 224, accuracy: 3)
        XCTAssertGreaterThan(try gray(0.8, 40), 40)
        XCTAssertLessThan(try gray(0.8, 215), 215)
        var previous = -1
        for x in stride(from: 0, through: 255, by: 15) {
            let value = try gray(1.5, x)
            XCTAssertGreaterThanOrEqual(value, previous, "최대 대비에서도 순서가 뒤집히지 않는다")
            previous = value
        }
    }

    private func temporaryPNG(width: Int, height: Int,
                              pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> URL {
        let image = try makeImage(width: width, height: height, pixel: pixel)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try pngData(image).write(to: url)
        return url
    }

    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let index = y * rowBytes + x * 4
                bytes[index] = color.0
                bytes[index + 1] = color.1
                bytes[index + 2] = color.2
                bytes[index + 3] = color.3
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw TestError.imageCreation
        }
        return image
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw TestError.imageCreation }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.imageCreation }
        return data as Data
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else {
            throw TestError.pixelOutsideImage
        }
        let bytes = try rgbaBytes(image)
        let index = (y * image.width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestError.imageCreation
        }
        // 비트맵 메모리의 첫 행이 이미지 위쪽이 되도록 뒤집지 않고 그린다.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func gray(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        try rgba(image, x: x, y: y).0
    }

    private func assertOpaque(_ image: CGImage, file: StaticString = #filePath,
                              line: UInt = #line) throws {
        let bytes = try rgbaBytes(image)
        for index in stride(from: 3, to: bytes.count, by: 4) {
            XCTAssertEqual(bytes[index], 255, file: file, line: line)
        }
    }

    private enum TestError: Error {
        case imageCreation
        case pixelOutsideImage
    }
}
