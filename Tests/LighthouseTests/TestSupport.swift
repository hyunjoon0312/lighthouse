import Foundation
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

    /// 모델이 기억하는 화면 설정을 지워 테스트마다 같은 상태에서 시작한다(xctest의 기본 설정 영역만 바뀐다).
    static func resetModelDefaults() {
        for key in ["autoAdvanceAfterMark", "collapseRAWJPEGPairs", "comparePinnedEdits", "importPresetID", "photoSortOrder"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
