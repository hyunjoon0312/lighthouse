import AppKit
import Foundation
import LighthouseCore

/// 부분 보정: 영역·브러시·그라데이션·자동 선택과 마스크 표시.
@MainActor
extension LibraryModel {
    func enterLocalPanel() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        adjustmentPanel = .local
        cancelDraft()
        cancelRetouchDraft()
        isOriginal = false
        actualSize = false
        mode = .edit
        reconcileLocalSelection()
        isLocalEditing = selectedLocal != nil && selectedLocal?.gradient == nil
        requestRender()
    }

    func enterRetouchPanel() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        adjustmentPanel = .retouch
        cancelDraft()
        cancelRetouchDraft()
        isLocalEditing = false
        isOriginal = false
        actualSize = false
        mode = .edit
        maskImage = nil
        maskGeneration += 1
        requestRender()
    }

    func leaveLocalPanel() {
        cancelDraft()
        cancelRetouchDraft()
        isLocalEditing = false
        adjustmentPanel = .global
        maskImage = nil
        maskGeneration += 1
    }

    /// 그라데이션 영역은 조절점 모드로, 브러시 영역은 그리기 모드로 연다. `drawing`을 주면 그 모드로 연다.
    func chooseLocal(_ id: UUID, drawing: Bool? = nil) {
        enterLocalPanel()
        selectedLocalID = id
        isLocalEditing = drawing ?? (selectedLocal?.gradient == nil)
        requestMask()
    }

    func addLocal() {
        guard let selected = selection else { return }
        enterLocalPanel()
        var edits = selected.edits
        let adjustment = LocalAdjustment(name: "영역 \(edits.localAdjustments.count + 1)")
        edits.localAdjustments.append(adjustment)
        selectedLocalID = adjustment.id
        isLocalEditing = true
        updateEdits(edits)
    }

    /// 화면 기준 기본 위치에 그라데이션 영역을 만든다. 직선은 위쪽 하늘을 어둡게, 원형은 가운데를 밝게 시작한다.
    func addGradientLocal(radial: Bool) {
        guard let selected = selection, selected.metadata.width > 0, selected.metadata.height > 0 else { return }
        enterLocalPanel()
        let geometry = LocalMaskGeometry(sourceWidth: Double(selected.metadata.width),
                                         sourceHeight: Double(selected.metadata.height),
                                         edits: selected.edits)
        var edits = selected.edits
        let number = edits.localAdjustments.count + 1
        let adjustment: LocalAdjustment
        if radial {
            adjustment = LocalAdjustment(
                name: "원형 \(number)", exposure: 0.4, feather: 0,
                gradient: .radial(center: geometry.sourcePoint(fromDisplay: MaskPoint(x: 0.5, y: 0.5)),
                                  radiusX: 0.3, radiusY: 0.3, softness: 0.5))
        } else {
            adjustment = LocalAdjustment(
                name: "그라데이션 \(number)", exposure: -0.5, feather: 0,
                gradient: .linear(start: geometry.sourcePoint(fromDisplay: MaskPoint(x: 0.5, y: 0)),
                                  end: geometry.sourcePoint(fromDisplay: MaskPoint(x: 0.5, y: 0.45))))
        }
        edits.localAdjustments.append(adjustment)
        selectedLocalID = adjustment.id
        isLocalEditing = false
        updateEdits(edits)
    }

    /// 드래그 중인 조절점을 화면 좌표 `displayPoint`로 옮긴다. 드래그 한 번은 `endContinuousEdit()`에서 한 단계가 된다.
    func moveGradientHandle(_ handle: MaskGradientHandle, toDisplay displayPoint: MaskPoint) {
        guard canEditGradient, let photo = selection, photo.metadata.width > 0, photo.metadata.height > 0 else { return }
        let geometry = LocalMaskGeometry(sourceWidth: Double(photo.metadata.width),
                                         sourceHeight: Double(photo.metadata.height),
                                         edits: photo.edits)
        let point = geometry.sourcePoint(fromDisplay: displayPoint)
        updateLocal(continuous: true) { area in area.gradient = area.gradient?.moving(handle, to: point) }
    }

    func addAutomaticLocal(background: Bool) {
        guard !isAutoMasking, let photo = selection else { return }
        enterLocalPanel()
        autoMaskGeneration += 1
        let token = autoMaskGeneration
        let photoID = photo.id
        let editsSnapshot = photo.edits
        let selectionToken = selectionGeneration
        isAutoMasking = true
        autoMaskError = nil
        autoMaskQueue.async { [pipeline] in
            let result = Result { try pipeline.subjectMask(url: photo.url) }
            DispatchQueue.main.async {
                guard token == self.autoMaskGeneration else { return }
                self.isAutoMasking = false
                guard self.selectedID == photoID, self.selectionGeneration == selectionToken,
                      let current = self.selection, current.edits == editsSnapshot else {
                    self.autoMaskError = "사진이나 보정이 바뀌어 자동 선택 결과를 적용하지 않았습니다."
                    return
                }
                switch result {
                case .success(let mask):
                    var edits = current.edits
                    let adjustment = LocalAdjustment(
                        name: background ? "자동 배경" : "자동 피사체",
                        baseMask: mask,
                        isInverted: background,
                        automaticMaskKind: background ? .background : .subject
                    )
                    edits.localAdjustments.append(adjustment)
                    self.selectedLocalID = adjustment.id
                    self.isLocalEditing = true
                    self.updateEdits(edits)
                case .failure(let error):
                    AppLog.editing.error("subject mask failed: \(error.localizedDescription, privacy: .private)")
                    self.autoMaskError = "자동 선택 실패: \(error.localizedDescription) 브러시로 영역을 직접 추가할 수 있습니다."
                }
            }
        }
    }

    func cancelAutoMask() {
        autoMaskGeneration += 1
        isAutoMasking = false
    }

    func updateLocal(continuous: Bool = false, _ change: (inout LocalAdjustment) -> Void) {
        guard let selected = selection,
              let index = selected.edits.localAdjustments.firstIndex(where: { $0.id == selectedLocalID }) else { return }
        var edits = selected.edits
        change(&edits.localAdjustments[index])
        updateEdits(edits, continuous: continuous)
    }

    func deleteLocal() {
        guard let selected = selection, let id = selectedLocalID else { return }
        var edits = selected.edits
        edits.localAdjustments.removeAll { $0.id == id }
        selectedLocalID = edits.localAdjustments.first?.id
        if selectedLocalID == nil { isLocalEditing = false }
        updateEdits(edits)
    }

    func finishLocalDrawing() { cancelDraft(); isLocalEditing = false }

    func beginStroke(at displayPoint: MaskPoint) {
        guard canDrawLocal, let photoID = selectedID, let localID = selectedLocalID else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        draftPhotoID = photoID
        draftLocalID = localID
        draftPoints = [displayPoint]
        brushCursor = displayPoint
    }

    func extendStroke(to displayPoint: MaskPoint, shortSide: CGFloat) {
        guard draftPhotoID == selectedID, draftLocalID == selectedLocalID,
              let last = draftPoints.last else { return }
        brushCursor = displayPoint
        let dx = (displayPoint.x - last.x) * Double(shortSide)
        let dy = (displayPoint.y - last.y) * Double(shortSide)
        if hypot(dx, dy) >= max(1, brushRadius * Double(shortSide) * 0.2) {
            draftPoints.append(displayPoint)
        }
    }

    func commitStroke() {
        guard draftPhotoID == selectedID, draftLocalID == selectedLocalID,
              let selected = selection, let index = selected.edits.localAdjustments.firstIndex(where: { $0.id == selectedLocalID }),
              !draftPoints.isEmpty, selected.metadata.width > 0, selected.metadata.height > 0 else {
            cancelDraft(); return
        }
        let geometry = LocalMaskGeometry(sourceWidth: Double(selected.metadata.width),
                                         sourceHeight: Double(selected.metadata.height),
                                         edits: selected.edits)
        let points = draftPoints.map { geometry.sourcePoint(fromDisplay: $0) }
        let stroke = MaskStroke(points: points, radius: brushRadius, isErasing: brushTool == .eraser)
        var edits = selected.edits
        edits.localAdjustments[index].strokes.append(stroke)
        cancelDraft()
        updateEdits(edits)
    }

    func cancelDraft() {
        draftPoints = []
        draftPhotoID = nil
        draftLocalID = nil
        brushCursor = nil
    }

    func reconcileLocalSelection() {
        let areas = selection?.edits.localAdjustments ?? []
        if !areas.contains(where: { $0.id == selectedLocalID }) {
            selectedLocalID = areas.first?.id
            if selectedLocalID == nil { isLocalEditing = false }
        }
    }

    /// 선택한 영역의 마스크 표시를 새로 그린다. 모양·구도가 그대로면 건너뛰고, 그리는 중에 들어온 요청은
    /// 마지막 것만 이어서 그려 조절점을 끄는 동안 작업이 쌓이지 않게 한다.
    func requestMask() {
        maskGeneration += 1
        let token = maskGeneration
        guard adjustmentPanel == .local, showsMask, mode == .edit, !isOriginal, !actualSize,
              let photo = selection, let adjustment = selectedLocal,
              photo.metadata.width > 0, photo.metadata.height > 0 else {
            maskImage = nil; maskError = nil; maskSource = nil; displayedMaskKey = nil; pendingMaskJob = nil; return
        }
        let source = "\(photo.id):\(adjustment.id):\(photo.edits.rotationQuarterTurns):\(photo.edits.straightenDegrees):\(String(describing: photo.edits.cropRect)): \(photo.edits.cropAspect ?? 0)"
        if source != maskSource { maskImage = nil; maskSource = source }
        let key = MaskRequestKey(photoID: photo.id, definition: adjustment.maskDefinition,
                                 rotationQuarterTurns: photo.edits.rotationQuarterTurns,
                                 straightenDegrees: photo.edits.straightenDegrees,
                                 cropRect: photo.edits.cropRect, cropAspect: photo.edits.cropAspect)
        if key == displayedMaskKey, maskImage != nil { pendingMaskJob = nil; return }
        let job = { [pipeline] in
            self.maskQueue.async {
                let result = Result {
                    try pipeline.renderMask(adjustment: adjustment,
                                            sourceWidth: photo.metadata.width,
                                            sourceHeight: photo.metadata.height,
                                            edits: photo.edits, maxPixel: 1600)
                }
                DispatchQueue.main.async {
                    self.maskInFlight = false
                    if token == self.maskGeneration {
                        switch result {
                        case .success(let cg):
                            self.maskError = nil
                            self.maskImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                            self.displayedMaskKey = key
                        case .failure(let error):
                            AppLog.render.error("mask overlay failed: \(error.localizedDescription, privacy: .private)")
                            self.maskImage = nil
                            self.maskError = error.localizedDescription
                            self.displayedMaskKey = nil
                        }
                    }
                    if let next = self.pendingMaskJob {
                        self.pendingMaskJob = nil
                        self.maskInFlight = true
                        next()
                    }
                }
            }
        }
        if maskInFlight { pendingMaskJob = job } else { maskInFlight = true; job() }
    }
}
