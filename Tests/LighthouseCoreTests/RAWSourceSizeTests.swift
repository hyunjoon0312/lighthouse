import CoreImage
import Foundation
import XCTest
@testable import LighthouseCore

/// RAW를 줄여 현상할 배율을 정할 때 쓰는 원본 크기. 실제 S9 RW2로 확인하며 표본이 없으면 건너뛴다.
final class RAWSourceSizeTests: XCTestCase {
    private var rawSample: URL? {
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

    func testPropertySizeMatchesRAWDecoderIncludingRotation() throws {
        guard let sample = rawSample else {
            throw XCTSkip("RAW 표본이 없습니다. LIGHTHOUSE_SAMPLE_RW2에 S9 RW2 경로를 지정하세요.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // 복사본의 방향 태그(0x0112, SHORT 1개, 값 1)를 6(90° 회전)으로 바꾼 세로 사진. 원본은 읽기만 한다.
        var bytes = try Data(contentsOf: sample)
        let entry: [UInt8] = [0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00]
        var patched = 0
        for offset in 0..<min(bytes.count, 65_536) - entry.count where bytes[offset..<offset + entry.count].elementsEqual(entry) {
            bytes[offset + 8] = 6
            patched += 1
        }
        XCTAssertGreaterThan(patched, 0)
        let rotated = directory.appendingPathComponent("rotated.RW2")
        try bytes.write(to: rotated)

        let pipeline = ImagePipeline()
        for url in [sample, rotated] {
            let decoded = try XCTUnwrap(CIRAWFilter(imageURL: url)?.outputImage?.extent.size)
            XCTAssertEqual(pipeline.sourceSize(url: url), decoded, url.lastPathComponent)
        }
        XCTAssertEqual(pipeline.sourceSize(url: rotated), CGSize(width: 4000, height: 6000))
        XCTAssertEqual(pipeline.decodeScale(url: sample, edits: .neutral, maxPixel: 2200), pow(2, -0.75), accuracy: 1e-9)
    }

    /// 100%로 바꿀 때 먼저 늘려 보이는 크기가 원본 크기 렌더와 같아야 선명한 그림으로 바뀔 때 화면이 튀지 않는다.
    func testOutputSizeMatchesFullRAWRender() throws {
        guard let sample = rawSample else {
            throw XCTSkip("RAW 표본이 없습니다. LIGHTHOUSE_SAMPLE_RW2에 S9 RW2 경로를 지정하세요.")
        }
        let pipeline = ImagePipeline()
        let edits = EditSettings(rotationQuarterTurns: 3, cropRect: NormalizedCrop(x: 0.1, y: 0.2, width: 0.6, height: 0.5))
        let image = try pipeline.render(url: sample, edits: edits, maxPixel: nil)
        XCTAssertEqual(pipeline.outputSize(url: sample, edits: edits), CGSize(width: image.width, height: image.height))
    }
}
