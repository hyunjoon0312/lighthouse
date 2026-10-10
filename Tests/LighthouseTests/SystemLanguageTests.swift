import AppKit
@testable import Lighthouse
import XCTest

/// macOS가 그려 주는 부분(메뉴 막대의 시스템 항목, 열기·저장 창, 오류 문구)도 앱과 같은 한국어로 보이는지.
final class SystemLanguageTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 현지화를 밝히지 않은 앱은 한국어 Mac에서도 시스템 메뉴(Edit·Cut·Quit…)와 오류 설명을 영어로 받는다.
    func testBundleDeclaresKorean() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "ko")
        XCTAssertEqual(plist["CFBundleLocalizations"] as? [String], ["ko"])
    }

    /// 라이브러리 창은 하나라 창 탭 메뉴(탭 막대 보기·모든 탭 보기 등)를 두지 않는다.
    @MainActor
    func testWindowTabbingIsOff() {
        NSWindow.allowsAutomaticWindowTabbing = true
        let delegate: NSApplicationDelegate = AppDelegate()
        delegate.applicationWillFinishLaunching?(Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    /// SwiftUI는 화면 문자열 리터럴을 Markdown으로 읽는다. `(\\)`처럼 Markdown이 글자를 바꾸는 리터럴은 쓴 대로 보이지 않는다.
    func testLiteralUIStringsRenderAsWritten() throws {
        let sources = root.appendingPathComponent("Sources/Lighthouse")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        // 화면 문자열을 받는 호출이 있는 줄의 리터럴을 모두 본다(`Button(조건 ? "…" : "…")`처럼 삼항으로 고르는 이름 포함).
        let call = try NSRegularExpression(pattern:
            #"\b(?:Text|Button|Toggle|Label|Menu|Picker|TextField|Section|ProgressView|help|accessibilityLabel|accessibilityHint)\("#)
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        var checked = 0
        var altered: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n").map(String.init) where !line.contains(#"""""#)
                && call.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                for match in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    // `Text(verbatim:)`의 글자는 Markdown으로 읽지 않는다.
                    if line[..<range.lowerBound].contains("verbatim:") { continue }
                    // 보간과 유니코드 이스케이프는 컴파일러가 따로 다루므로 건너뛴다.
                    guard let value = Self.unescape(String(line[range])) else { continue }
                    checked += 1
                    let rendered = try AttributedString(markdown: value,
                                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                    if String(rendered.characters) != value {
                        altered.append("\(file.lastPathComponent): \(value) → \(String(rendered.characters))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 200, "화면 문자열을 찾지 못했다")
        XCTAssertEqual(altered, [], "Markdown 때문에 쓴 대로 보이지 않는 문자열")
    }

    private static func unescape(_ literal: String) -> String? {
        var result = "", escaping = false
        for character in literal {
            if escaping {
                switch character {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "'": result.append("'")
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: return nil
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return escaping ? nil : result
    }
}
