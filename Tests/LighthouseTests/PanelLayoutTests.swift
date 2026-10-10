@testable import Lighthouse
import XCTest

/// 끌어서 정한 패널 너비가 가운데 사진 영역을 위쪽 막대가 들어가는 너비보다 좁히지 않는지.
final class PanelLayoutTests: XCTestCase {
    func testDefaultsFitSmallestWindowExactly() {
        let widths = PanelLayout.widths(total: 1100, sidebar: PanelLayout.sidebarDefault,
                                        inspector: PanelLayout.inspectorDefault, showsSidebar: true, showsInspector: true)
        XCTAssertEqual(widths.sidebar, 224)
        XCTAssertEqual(widths.inspector, 300)
        XCTAssertEqual(1100 - widths.sidebar - widths.inspector - 2, PanelLayout.minimumCenter)
    }

    func testStoredWidthsKeptWhenWindowHasRoom() {
        let widths = PanelLayout.widths(total: 1800, sidebar: 320, inspector: 460, showsSidebar: true, showsInspector: true)
        XCTAssertEqual(widths.sidebar, 320)
        XCTAssertEqual(widths.inspector, 460)
    }

    func testStoredWidthsClampedToRange() {
        let widths = PanelLayout.widths(total: 3000, sidebar: 40, inspector: 2000, showsSidebar: true, showsInspector: true)
        XCTAssertEqual(widths.sidebar, PanelLayout.sidebarRange.lowerBound)
        XCTAssertEqual(widths.inspector, PanelLayout.inspectorRange.upperBound)
    }

    /// 창을 줄이면 오른쪽 패널부터 기본 너비까지 줄이고, 그래도 모자라면 사이드바를 줄인다.
    func testShrinkingWindowNarrowsInspectorThenSidebar() {
        let widths = PanelLayout.widths(total: 1100, sidebar: 360, inspector: 520, showsSidebar: true, showsInspector: true)
        XCTAssertEqual(widths.inspector, PanelLayout.inspectorRange.lowerBound)
        XCTAssertEqual(widths.sidebar, 1100 - 2 - PanelLayout.minimumCenter - PanelLayout.inspectorRange.lowerBound)
    }

    func testHiddenPanelGivesRoomToTheOther() {
        let widths = PanelLayout.widths(total: 1100, sidebar: 360, inspector: 520, showsSidebar: false, showsInspector: true)
        XCTAssertEqual(widths.sidebar, 0)
        XCTAssertEqual(widths.inspector, 520)
    }

    /// 끄는 동안에는 다른 패널을 밀지 않고, 가운데가 최소 너비에 닿으면 더 넓어지지 않는다.
    func testDragStopsAtRoomWithoutMovingOtherPanel() {
        XCTAssertEqual(PanelLayout.dragged(500, range: PanelLayout.inspectorRange, total: 1100, other: 224, dividers: 2), 300)
        XCTAssertEqual(PanelLayout.dragged(500, range: PanelLayout.inspectorRange, total: 1400, other: 224, dividers: 2), 500)
        XCTAssertEqual(PanelLayout.dragged(100, range: PanelLayout.sidebarRange, total: 1400, other: 300, dividers: 2), 180)
    }
}
