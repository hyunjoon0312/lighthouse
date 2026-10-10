import AppKit
import SwiftUI
@testable import Lighthouse
import XCTest

/// 앱 안 도움말: 주제·항목이 고르게 있고, 검색이 도움말과 단축키를 함께 찾으며, 적힌 메뉴 경로가 실제 메뉴에 있다.
@MainActor
final class HelpGuideTests: XCTestCase {
    func testTopicsHaveItemsWithDistinctTitles() {
        XCTAssertGreaterThanOrEqual(HelpGuide.topics.count, 5)
        for topic in HelpGuide.topics {
            XCTAssertGreaterThanOrEqual(topic.items.count, 3, "\(topic.title) 주제가 너무 얇다")
            XCTAssertFalse(topic.summary.isEmpty)
        }
        let titles = HelpGuide.topics.flatMap(\.items).map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "같은 제목의 항목이 있다")
    }

    /// 낱말이 모두 든 항목을 찾고, 단축키 표의 줄도 함께 찾는다. 대소문자는 가리지 않는다.
    func testSearchFindsHelpItemsAndShortcuts() {
        XCTAssertTrue(HelpGuide.search("라벨 이름").contains { $0.title == "라벨 이름" })
        XCTAssertTrue(HelpGuide.search("drive").contains { $0.title.contains("Google Drive") })
        let rotation = HelpGuide.search("회전")
        XCTAssertTrue(rotation.contains { $0.keys == "⌘[ / ⌘]" }, "단축키 표에서도 찾는다")
        XCTAssertTrue(HelpGuide.search("원본 없음 폴더").contains { $0.title == "원본 없음" }, "낱말이 모두 들어 있어야 한다")
        XCTAssertEqual(HelpGuide.search("   "), [])
        XCTAssertEqual(HelpGuide.search("없는낱말없는낱말"), [])
    }

    /// 도움말에 적은 메뉴 경로(파일 › 사진 가져오기…)의 항목 이름이 실제 메뉴에 있다.
    func testMenuPathsExistInTheAppMenus() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Lighthouse/LighthouseApp.swift"), encoding: .utf8)
        let paths = HelpGuide.topics.flatMap(\.items).flatMap(\.menus)
        XCTAssertGreaterThan(paths.count, 15)
        for path in paths {
            let parts = path.components(separatedBy: " › ")
            XCTAssertTrue(["파일", "편집", "보기", "사진", "도움말"].contains(parts[0]), "\(path): 없는 메뉴")
            XCTAssertGreaterThanOrEqual(parts.count, 2, path)
            for item in parts.dropFirst() {
                XCTAssertTrue(source.contains("(\"" + item), "\(path): 메뉴에 '\(item)' 항목이 없다")
            }
        }
    }

    /// ⌘?(⇧⌘/)는 "/" 키 자리로 읽어 도움말을 연다. 메뉴에 두면 SwiftUI가 이 단축키를 붙이지 않아 ⌘/(단축키 보기)로 넘어갔다.
    func testCommandQuestionMarkIsTheHelpKey() {
        XCTAssertTrue(HelpGuide.isHelpKey(keyCode: 44, modifiers: [.command, .shift]))
        XCTAssertTrue(HelpGuide.isHelpKey(keyCode: 44, modifiers: [.command, .shift, .capsLock]), "Caps Lock은 상관없다")
        XCTAssertFalse(HelpGuide.isHelpKey(keyCode: 44, modifiers: [.shift]), "?는 단축키 창")
        XCTAssertFalse(HelpGuide.isHelpKey(keyCode: 44, modifiers: [.command]), "⌘/는 단축키 메뉴")
        XCTAssertFalse(HelpGuide.isHelpKey(keyCode: 44, modifiers: [.command, .shift, .option]))
        XCTAssertFalse(HelpGuide.isHelpKey(keyCode: 43, modifiers: [.command, .shift]), "다른 키")
    }

    /// 창의 키 감시가 ⌘?(⇧⌘/)를 메뉴보다 먼저 받아 도움말을 열고, 단축키 창(⌘/)으로 넘기지 않는다.
    func testKeyMonitorOpensHelpForCommandQuestionMark() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WorkspaceView().environmentObject(model))
        defer { window.contentView = nil }
        try await Task.sleep(nanoseconds: 500_000_000)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "?", charactersIgnoringModifiers: "?",
            isARepeat: false, keyCode: 44))
        // 키 감시는 앱이 이벤트를 나눠 보낼 때(sendEvent) 메뉴 단축키보다 먼저 본다.
        NSApp.sendEvent(event)
        XCTAssertTrue(model.showHelp)
        XCTAssertFalse(model.showShortcuts)
        model.showHelp = false
    }

    /// 도움말 창이 떠 있는 동안에는 뒤 창의 한 글자 단축키가 동작하지 않는다(검색 칸에 입력할 수 있게).
    func testHelpIsModal() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 0)
        XCTAssertFalse(model.hasModalPresentation)
        model.showHelp = true
        XCTAssertTrue(model.hasModalPresentation)
        model.showHelp = false
    }
}
