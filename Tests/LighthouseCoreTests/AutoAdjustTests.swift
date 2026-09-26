import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class AutoAdjustTests: XCTestCase {
    private func temporaryJPEG(_ pixel: (Int, Int) -> (Double, Double, Double)) throws -> URL {
        let width = 240, height = 160
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let index = (y * width + x) * 4
            bytes[index] = UInt8(max(0, min(255, r * 255)))
            bytes[index + 1] = UInt8(max(0, min(255, g * 255)))
            bytes[index + 2] = UInt8(max(0, min(255, b * 255)))
        } }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDarkBlueCastGetsWarmerAndBrighter() throws {
        // 어둡고 파랗게 뜬 회색 계단.
        let url = try temporaryJPEG { x, _ in
            let v = 0.08 + Double(x) / 240 * 0.3
            return (v * 0.9, v, v * 1.12)
        }
        let pipeline = ImagePipeline()
        let before = AutoAdjust.Stats(try pipeline.renderPreview(url: url, edits: .neutral, maxPixel: 192).image)
        var current = EditSettings.neutral
        current.vignette = 0.3
        current.rotationQuarterTurns = 1
        let result = try AutoAdjust.suggest(url: url, current: current, pipeline: pipeline)
        let edits = result.edits
        XCTAssertGreaterThan(edits.temperatureShift, 0, "파란 기운은 따뜻한 쪽으로")
        XCTAssertGreaterThan(edits.exposure, 0.5, "어두운 사진은 밝게")
        XCTAssertEqual(edits.vignette, 0.3, "다른 보정은 그대로")
        XCTAssertEqual(edits.rotationQuarterTurns, 1)
        var measured = edits
        measured.vignette = 0
        let after = AutoAdjust.Stats(try pipeline.renderPreview(url: url, edits: measured, maxPixel: 192).image)
        func cast(_ stats: AutoAdjust.Stats) -> Double {
            (stats.gray.b - stats.gray.r) / (stats.gray.r + stats.gray.g + stats.gray.b)
        }
        XCTAssertLessThan(abs(cast(after)), abs(cast(before)) * 0.3, "회색 부분의 파랑·빨강 치우침이 크게 줄어든다")
        XCTAssertGreaterThan(after.medianLinear, before.medianLinear * 2)
        print(String(format: "  auto: %.0fK tint %.1f %.2fEV highlights %.1f shadows %.2f, %d renders",
                     edits.temperatureShift, edits.tintShift, edits.exposure, edits.highlights, edits.shadows, result.renders))
    }

    func testBrightSceneIsDarkenedOrProtected() throws {
        let url = try temporaryJPEG { x, _ in
            let v = x < 150 ? 0.98 : 0.5 + Double(x - 150) / 180
            return (v, v, v)
        }
        let edits = try AutoAdjust.suggest(url: url, current: .neutral, pipeline: ImagePipeline()).edits
        XCTAssertTrue(edits.exposure < 0 || edits.highlights < 1, "밝게 날아간 사진은 어둡게 하거나 하이라이트를 누른다")
        XCTAssertEqual(abs(edits.temperatureShift), 0, accuracy: 150, "무채색은 색을 거의 옮기지 않는다")
    }

    func testSolveFindsZeroWithFewCalls() throws {
        var calls = 0
        XCTAssertEqual(try AutoAdjust.solve(from: 0.37, step: 10, limit: 100) { calls += 1; return (37 - $0) / 100 }, 37,
                       accuracy: 0.01, "직선이면 한 번에")
        XCTAssertLessThanOrEqual(calls, 2)
        calls = 0
        let curved = try AutoAdjust.solve(from: -0.5, step: 400, limit: 1500) { calls += 1; return -0.5 - $0 / 800 - pow($0 / 2000, 3) }
        XCTAssertEqual(curved, -400, accuracy: 30)
        XCTAssertLessThanOrEqual(calls, 3)
        XCTAssertEqual(try AutoAdjust.solve(from: 1, step: 10, limit: 20) { 1 - $0 / 1000 }, 20, "범위 밖이면 끝에서 멈춘다")
        XCTAssertEqual(try AutoAdjust.solve(from: 0, step: 10, limit: 20) { _ in XCTFail(); return 0 }, 0)
    }

    func testS9RAWSuggestionStaysInRange() throws {
        let path = ProcessInfo.processInfo.environment["LIGHTHOUSE_SAMPLE_RW2"] ?? {
            var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            for _ in 0..<5 {
                directory.deleteLastPathComponent()
                let candidate = directory.appendingPathComponent(".artifacts/samples/LUMIX-S9.RW2")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            }
            return ""
        }()
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("RAW 표본이 없습니다.") }
        let start = Date()
        let result = try AutoAdjust.suggest(url: URL(fileURLWithPath: path), current: .neutral, pipeline: ImagePipeline())
        let edits = result.edits
        print(String(format: "  S9 auto: %.0fK tint %.1f %.2fEV highlights %.1f shadows %.2f, %d renders %.2fs",
                     edits.temperatureShift, edits.tintShift, edits.exposure, edits.highlights, edits.shadows,
                     result.renders, Date().timeIntervalSince(start)))
        XCTAssertLessThanOrEqual(abs(edits.temperatureShift), AutoAdjust.temperatureLimit)
        XCTAssertLessThanOrEqual(abs(edits.tintShift), AutoAdjust.tintLimit)
        XCTAssertLessThanOrEqual(abs(edits.exposure), 2)
    }
}
