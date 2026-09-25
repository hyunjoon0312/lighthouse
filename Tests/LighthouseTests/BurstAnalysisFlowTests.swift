import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
@testable import Lighthouse
import LighthouseCore
import UniformTypeIdentifiers
import XCTest

/// 연속 촬영 분석을 중간에 멈추거나 읽지 못하는 컷이 있을 때의 추천. 만든 JPEG로 돈다.
@MainActor
final class BurstAnalysisFlowTests: XCTestCase {
    private func wait(_ label: String, timeout: Double = 60, _ ready: @escaping () -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if ready() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("시간 초과: \(label)")
        throw TestSupport.Timeout(label: label)
    }

    /// 1초 안에 찍은 같은 카메라의 컷. 같은 무늬를 점점 더 흐리게 해 첫 컷이 가장 선명하다.
    private func writeFrame(_ url: URL, index: Int) throws {
        let pattern = CIFilter.checkerboardGenerator()
        pattern.width = 40
        pattern.color0 = CIColor(red: 0.85, green: 0.85, blue: 0.85)
        pattern.color1 = CIColor(red: 0.15, green: 0.15, blue: 0.15)
        pattern.sharpness = 1
        let extent = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        var image = pattern.outputImage!.cropped(to: extent)
        let radius = [0, 3, 7, 14][index]
        if radius > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(radius)
            image = blur.outputImage!.cropped(to: extent)
        }
        let cgImage = CIContext().createCGImage(image, from: extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:21 10:00:00",
                                             kCGImagePropertyExifSubsecTimeOriginal: "\(100 + index * 200)"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Panasonic", kCGImagePropertyTIFFModel: "DC-S9"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testStoppedAnalysisDoesNotRecommendAndUnreadableShotIsLeftUnmarked() async throws {
        TestSupport.resetModelDefaults()
        _ = NSApplication.shared
        let root = try TestSupport.temporaryDirectory(self)
        setenv("LIGHTHOUSE_DATA_DIR", root.appendingPathComponent("data").path, 1)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var urls: [URL] = []
        for index in 0..<4 {
            let url = photos.appendingPathComponent("frame-\(index).jpg")
            try writeFrame(url, index: index)
            urls.append(url)
        }
        let model = LibraryModel()
        model.start()
        try await wait("catalog") { model.catalogLoaded }
        model.importURLs(urls)
        try await wait("import") { !model.isImporting && model.photos.count == 4 }
        XCTAssertEqual(model.burstIndex.groups.count, 1, "네 컷이 한 묶음")
        model.filter = .bursts

        model.analyzeBursts()
        try await wait("first shot analyzed") { !model.burstQualities.isEmpty || !model.isAnalyzingBursts }
        model.cancelBurstAnalysis()
        try await wait("stopped") { !model.isAnalyzingBursts }
        if model.burstQualities.count < 4 {
            model.markBurstRecommendations()
            XCTAssertTrue(model.photos.allSatisfy { $0.flag == .none }, "일부만 분석한 묶음은 표시하지 않는다")
            XCTAssertTrue(model.burstRecommendations.isEmpty, "일부만 분석한 묶음은 추천하지 않는다")
        } else {
            print("분석이 멈추기 전에 끝나 부분 분석 검사는 건너뜀")
        }
        model.analyzeBursts()
        try await wait("resumed") { !model.isAnalyzingBursts }
        XCTAssertEqual(model.burstQualities.count, 4, "다시 분석하면 남은 컷을 마저 분석한다")
        let best = model.burstRecommendations.values.first?.bestShot
        XCTAssertEqual(best, 0, "가장 선명한 첫 컷을 추천한다")

        // 읽지 못하는 컷은 추천·표시에서 빠진다.
        let broken = model.photos.first { $0.filename == "frame-3.jpg" }!
        try Data("broken".utf8).write(to: broken.url)
        try model.flushSave()
        let fresh = LibraryModel()
        fresh.start()
        try await wait("reload") { fresh.catalogLoaded }
        fresh.filter = .bursts
        fresh.analyzeBursts()
        try await wait("fresh analysis") { !fresh.isAnalyzingBursts }
        fresh.markBurstRecommendations()
        let flags = Dictionary(uniqueKeysWithValues: fresh.photos.map { ($0.filename, $0.flag) })
        XCTAssertEqual(flags["frame-0.jpg"], .pick)
        XCTAssertEqual(flags["frame-1.jpg"], .reject)
        XCTAssertEqual(flags["frame-2.jpg"], .reject)
        XCTAssertEqual(flags["frame-3.jpg"], PhotoFlag.none, "읽지 못한 컷은 표시하지 않는다")
    }
}
