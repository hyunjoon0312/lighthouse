import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class LUTTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func cube(size: Int, title: String? = nil, domain: String = "",
                      transform: (Float, Float, Float) -> (Float, Float, Float)) -> Data {
        var lines: [String] = []
        if let title { lines.append("TITLE \"\(title)\"") }
        lines.append("LUT_3D_SIZE \(size)")
        if !domain.isEmpty { lines.append(domain) }
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let rgb = transform(Float(red) / Float(size - 1), Float(green) / Float(size - 1),
                                        Float(blue) / Float(size - 1))
                    lines.append("\(rgb.0) \(rgb.1) \(rgb.2)")
                }
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func sourceImage(in directory: URL) throws -> URL {
        // Premultiplied RGBA: second pixel is half-transparent.
        let row: [UInt8] = [64, 128, 192, 255, 64, 32, 16, 128, 192, 64, 128, 255]
        let bytes = row + row
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = directory.appendingPathComponent("colors.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixel(_ image: CGImage, at x: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let count = image.bitsPerPixel / 8
        return Array(data[(x * count)..<((x + 1) * count)])
    }

    private func imported(_ data: Data, in directory: URL) throws -> LUTAdjustment {
        let url = directory.appendingPathComponent("look.CUBE")
        try data.write(to: url)
        return try LUTStore(directory: directory.appendingPathComponent("LUTs")).importCube(from: url)
    }

    func testParserValidCubeDomainOrderingAndErrors() throws {
        let identity = cube(size: 2, title: "Film #1", domain: "DOMAIN_MIN 0.1 0.2 0.3\nDOMAIN_MAX 0.9 0.8 0.7") {
            ($0, $1, $2)
        }
        let parsed = try CubeLUT.parse(Data([0xEF, 0xBB, 0xBF]) + identity)
        XCTAssertEqual(parsed.title, "Film #1")
        XCTAssertEqual(parsed.dimension, 2)
        XCTAssertEqual(parsed.domainMin, SIMD3<Float>(0.1, 0.2, 0.3))
        XCTAssertEqual(parsed.domainMax, SIMD3<Float>(0.9, 0.8, 0.7))
        XCTAssertEqual(parsed.cubeData.count, 8 * 4 * 4)
        let floats = parsed.cubeData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Array(floats[0..<4]), [0, 0, 0, 1])
        XCTAssertEqual(Array(floats[4..<8]), [1, 0, 0, 1])
        XCTAssertEqual(Array(floats[16..<20]), [0, 0, 1, 1])
        let range = try CubeLUT.parse(cube(size: 2, domain: "LUT_3D_INPUT_RANGE 0.25 0.75") {
            ($0, $1, $2)
        })
        XCTAssertEqual(range.domainMin, SIMD3<Float>(repeating: 0.25))
        XCTAssertEqual(range.domainMax, SIMD3<Float>(repeating: 0.75))
        XCTAssertEqual(try CubeLUT.parse(cube(size: 65) { ($0, $1, $2) }).dimension, 65)

        let base = String(decoding: cube(size: 2) { ($0, $1, $2) }, as: UTF8.self)
        for bad in [
            base.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 1"),
            base.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 66"),
            base.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 2\nLUT_3D_SIZE 2"),
            base.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_1D_SIZE 2\nLUT_3D_SIZE 2"),
            base.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "UNKNOWN 1\nLUT_3D_SIZE 2"),
            base.replacingOccurrences(of: "0.0 0.0 0.0", with: "nan 0 0"),
            base + "0 0 0\n",
            String(base.split(separator: "\n").dropLast().joined(separator: "\n")),
            "LUT_3D_SIZE 2\nDOMAIN_MIN 1 0 0\nDOMAIN_MAX 0 1 1\n" + base.components(separatedBy: "\n").dropFirst().joined(separator: "\n"),
            "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nLUT_3D_INPUT_RANGE 0 1\n" + base.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        ] {
            XCTAssertThrowsError(try CubeLUT.parse(Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try CubeLUT.parse(Data([0xFF])))
        XCTAssertThrowsError(try CubeLUT.parse(Data(repeating: 0, count: 64 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try CubeLUT.parse(cube(size: 2, domain: "DOMAIN_MIN -3e38 0 0\nDOMAIN_MAX 3e38 1 1") { ($0, $1, $2) }))
        XCTAssertThrowsError(try CubeLUT.parse(cube(size: 2, domain: "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 1e-44 1 1") { ($0, $1, $2) }))
    }

    func testStoreDedupSourceMoveAndIntegrity() throws {
        let directory = try temporaryDirectory()
        let data = cube(size: 2, title: "Warm #2") { ($0, $1, $2) }
        let source = directory.appendingPathComponent("look.CUBE")
        try data.write(to: source)
        let store = LUTStore(directory: directory.appendingPathComponent("catalog/LUTs"))
        let first = try store.importCube(from: source)
        XCTAssertEqual(first.id.count, 64)
        XCTAssertEqual(first.name, "Warm #2")
        XCTAssertEqual(try store.importCube(from: source).id, first.id)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try store.load(id: first.id).dimension, 2)
        XCTAssertThrowsError(try store.load(id: "../bad"))
        let saved = store.directory.appendingPathComponent(first.id + ".cube")
        try Data("damaged".utf8).write(to: saved)
        XCTAssertThrowsError(try store.load(id: first.id))
        try data.write(to: source)
        XCTAssertEqual(try store.importCube(from: source).id, first.id)
        XCTAssertEqual(try store.load(id: first.id).dimension, 2)
        try FileManager.default.removeItem(at: saved)
        XCTAssertThrowsError(try store.load(id: first.id)) { error in
            guard case LUTStoreError.missing = error else { return XCTFail("Missing file error: \(error)") }
        }
        let large = directory.appendingPathComponent("large.cube")
        _ = FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try store.importCube(from: large)) { error in
            guard case CubeLUTError.tooLarge = error else { return XCTFail("Large file error: \(error)") }
        }
        try FileManager.default.copyItem(at: large, to: saved)
        XCTAssertThrowsError(try store.load(id: first.id)) { error in
            guard case CubeLUTError.tooLarge = error else { return XCTFail("Large stored file error: \(error)") }
        }
    }

    func testLegacyAndNewCatalog() throws {
        let directory = try temporaryDirectory()
        let original = try JSONEncoder().encode(EditSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object.removeValue(forKey: "lut")
        XCTAssertNil(try JSONDecoder().decode(EditSettings.self,
                                              from: JSONSerialization.data(withJSONObject: object)).lut)
        object["lut"] = NSNull()
        XCTAssertNil(try JSONDecoder().decode(EditSettings.self,
                                              from: JSONSerialization.data(withJSONObject: object)).lut)
        object["lut"] = ["id": "broken"]
        XCTAssertThrowsError(try JSONDecoder().decode(EditSettings.self,
                                                     from: JSONSerialization.data(withJSONObject: object)))
        var photo = PhotoAsset(url: directory.appendingPathComponent("photo.png"))
        photo.edits.lut = LUTAdjustment(id: String(repeating: "a", count: 64), name: "Look", intensity: 0.5)
        let store = CatalogStore(url: directory.appendingPathComponent("catalog.json"))
        try store.save([photo])
        XCTAssertEqual(try store.load(), [photo])
    }

    func testIdentityNonlinearStrengthAlphaAndMissingBypass() throws {
        let directory = try temporaryDirectory()
        let source = try sourceImage(in: directory)
        let lutDirectory = directory.appendingPathComponent("LUTs")
        let store = LUTStore(directory: lutDirectory)
        let pipeline = ImagePipeline(lutDirectory: lutDirectory)
        let neutral = try pipeline.render(url: source, edits: .neutral, maxPixel: nil)
        let identity = try imported(cube(size: 17) { ($0, $1, $2) }, in: directory)
        let identityImage = try pipeline.render(url: source, edits: EditSettings(lut: identity), maxPixel: nil)
        for x in 0..<3 {
            let actual = try pixel(identityImage, at: x)
            let baseline = try pixel(neutral, at: x)
            for channel in 0..<4 { XCTAssertEqual(Int(actual[channel]), Int(baseline[channel]), accuracy: 2) }
        }

        let nonlinear = try imported(cube(size: 17) { ($0 * $0, $1 * $1, $2 * $2) }, in: directory)
        let full = try pipeline.render(url: source, edits: EditSettings(lut: nonlinear), maxPixel: nil)
        let original = try pixel(neutral, at: 0)
        let changed = try pixel(full, at: 0)
        for channel in 0..<3 {
            let expected = Double(original[channel]) * Double(original[channel]) / 255
            XCTAssertEqual(Double(changed[channel]), expected, accuracy: 3)
        }
        XCTAssertEqual(try pixel(full, at: 1)[3], try pixel(neutral, at: 1)[3])

        var half = nonlinear
        half.intensity = 0.5
        let midpoint = try pipeline.render(url: source, edits: EditSettings(lut: half), maxPixel: nil)
        let mixed = try pixel(midpoint, at: 0)
        for channel in 0..<3 {
            let expected = encodeSRGB((decodeSRGB(Double(original[channel]) / 255) +
                                       decodeSRGB(Double(changed[channel]) / 255)) / 2) * 255
            XCTAssertEqual(Double(mixed[channel]), expected, accuracy: 4)
        }
        XCTAssertEqual(try pixel(midpoint, at: 1)[3], try pixel(neutral, at: 1)[3])

        let missing = LUTAdjustment(id: String(repeating: "0", count: 64), name: "Missing")
        XCTAssertThrowsError(try pipeline.render(url: source, edits: EditSettings(lut: missing), maxPixel: nil))
        var zero = missing
        zero.intensity = 0
        XCTAssertEqual(try pixel(pipeline.render(url: source, edits: EditSettings(lut: zero), maxPixel: nil), at: 0), original)
        var disabled = missing
        disabled.isEnabled = false
        XCTAssertEqual(try pixel(pipeline.render(url: source, edits: EditSettings(lut: disabled), maxPixel: nil), at: 0), original)
        XCTAssertEqual(try store.load(id: nonlinear.id).dimension, 17)
    }

    func testDomainLocalPreviewAndJPEG() throws {
        let directory = try temporaryDirectory()
        let source = try sourceImage(in: directory)
        let lutDirectory = directory.appendingPathComponent("LUTs")
        let domain = try imported(cube(size: 17, domain: "DOMAIN_MIN 0.25 0.25 0.25\nDOMAIN_MAX 0.75 0.75 0.75") {
            ($0, $1, $2)
        }, in: directory)
        let pipeline = ImagePipeline(lutDirectory: lutDirectory)
        let output = try pipeline.render(url: source, edits: EditSettings(lut: domain), maxPixel: nil)
        let p = try pixel(output, at: 0)
        XCTAssertLessThan(p[0], 5)
        XCTAssertEqual(Int(p[1]), 129, accuracy: 5)
        XCTAssertGreaterThan(p[2], 250)

        let square = try imported(cube(size: 17) { ($0 * $0, $1 * $1, $2 * $2) }, in: directory)
        var edits = EditSettings(lut: square)
        edits.localAdjustments = [LocalAdjustment(exposure: 1, feather: 0, strokes: [
            MaskStroke(points: [MaskPoint(x: 0.15, y: 0.5)], radius: 0.4)
        ])]
        let withLocal = try pipeline.render(url: source, edits: edits, maxPixel: nil)
        let withoutLocal = try pipeline.render(url: source, edits: EditSettings(lut: square), maxPixel: nil)
        XCTAssertNotEqual(try pixel(withLocal, at: 0), try pixel(withoutLocal, at: 0))
        XCTAssertEqual(try pixel(withLocal, at: 2), try pixel(withoutLocal, at: 2))

        let preview = try pipeline.render(url: source, edits: EditSettings(lut: square), maxPixel: 2)
        XCTAssertEqual(preview.width, 2)
        let export = try pipeline.exportJPEG(url: source, edits: EditSettings(lut: square),
                                             to: directory, maxPixel: nil, quality: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(export as CFURL, nil)!, 0, nil)?.width, 3)
    }

    private func decodeSRGB(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func encodeSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
