import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 6–9 키로 라벨 붙이기·떼기, 실행 취소, 라벨로 거르기.
@MainActor
final class ColorLabelFlowTests: XCTestCase {
    func testKeyTogglesLabelUndoAndFilter() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let photos = model.photos
        model.focusPhoto(photos[0])
        model.markFromKeyboard(toggleLabel: PhotoColorLabel.forKey("6"))
        XCTAssertEqual(model.photo(withID: photos[0].id)?.colorLabel, .red)
        model.markFromKeyboard(toggleLabel: .red)
        XCTAssertNil(model.photo(withID: photos[0].id)?.colorLabel, "같은 키를 다시 누르면 뗀다")
        model.undo()
        XCTAssertEqual(model.photo(withID: photos[0].id)?.colorLabel, .red, "떼기도 한 단계로 되돌린다")

        model.autoAdvance = true
        model.focusPhoto(photos[1])
        model.markFromKeyboard(toggleLabel: .blue)
        XCTAssertEqual(model.selectedID, photos[2].id, "표시 후 다음 사진이 켜져 있으면 넘어간다")
        model.criteria.colorLabel = .blue
        XCTAssertEqual(model.visiblePhotos.map(\.id), [photos[1].id])
        model.criteria.colorLabel = .red
        model.focusPhoto(photos[0])
        model.setColorLabel(.purple)
        XCTAssertTrue(model.visiblePhotos.isEmpty, "라벨을 바꾸면 조건에서 빠진다")
    }

    /// 라벨에 쓰임을 이름으로 붙이면(빨강 → 블로그) 메뉴·조건 요약에 이름으로 보이고, 라이브러리를 다시 열어도 남는다.
    func testLabelNamesShowInMenusAndSummaryAndPersist() async throws {
        UserDefaults.standard.removeObject(forKey: "colorLabelNames")
        defer { UserDefaults.standard.removeObject(forKey: "colorLabelNames") }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        model.setColorLabelNames([.red: "  블로그  ", .green: " ", .blue: String(repeating: "가", count: 30)])
        XCTAssertEqual(model.colorLabelNames, [.red: "블로그", .blue: String(repeating: "가", count: 20)],
                       "앞뒤 공백과 빈 이름은 버리고 20자로 줄인다")
        XCTAssertEqual(model.labelName(.red), "블로그")
        XCTAssertEqual(model.labelName(.green), "초록", "이름이 없으면 색 이름")
        XCTAssertEqual(model.labelMenuTitle(.red), "블로그 · 빨강")
        XCTAssertEqual(model.labelMenuTitle(.green), "초록")
        var criteria = model.criteria
        criteria.colorLabel = .red
        XCTAssertEqual(criteria.summary(labelName: model.labelName), ["블로그 라벨"])

        // 새 모델은 Mac 환경설정에서 이름을 읽는다(TestSupport.startedModel은 시작할 때 설정을 지우므로 직접 만든다).
        let reopened = LibraryModel()
        XCTAssertEqual(reopened.labelName(.red), "블로그", "Mac 환경설정에 남는다")
        reopened.setColorLabelNames([:])
        XCTAssertEqual(reopened.labelMenuTitle(.red), "빨강")
    }
}
