import Foundation
@testable import Lighthouse
import XCTest

/// 앱 안의 단축키 안내와 README 단축키 표가 같은 키를 다루는지.
final class ShortcutGuideTests: XCTestCase {
    func testGuideMatchesReadmeTable() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        let table = try XCTUnwrap(text.components(separatedBy: "## 단축키").dropFirst().first?
            .components(separatedBy: "\n## ").first)
        let readmeKeys = table.split(separator: "\n").compactMap { line -> String? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            guard line.hasPrefix("|"), cells.count >= 3 else { return nil }
            let key = cells[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "")
            return key == "키" || key.allSatisfy { $0 == "-" || $0 == " " } ? nil : key
        }
        let guideKeys = ShortcutGuide.sections.flatMap(\.entries).map(\.keys)
        XCTAssertEqual(Set(guideKeys).count, guideKeys.count, "안내에 같은 키가 두 번 있다")
        XCTAssertEqual(Set(readmeKeys), Set(guideKeys))
    }
}
