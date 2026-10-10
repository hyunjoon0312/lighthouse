import AppKit
import XCTest

/// 화면 코드가 쓰는 SF Symbol 이름이 이 macOS에 실제로 있는지. 없는 이름은 아이콘 없이 빈 자리로 그려진다.
final class SymbolNameTests: XCTestCase {
    func testEveryUISymbolExists() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Lighthouse")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"(?:systemName|systemImage|icon): "([a-z0-9.]+)""#)
        var names: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names[String(text[range])] = file.lastPathComponent }
            }
        }
        XCTAssertGreaterThan(names.count, 30, "기호 이름을 찾지 못했다")
        let missing = names.filter { NSImage(systemSymbolName: $0.key, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [:], "없는 SF Symbol")
    }
}
