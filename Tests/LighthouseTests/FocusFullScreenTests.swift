@testable import Lighthouse
import XCTest

/// 사진만 보기(F)와 창 전체 화면 맞추기. AppKit 전환 알림 순서를 흉내 낸다.
final class FocusFullScreenTests: XCTestCase {
    /// 전체 화면 전환을 흉내 내는 창. 전환 중의 요청은 AppKit처럼 무시한다.
    private struct Window {
        var isFullScreen = false
        var animating = false

        mutating func toggle() {
            guard !animating else { return }
            animating = true
            isFullScreen.toggle()
        }
    }

    private var state = FocusFullScreen()
    private var window = Window()
    private var focused = false

    private func press(_ newFocus: Bool) {
        focused = newFocus
        if state.sync(focused: focused, isFullScreen: window.isFullScreen) {
            window.toggle()
            state.willTransition()
        }
    }

    /// 애니메이션이 끝났을 때의 did 알림.
    private func finishTransition() {
        guard window.animating else { return }
        window.animating = false
        if window.isFullScreen {
            state.didEnter()
        } else if state.didExit(focused: focused) {
            focused = false
        }
        if state.sync(focused: focused, isFullScreen: window.isFullScreen) {
            window.toggle()
            state.willTransition()
        }
    }

    func testEntersAndLeavesFullScreenWithFocusView() {
        press(true)
        finishTransition()
        XCTAssertTrue(window.isFullScreen)
        press(false)
        finishTransition()
        XCTAssertFalse(window.isFullScreen)
        XCTAssertFalse(state.transitioning)
    }

    func testDoublePressDuringEnterEndsWindowed() {
        press(true)
        press(false)
        XCTAssertTrue(window.animating, "두 번째 F는 전환 중이라 미룬다")
        finishTransition()
        XCTAssertTrue(window.animating, "전환이 끝나면 마지막 상태로 다시 나간다")
        finishTransition()
        XCTAssertFalse(window.isFullScreen)
        XCTAssertFalse(focused)
    }

    func testTriplePressDuringEnterStaysFullScreen() {
        press(true)
        press(false)
        press(true)
        finishTransition()
        XCTAssertFalse(window.animating)
        XCTAssertTrue(window.isFullScreen)
        XCTAssertTrue(focused)
    }

    func testPressDuringExitReentersAndKeepsFocusView() {
        press(true)
        finishTransition()
        press(false)
        press(true)
        finishTransition()
        XCTAssertTrue(focused, "앱이 요청한 종료라 사진만 보기를 끝내지 않는다")
        XCTAssertTrue(window.animating)
        finishTransition()
        XCTAssertTrue(window.isFullScreen)
    }

    func testUserExitEndsFocusView() {
        press(true)
        finishTransition()
        window.toggle()
        state.willTransition()
        finishTransition()
        XCTAssertFalse(focused)
        XCTAssertFalse(window.isFullScreen)
        XCTAssertFalse(state.entered)
    }

    func testAlreadyFullScreenWindowStaysFullScreen() {
        window.isFullScreen = true
        press(true)
        XCTAssertFalse(window.animating)
        press(false)
        XCTAssertFalse(window.animating)
        XCTAssertTrue(window.isFullScreen)
    }
}
