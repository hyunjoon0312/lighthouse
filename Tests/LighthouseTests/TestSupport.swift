import AppKit
import Foundation
import ImageIO
@testable import Lighthouse
import UniformTypeIdentifiers
import XCTest

enum TestSupport {
    struct Timeout: Error, CustomStringConvertible {
        let label: String
        var description: String { "시간 초과: \(label)" }
    }

    /// 테스트가 끝나면 지워지는 폴더. 카탈로그와 사진을 모두 여기에 둔다.
    static func temporaryDirectory(_ test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighthouse-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 실제 S9 RW2 표본. 원본은 읽기만 하고, 테스트는 임시 폴더의 복사본을 쓴다.
    static var rawSample: URL? {
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

    /// 연속 촬영 추천의 얼굴 품질 표본(burst-1-sharp.jpg 등 4장이 든 폴더). 없으면 nil이다.
    static var faceBurstSamples: URL? {
        let fromEnvironment = ProcessInfo.processInfo.environment["LIGHTHOUSE_SAMPLE_FACES"].map { URL(fileURLWithPath: $0) }
        var candidates = fromEnvironment.map { [$0] } ?? []
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            directory.deleteLastPathComponent()
            candidates.append(directory.appendingPathComponent(".artifacts/samples/faces"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("burst-1-sharp.jpg").path) }
    }

    /// `ready`가 참이 될 때까지 기다린다. 시간을 넘기면 실패로 기록하고 멈춘다.
    @MainActor
    static func wait(_ label: String, timeout: Double = 60, _ ready: () -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if ready() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("시간 초과: \(label)")
        throw Timeout(label: label)
    }

    /// 만든 사진 한 장. `properties`로 촬영 정보(EXIF·TIFF 사전)를 넣는다.
    static func writeJPEG(_ url: URL, width: Int = 64, height: Int = 48, color: (UInt8, UInt8, UInt8) = (120, 130, 140),
                          properties: [CFString: Any] = [:]) throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = color.0; bytes[index + 1] = color.1; bytes[index + 2] = color.2
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Timeout(label: "JPEG 쓰기 실패") }
    }

    /// 격리한 카탈로그로 시작해 만든 사진 `count`장을 가져온 모델. 촬영 시각은 1분 간격이라 순서가 정해진다.
    /// `properties(index)`로 사진마다 촬영 정보를 더 넣을 수 있다.
    @MainActor
    static func startedModel(_ test: XCTestCase, photos count: Int,
                             properties: (Int) -> [CFString: Any] = { _ in [:] }) async throws
        -> (model: LibraryModel, root: URL, urls: [URL]) {
        resetModelDefaults()
        _ = NSApplication.shared
        let root = try temporaryDirectory(test)
        setenv("LIGHTHOUSE_DATA_DIR", root.appendingPathComponent("data").path, 1)
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for index in 0..<count {
            let url = folder.appendingPathComponent(String(format: "photo-%02d.jpg", index))
            var extra = properties(index)
            var exif = extra[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = String(format: "2026:09:20 10:%02d:00", index)
            extra[kCGImagePropertyExifDictionary] = exif
            try writeJPEG(url, color: (UInt8(40 + index * 9 % 200), 120, 160), properties: extra)
            urls.append(url)
        }
        let model = LibraryModel()
        model.start()
        try await wait("catalog") { model.catalogLoaded && model.foldersLoaded }
        if count > 0 {
            model.importURLs(urls)
            try await wait("import") { !model.isImporting && model.photos.count == count }
        }
        return (model, root, urls)
    }

    /// 모델이 기억하는 화면 설정을 지워 테스트마다 같은 상태에서 시작한다(xctest의 기본 설정 영역만 바뀐다).
    static func resetModelDefaults() {
        for key in ["autoAdvanceAfterMark", "collapseRAWJPEGPairs", "comparePinnedEdits", "importPresetID", "photoSortOrder",
                    "writesXMPSidecars"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
