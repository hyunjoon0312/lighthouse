import AppKit
import Foundation
import LighthouseCore

/// 스팟 복구·복제와 화면↔원본 좌표.
@MainActor
extension LibraryModel {
    func beginRetouch(at displayPoint: MaskPoint) {
        guard canUseRetouchCanvas else { return }
        if retouchMode == .clone && isPickingCloneSource {
            cloneSource = sourcePoint(fromDisplay: displayPoint)
            isPickingCloneSource = false
            retouchCursor = displayPoint
            return
        }
        guard canDrawRetouch else { return }
        retouchError = nil
        retouchDraftPoints = [displayPoint]
        retouchCursor = displayPoint
    }

    func extendRetouch(to displayPoint: MaskPoint, shortSide: CGFloat) {
        guard canDrawRetouch, let last = retouchDraftPoints.last else { return }
        retouchCursor = displayPoint
        let dx = (displayPoint.x - last.x) * Double(shortSide)
        let dy = (displayPoint.y - last.y) * Double(shortSide)
        if hypot(dx, dy) >= max(1, retouchRadius * Double(shortSide) * 0.2) {
            retouchDraftPoints.append(displayPoint)
        }
    }

    func commitRetouch() {
        guard canDrawRetouch, let selected = selection, !retouchDraftPoints.isEmpty else {
            cancelRetouchDraft(); return
        }
        let geometry = PhotoGeometry(sourceWidth: Double(selected.metadata.width),
                                     sourceHeight: Double(selected.metadata.height), edits: selected.edits)
        let points = retouchDraftPoints.map { geometry.sourcePoint(fromDisplay: $0) }
        let offset: MaskPoint?
        if retouchMode == .clone, let source = cloneSource, let destination = points.first {
            offset = MaskPoint(x: source.x - destination.x, y: source.y - destination.y)
        } else {
            offset = nil
        }
        let stroke = RetouchStroke(mode: retouchMode, points: points,
                                   radius: retouchRadius, sourceOffset: offset)
        guard stroke.mode == .heal else {
            var edits = selected.edits
            edits.retouchStrokes.append(stroke)
            cancelRetouchDraft()
            updateEdits(edits)
            return
        }
        findHealSource(for: stroke, in: selected)
    }

    /// 패치 위치를 한 번 찾아 stroke에 저장한다. 찾는 동안 그린 경로는 화면에 남겨 둔다.
    private func findHealSource(for stroke: RetouchStroke, in photo: PhotoAsset) {
        retouchGeneration += 1
        let token = retouchGeneration
        let selectionToken = selectionGeneration
        isFindingHealSource = true
        let maxPixel: Int? = actualSize ? nil : 2200
        retouchQueue.async { [previewPipeline] in
            let result = Result {
                try previewPipeline.healingSourceOffset(url: photo.url, edits: photo.edits, stroke: stroke,
                                                        maxPixel: maxPixel)
            }
            DispatchQueue.main.async {
                guard token == self.retouchGeneration else { return }
                self.isFindingHealSource = false
                self.retouchDraftPoints = []
                guard self.selectedID == photo.id, self.selectionGeneration == selectionToken,
                      let current = self.selection, current.edits == photo.edits else {
                    self.retouchError = "사진이나 보정이 바뀌어 스팟 복구를 적용하지 않았습니다."
                    return
                }
                switch result {
                case .success(let offset):
                    var healed = stroke
                    healed.sourceOffset = offset
                    var edits = current.edits
                    edits.retouchStrokes.append(healed)
                    self.updateEdits(edits)
                case .failure(let error):
                    AppLog.editing.error("heal source search failed: \(error.localizedDescription, privacy: .private)")
                    self.retouchError = error.localizedDescription
                }
            }
        }
    }

    func cancelRetouchDraft(clearSource: Bool = false) {
        retouchGeneration += 1
        isFindingHealSource = false
        retouchDraftPoints = []
        retouchCursor = nil
        isPickingCloneSource = false
        if clearSource { cloneSource = nil }
    }

    func setRetouchStrokeEnabled(_ id: UUID, enabled: Bool) {
        guard let selected = selection,
              let index = selected.edits.retouchStrokes.firstIndex(where: { $0.id == id }) else { return }
        var edits = selected.edits
        edits.retouchStrokes[index].isEnabled = enabled
        updateEdits(edits)
    }

    func deleteRetouchStroke(_ id: UUID) {
        guard let selected = selection else { return }
        var edits = selected.edits
        edits.retouchStrokes.removeAll { $0.id == id }
        updateEdits(edits)
    }

    func clearRetouchStrokes() {
        guard let selected = selection, !selected.edits.retouchStrokes.isEmpty else { return }
        var edits = selected.edits
        edits.retouchStrokes = []
        updateEdits(edits)
    }

    func displayPoint(fromSource point: MaskPoint) -> MaskPoint? {
        guard let selected = selection, selected.metadata.width > 0, selected.metadata.height > 0 else { return nil }
        return PhotoGeometry(sourceWidth: Double(selected.metadata.width),
                             sourceHeight: Double(selected.metadata.height), edits: selected.edits)
            .displayPoint(fromSource: point)
    }

    private func sourcePoint(fromDisplay point: MaskPoint) -> MaskPoint {
        guard let selected = selection else { return point }
        return PhotoGeometry(sourceWidth: Double(selected.metadata.width),
                             sourceHeight: Double(selected.metadata.height), edits: selected.edits)
            .sourcePoint(fromDisplay: point)
    }
}
