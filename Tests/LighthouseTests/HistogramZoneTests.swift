@testable import Lighthouse
import LighthouseCore
import XCTest

/// 히스토그램을 끌어 바꾸는 구간(왼쪽부터 검정·섀도·노출·하이라이트·흰색)과 끈 거리만큼의 값.
final class HistogramZoneTests: XCTestCase {
    func testZonesSplitTheWidthLikeLightroom() {
        XCTAssertEqual([0, 0.05, 0.2, 0.5, 0.8, 0.95, 1].map(HistogramZone.at),
                       [.blacks, .blacks, .shadows, .exposure, .highlights, .whites, .whites])
        XCTAssertEqual(HistogramZone.at(-0.2), .blacks, "창 밖으로 나가도 양 끝 구간")
        XCTAssertEqual(HistogramZone.at(1.4), .whites)
        XCTAssertEqual(HistogramZone.allCases.map(\.title), ["검정", "섀도", "노출", "하이라이트", "흰색"])
    }

    /// 히스토그램 너비만큼 끌면 슬라이더 범위의 절반만큼 바뀌고, 슬라이더 범위를 넘지 않는다.
    func testDragMovesHalfTheSliderRangePerWidth() {
        XCTAssertEqual(HistogramZone.exposure.value(from: 0, dragged: 130, width: 260), 2, accuracy: 0.0001)
        XCTAssertEqual(HistogramZone.exposure.value(from: 3.5, dragged: 260, width: 260), 4, "노출은 +4 EV까지")
        XCTAssertEqual(HistogramZone.blacks.value(from: 0, dragged: -52, width: 260), -0.2, accuracy: 0.0001)
        XCTAssertEqual(HistogramZone.highlights.value(from: 1, dragged: -400, width: 260), 0, "하이라이트는 0까지")
    }

    /// 아래 글줄에는 오른쪽 패널 슬라이더와 같은 모양으로 값을 보인다(노출은 EV, 나머지는 보정 안 한 값과의 차이).
    func testValueTextMatchesTheSliders() {
        XCTAssertEqual(HistogramZone.exposure.valueText(0.35), "0.35 EV")
        XCTAssertEqual(HistogramZone.shadows.valueText(EditSettings.neutral.shadows + 0.2), "+20")
        XCTAssertEqual(HistogramZone.highlights.valueText(EditSettings.neutral.highlights), "0")
    }

    /// 끄는 동안의 값은 끌기 시작 값에서 끈 거리만큼이고(누적하지 않음), 한 번 끈 것은 실행 취소 한 단계다.
    /// 두 번 누르면 그 구간만 기본값으로 돌아가고, 원본 보기에서는 바꾸지 않는다.
    @MainActor
    func testDragChangesOneZoneAsOneUndoStep() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        model.select(model.visiblePhotos[0])
        func edits() -> EditSettings? { model.selection?.edits }

        let drag = try XCTUnwrap(model.beginHistogramDrag(at: 0.5))
        XCTAssertEqual(drag.zone, .exposure)
        model.dragHistogram(drag, distance: 65, width: 260)
        XCTAssertEqual(edits()?.exposure ?? .nan, 1, accuracy: 0.0001)
        model.dragHistogram(drag, distance: 130, width: 260)
        XCTAssertEqual(edits()?.exposure ?? .nan, 2, accuracy: 0.0001, "끌기 시작 값에서 잰다")
        model.endHistogramDrag()
        model.undo()
        XCTAssertEqual(edits()?.exposure, 0)

        let blacks = try XCTUnwrap(model.beginHistogramDrag(at: 0.02))
        model.dragHistogram(blacks, distance: 52, width: 260)
        model.endHistogramDrag()
        XCTAssertEqual(edits()?.blacks ?? .nan, 0.2, accuracy: 0.0001)
        XCTAssertEqual(edits()?.exposure, 0, "다른 구간은 그대로")
        model.resetHistogramZone(at: 0.02)
        XCTAssertEqual(edits()?.blacks, EditSettings.neutral.blacks)
        model.undo()
        XCTAssertEqual(edits()?.blacks ?? .nan, 0.2, accuracy: 0.0001, "기본값으로 돌리기도 한 단계")

        model.toggleOriginal()
        XCTAssertNil(model.beginHistogramDrag(at: 0.5), "원본 보기에서는 바뀐 값이 보이지 않아 끌지 않는다")
    }
}
