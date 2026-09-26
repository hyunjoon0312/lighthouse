import Foundation
import LighthouseCore

/// 보정 기록의 한 줄. `edits`는 그 단계를 마친 상태다.
struct EditTimelineEntry: Identifiable {
    let id: Int
    let title: String
    let edits: EditSettings
}

/// 이번 실행의 보정 기록과 사진마다 저장하는 스냅숏.
@MainActor
extension LibraryModel {
    /// 보고 있는 사진을 이번 실행에서 바꾼 순서(첫 줄은 처음 상태). 실행 취소한 단계는 빠진다.
    var editTimeline: [EditTimelineEntry] {
        guard let id = selectedID else { return [] }
        let changes = editHistory.editChanges(for: id)
        guard let first = changes.first else { return [] }
        return [EditTimelineEntry(id: 0, title: "처음 상태", edits: first.before)] +
            changes.enumerated().map { index, change in
                EditTimelineEntry(id: index + 1, title: change.after.changeSummary(from: change.before), edits: change.after)
            }
    }

    /// 기록이나 스냅숏의 상태로 돌아간다. 새 단계로 남으므로 다시 실행 취소할 수 있다.
    func restoreEdits(_ edits: EditSettings) {
        updateEdits(edits)
    }

    func saveSnapshot(name: String) {
        guard let photo = selection else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let snapshot = EditSnapshot(name: trimmed.isEmpty ? "스냅숏 \(photo.snapshots.count + 1)" : trimmed,
                                    edits: photo.edits)
        updatePhoto(photo.id) { $0.snapshots.append(snapshot) }
        operationMessage = "‘\(snapshot.name)’으로 지금 보정을 저장했습니다."
    }

    func deleteSnapshot(_ id: UUID) {
        guard let photo = selection else { return }
        updatePhoto(photo.id) { $0.snapshots.removeAll { $0.id == id } }
    }
}
