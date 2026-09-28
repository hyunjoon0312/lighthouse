import Foundation
import LighthouseCore

/// 별점·표시·키워드·설명. 한 번에 바꾼 것은 한 단계로 실행 취소된다.
@MainActor
extension LibraryModel {
    /// 별점·표시·라벨을 붙일 사진. 그리드에서 두 장 이상 골랐으면 고른 사진 모두, 아니면 기준 사진 한 장이다.
    /// 사진·비교·여러 장 보기에서는 보고 있는 한 장에만 붙인다.
    var markTargetIDs: [UUID] {
        if mode == .grid, selectedPhotos.count >= 2 { return selectedPhotos.map(\.id) }
        return selectedID.map { [$0] } ?? []
    }

    var markTargetPhotos: [PhotoAsset] { markTargetIDs.compactMap(photo(withID:)) }

    var commonMarkRating: Int? { commonMarkValue(\.rating) }
    var commonMarkFlag: PhotoFlag? { commonMarkValue(\.flag) }
    var commonMarkColorLabel: PhotoColorLabel? { commonMarkValue(\.colorLabel) ?? nil }
    var canClearMarkFlags: Bool { markTargetPhotos.contains { $0.flag != .none } }
    var hasMixedMarks: Bool {
        guard let first = markTargetPhotos.first else { return false }
        return markTargetPhotos.dropFirst().contains {
            $0.rating != first.rating || $0.flag != first.flag || $0.colorLabel != first.colorLabel
        }
    }

    private func commonMarkValue<Value: Equatable>(_ keyPath: KeyPath<PhotoAsset, Value>) -> Value? {
        guard let first = markTargetPhotos.first?[keyPath: keyPath],
              markTargetPhotos.dropFirst().allSatisfy({ $0[keyPath: keyPath] == first }) else { return nil }
        return first
    }

    func setRating(_ rating: Int) {
        changeMarks(of: markTargetIDs) { $0.rating = rating }
    }

    func setFlag(_ flag: PhotoFlag) {
        changeMarks(of: markTargetIDs) { $0.flag = flag }
    }

    func setColorLabel(_ label: PhotoColorLabel?) {
        changeMarks(of: markTargetIDs) { $0.colorLabel = label }
    }

    func toggleMarkRating(_ value: Int) {
        let targets = markTargetPhotos
        guard !targets.isEmpty else { return }
        let replacement = targets.allSatisfy { $0.rating == value } ? 0 : value
        changeMarks(of: targets.map(\.id)) { $0.rating = replacement }
    }

    func toggleMarkColorLabel(_ value: PhotoColorLabel) {
        let targets = markTargetPhotos
        guard !targets.isEmpty else { return }
        let replacement: PhotoColorLabel? = targets.allSatisfy { $0.colorLabel == value } ? nil : value
        changeMarks(of: targets.map(\.id)) { $0.colorLabel = replacement }
    }

    /// 키보드로 별점·표시·라벨을 바꾼다. 자동 다음 사진이 켜져 있으면 바꾸기 전에 정한 다음 사진으로 넘어가므로
    /// 필터 때문에 방금 표시한 사진이 목록에서 빠져도 한 장을 건너뛰지 않는다.
    /// `toggleLabel`은 이미 그 라벨이면 떼고, 아니면 붙인다. 그리드에서 여러 장을 골랐으면 모두에 붙이고
    /// (모두 그 라벨이면 떼고) 다음 사진으로 넘어가지 않는다.
    func markFromKeyboard(rating: Int? = nil, flag: PhotoFlag? = nil, toggleLabel: PhotoColorLabel? = nil) {
        let targets = markTargetIDs
        if targets.count > 1 {
            let removesLabel = toggleLabel != nil && targets.allSatisfy { photo(withID: $0)?.colorLabel == toggleLabel }
            changeMarks(of: targets) { marks in
                if let rating { marks.rating = rating }
                if let flag { marks.flag = flag }
                if toggleLabel != nil { marks.colorLabel = removesLabel ? nil : toggleLabel }
            }
            return
        }
        guard let id = selectedID else { return }
        // 여러 장 보기에서는 비교 중인 사진 안에서만 넘어가 선택이 풀리지 않게 한다.
        let visible = mode == .survey ? surveyPhotos : visiblePhotos
        let next = autoAdvance ? visible.firstIndex(where: { $0.id == id }).flatMap { index in
            visible.indices.contains(index + 1) ? visible[index + 1].id : nil
        } : nil
        changeMarks(of: id) { marks in
            if let rating { marks.rating = rating }
            if let flag { marks.flag = flag }
            if let toggleLabel { marks.colorLabel = marks.colorLabel == toggleLabel ? nil : toggleLabel }
        }
        if let next, let photo = (mode == .survey ? surveyPhotos : visiblePhotos).first(where: { $0.id == next }) {
            moveDirection = 1
            focusPhoto(photo)
        }
    }

    private func changeMarks(of id: UUID, _ change: (inout PhotoMarks) -> Void) {
        changeMarks(of: [id], change)
    }

    /// 여러 장의 별점·표시·키워드·설명을 한 번의 실행 취소 단계로 바꾼다.
    private func changeMarks(of ids: [UUID], _ change: (inout PhotoMarks) -> Void) {
        guard catalogLoaded, loadError == nil else { return }
        var changes: [PhotoMarkChange] = []
        for id in ids {
            guard let photo = photo(withID: id) else { continue }
            var after = photo.marks
            change(&after)
            if after != photo.marks { changes.append(PhotoMarkChange(id: id, before: photo.marks, after: after)) }
        }
        guard !changes.isEmpty else { return }
        editHistory.recordMarks(changes)
        for change in changes { applyMarks(change.after, to: change.id) }
    }

    func applyMarks(_ marks: PhotoMarks, to id: UUID) {
        updatePhoto(id) { $0.marks = marks }
        scheduleSidecarWrite(id)
    }

    // MARK: 키워드·설명

    /// 쉼표로 구분한 키워드로 바꾼다. 입력하는 동안 다른 사진으로 옮겨도 입력을 시작한 사진에 적용한다.
    func setKeywords(_ text: String, for id: UUID) {
        changeMarks(of: id) { $0.keywords = PhotoKeywords.parse(text) }
    }

    func setCaption(_ text: String, for id: UUID) {
        let caption = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        changeMarks(of: id) { $0.caption = caption }
    }

    /// 선택한 사진마다 기존 키워드 뒤에 붙인다. 한 번에 실행 취소된다.
    func addKeywordsToSelection(_ text: String) {
        let added = PhotoKeywords.parse(text)
        guard !added.isEmpty else { return }
        let ids = actionTargets.map(\.id)
        changeMarks(of: ids) { $0.keywords = PhotoKeywords.merge($0.keywords, added) }
        operationMessage = "\(ids.count)장에 키워드 \(PhotoKeywords.text(added))를 붙였습니다."
    }
}
