import CoreGraphics
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class FaceAnalyzerTests: XCTestCase {
    func testSimilarityTransformMatchesKnownRotationScaleAndTranslation() throws {
        let source = [
            CGPoint(x: 1, y: 2),
            CGPoint(x: 5, y: 2),
            CGPoint(x: 3, y: 4),
            CGPoint(x: 1.5, y: 6),
            CGPoint(x: 4.5, y: 6),
        ]
        let expected = CGAffineTransform(a: 1.2, b: 0.35, c: -0.35, d: 1.2, tx: 8, ty: -3)
        let target = source.map { $0.applying(expected) }
        let actual = try FaceAlignment.transform(source: source, target: target)

        XCTAssertEqual(actual.a, expected.a, accuracy: 1e-10)
        XCTAssertEqual(actual.b, expected.b, accuracy: 1e-10)
        XCTAssertEqual(actual.c, expected.c, accuracy: 1e-10)
        XCTAssertEqual(actual.d, expected.d, accuracy: 1e-10)
        XCTAssertEqual(actual.tx, expected.tx, accuracy: 1e-10)
        XCTAssertEqual(actual.ty, expected.ty, accuracy: 1e-10)
        XCTAssertTrue([actual.a, actual.b, actual.c, actual.d, actual.tx, actual.ty].allSatisfy(\.isFinite))
    }

    func testSimilarityTransformRejectsWrongCountNonfiniteAndDegeneratePoints() {
        let valid = FaceAlignment.canonicalPoints
        XCTAssertThrowsError(try FaceAlignment.transform(source: Array(valid.prefix(4)), target: valid))

        var nonfinite = valid
        nonfinite[2].x = .nan
        XCTAssertThrowsError(try FaceAlignment.transform(source: nonfinite, target: valid))

        let repeated = [CGPoint](repeating: CGPoint(x: 4, y: 9), count: 5)
        XCTAssertThrowsError(try FaceAlignment.transform(source: repeated, target: valid))
        XCTAssertThrowsError(try FaceAlignment.transform(source: valid, target: repeated))
    }

    func testRGBTensorPreservesTopBottomAndChannelOrder() throws {
        let analyzer = FaceAnalyzer()
        let image = try asymmetricImage()
        let input = try analyzer.inputArray(forAlignedFace: image)

        XCTAssertEqual(input.dataType, .float32)
        XCTAssertEqual(input.shape.map(\.intValue), [3, 112, 112])
        assertPixel(input, x: 7, y: 3, equals: (250, 10, 20))
        assertPixel(input, x: 7, y: 108, equals: (30, 40, 240))
    }

    func testBundledModelProducesFiniteNormalizedEmbedding() throws {
        let embedding = try FaceAnalyzer().embedding(forAlignedFace: asymmetricImage())
        XCTAssertEqual(embedding.count, 128)
        XCTAssertTrue(embedding.allSatisfy(\.isFinite))
        let magnitude = sqrt(embedding.reduce(0.0) { $0 + Double($1) * Double($1) })
        XCTAssertEqual(magnitude, 1, accuracy: 1e-6)
    }

    func testPackagedModelResolverSupportsFlatBundleLayout() throws {
        let resourcesDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resourcesDirectory) }
        let modelURL = resourcesDirectory
            .appendingPathComponent("Lighthouse_LighthouseCore.bundle", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("SFace.mlmodel")
        try writeDummyModel(at: modelURL)

        XCTAssertEqual(
            FaceAnalyzer.packagedModelURL(in: resourcesDirectory)?.standardizedFileURL,
            modelURL.standardizedFileURL
        )
    }

    func testPackagedModelResolverSupportsContentsResourcesBundleLayout() throws {
        let resourcesDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resourcesDirectory) }
        let bundleURL = resourcesDirectory
            .appendingPathComponent("Lighthouse_LighthouseCore.bundle", isDirectory: true)
        let modelURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("SFace.mlmodel")
        try writeBundleInfo(at: bundleURL)
        try writeDummyModel(at: modelURL)

        XCTAssertEqual(
            FaceAnalyzer.packagedModelURL(in: resourcesDirectory)?.standardizedFileURL,
            modelURL.standardizedFileURL
        )
    }

    func testPackagedModelResolverRejectsMissingBundleAndModel() throws {
        let resourcesDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: resourcesDirectory) }
        XCTAssertNil(FaceAnalyzer.packagedModelURL(in: resourcesDirectory))

        let bundleURL = resourcesDirectory
            .appendingPathComponent("Lighthouse_LighthouseCore.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        XCTAssertNil(FaceAnalyzer.packagedModelURL(in: resourcesDirectory))
    }

    func testBlankImageHasNoFaces() throws {
        let url = try temporaryImage(makeImage(width: 256, height: 192) { _, _ in
            (180, 180, 180, 255)
        })
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try FaceAnalyzer().analyze(url: url, pipeline: ImagePipeline()), [])
    }

    func testMissingImageThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        XCTAssertThrowsError(try FaceAnalyzer().analyze(url: url, pipeline: ImagePipeline()))
    }

    func testOptionalLocalIdentityOrientationAndMultiFaceFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTHOUSE_FACE_FIXTURES"],
              !path.isEmpty else {
            throw XCTSkip("LIGHTHOUSE_FACE_FIXTURES를 지정하면 로컬 얼굴 표본을 검사합니다.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let analyzer = FaceAnalyzer()
        let pipeline = ImagePipeline()
        func faces(_ name: String) throws -> [DetectedFace] {
            let result = try analyzer.analyze(
                url: directory.appendingPathComponent(name).appendingPathExtension("jpg"),
                pipeline: pipeline
            )
            XCTAssertFalse(result.isEmpty, "\(name)에 사용할 수 있는 얼굴이 있어야 합니다.")
            return result
        }

        let personA1 = try XCTUnwrap(try faces("person-a-1").first)
        let personA2 = try XCTUnwrap(try faces("person-a-2").first)
        let personB1 = try XCTUnwrap(try faces("person-b-1").first)
        let sameScore = try XCTUnwrap(FaceMatching.cosine(personA1.embedding, personA2.embedding))
        let differentA1 = try XCTUnwrap(FaceMatching.cosine(personA1.embedding, personB1.embedding))
        let differentA2 = try XCTUnwrap(FaceMatching.cosine(personA2.embedding, personB1.embedding))
        print("face-fixtures same=\(sameScore) differentA1=\(differentA1) differentA2=\(differentA2)")
        XCTAssertGreaterThanOrEqual(sameScore, 0.50)
        XCTAssertLessThan(differentA1, 0.50)
        XCTAssertLessThan(differentA2, 0.50)

        let groupURL = directory.appendingPathComponent("two-people.jpg")
        if FileManager.default.fileExists(atPath: groupURL.path) {
            let group = try faces("two-people")
            XCTAssertEqual(group.count, 2)
            let groupScores = group.map { face -> (a: Float, b: Float) in
                (
                    FaceMatching.cosine(face.embedding, personA1.embedding) ?? -.infinity,
                    FaceMatching.cosine(face.embedding, personB1.embedding) ?? -.infinity
                )
            }
            print("face-fixtures group=\(groupScores)")
            XCTAssertEqual(groupScores.filter { $0.a >= 0.50 && $0.b < 0.50 }.count, 1)
            XCTAssertEqual(groupScores.filter { $0.b >= 0.50 && $0.a < 0.50 }.count, 1)
        }

        let exifURL = directory.appendingPathComponent("person-a-exif6.jpg")
        if FileManager.default.fileExists(atPath: exifURL.path) {
            let exifFace = try XCTUnwrap(try faces("person-a-exif6").first)
            let exifScore = try XCTUnwrap(FaceMatching.cosine(exifFace.embedding, personA1.embedding))
            print("face-fixtures exif6=\(exifScore)")
            XCTAssertGreaterThanOrEqual(exifScore, 0.95)
        }
    }

    private func assertPixel(
        _ array: MLMultiArray,
        x: Int,
        y: Int,
        equals expected: (Float, Float, Float),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let channelStride = array.strides[0].intValue
        let rowStride = array.strides[1].intValue
        let columnStride = array.strides[2].intValue
        let values = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        let offset = y * rowStride + x * columnStride
        XCTAssertEqual(values[offset], expected.0, file: file, line: line)
        XCTAssertEqual(values[channelStride + offset], expected.1, file: file, line: line)
        XCTAssertEqual(values[channelStride * 2 + offset], expected.2, file: file, line: line)
    }

    private func asymmetricImage() throws -> CGImage {
        try makeImage(width: 112, height: 112) { _, y in
            y < 56 ? (250, 10, 20, 255) : (30, 40, 240, 255)
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let index = (y * width + x) * 4
                bytes[index] = value.0
                bytes[index + 1] = value.1
                bytes[index + 2] = value.2
                bytes[index + 3] = value.3
            }
        }
        let data = Data(bytes) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func temporaryImage(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeDummyModel(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: url)
    }

    private func writeBundleInfo(at bundleURL: URL) throws {
        let infoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        try FileManager.default.createDirectory(
            at: infoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "Lighthouse.FaceAnalyzerTests.\(UUID().uuidString)",
            "CFBundleName": "Lighthouse_LighthouseCore",
            "CFBundlePackageType": "BNDL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: infoURL)
    }
}
