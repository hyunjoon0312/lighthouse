import Foundation
import LighthouseCore

/// 별점·표시·키워드·설명. 한 번에 바꾼 것은 한 단계로 실행 취소된다.
@MainActor
extension LibraryModel {
    func setRating(_ rating: Int) {
        guard let id = selectedID else { return }
        changeMarks(of: id) { $0.rating = rating }
    }

    func setFlag(_ flag: PhotoFlag) {
        guard let id = selectedID else { return }
        changeMarks(of: id) { $0.flag = flag }
    }

    /// 키보드로 별점·표시를 바꾼다. 자동 다음 사진이 켜져 있으면 바꾸기 전에 정한 다음 사진으로 넘어가므로
    /// 필터 때문에 방금 표시한 사진이 목록에서 빠져도 한 장을 건너뛰지 않는다.
    func markFromKeyboard(rating: Int? = nil, flag: PhotoFlag? = nil) {
        guard let id = selectedID else { return }
        let visible = visiblePhotos
        let next = autoAdvance ? visible.firstIndex(where: { $0.id == id }).flatMap { index in
            visible.indices.contains(index + 1) ? visible[index + 1].id : nil
        } : nil
        changeMarks(of: id) { marks in
            if let rating { marks.rating = rating }
            if let flag { marks.flag = flag }
        }
        if let next, let photo = visiblePhotos.first(where: { $0.id == next }) {
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
