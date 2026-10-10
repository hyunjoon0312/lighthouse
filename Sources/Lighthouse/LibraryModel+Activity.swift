import Foundation

/// 여러 장이나 라이브러리 전체에 하는 묶음 작업의 종류. 한 번에 하나만 돈다(`isRunningWorkflow`).
enum WorkflowKind {
    case rangeMask, batchAutoMask, similarPhotos, smartPreviews, archiveCheck, backup, restore

    var title: String {
        switch self {
        case .rangeMask: "범위 마스크 만들기"
        case .batchAutoMask: "일괄 적용"
        case .similarPhotos: "중복·유사 사진 찾기"
        case .smartPreviews: "스마트 미리보기 만들기"
        case .archiveCheck: "보관본 확인"
        case .backup: "라이브러리 백업"
        case .restore: "라이브러리 복원"
        }
    }

    /// `workflowProgress`로 진행을 알리는 작업. 나머지는 끝을 모르는 표시로 돈다.
    var reportsProgress: Bool {
        switch self {
        case .rangeMask, .archiveCheck: false
        case .batchAutoMask, .similarPhotos, .smartPreviews, .backup, .restore: true
        }
    }
}

/// 사용자가 다른 일을 하는 동안 뒤에서 도는 작업. 위쪽 막대의 작업 표시와 그 목록에 쓴다.
struct BackgroundActivity: Identifiable, Equatable {
    enum Kind: Hashable {
        case importing, exporting, driveUpload, faces, bursts, flicker, workflow, sidecars, lutImport, presetImport
    }

    let kind: Kind
    let title: String
    /// "34/120장"·"50%"처럼 어디까지 했는지. 모르면 nil이다.
    let detail: String?
    /// 0…1. 끝을 모르는 작업은 nil이다.
    let progress: Double?
    let canCancel: Bool
    let isCancelling: Bool

    var id: Kind { kind }
}

@MainActor
extension LibraryModel {
    /// 지금 도는 작업. 사진 보기의 자동 보정·마스크처럼 그 자리에서 결과를 기다리는 짧은 작업과
    /// 라이브러리를 열 때 잠깐 읽는 LUT 목록은 넣지 않는다.
    var backgroundActivities: [BackgroundActivity] {
        var items: [BackgroundActivity] = []
        if isImporting {
            items.append(BackgroundActivity(kind: .importing, title: "가져오기", detail: Self.percent(operationProgress),
                                            progress: operationProgress, canCancel: canCancelImport,
                                            isCancelling: isCancellingImport))
        }
        if isExporting {
            items.append(BackgroundActivity(kind: .exporting, title: "내보내기", detail: Self.percent(operationProgress),
                                            progress: operationProgress, canCancel: true, isCancelling: isCancellingExport))
        }
        if driveUpload.isBusy {
            let total = driveUpload.totalPhotos, done = driveUpload.completedPhotos
            items.append(BackgroundActivity(kind: .driveUpload, title: "Google Drive 업로드",
                                            detail: total > 0 ? "\(done)/\(total)장" : nil,
                                            progress: total > 0 ? Double(done) / Double(total) : nil,
                                            canCancel: true, isCancelling: driveUpload.isCancelling))
        }
        if isAnalyzingFaces {
            let total = faceAnalysisTotal, done = faceAnalysisCompleted
            items.append(BackgroundActivity(kind: .faces, title: "얼굴 찾기",
                                            detail: total > 0 ? "\(done)/\(total)장" : nil,
                                            progress: total > 0 ? Double(done) / Double(total) : nil,
                                            canCancel: true, isCancelling: isCancellingFaces))
        }
        if isAnalyzingBursts {
            items.append(BackgroundActivity(kind: .bursts, title: "베스트 컷 분석", detail: Self.percent(burstAnalysisProgress),
                                            progress: burstAnalysisProgress, canCancel: true, isCancelling: false))
        }
        if isAnalyzingFlicker {
            items.append(BackgroundActivity(kind: .flicker, title: "LED 띠 분석", detail: nil, progress: nil,
                                            canCancel: true, isCancelling: false))
        }
        if isRunningWorkflow {
            let reports = workflowKind?.reportsProgress == true
            items.append(BackgroundActivity(kind: .workflow, title: workflowKind?.title ?? "작업",
                                            detail: reports ? Self.percent(workflowProgress) : nil,
                                            progress: reports ? workflowProgress : nil, canCancel: true, isCancelling: false))
        }
        if sidecarWritesInFlight > 0 {
            items.append(BackgroundActivity(kind: .sidecars, title: "XMP 사이드카 쓰기", detail: "\(sidecarWritesInFlight)장",
                                            progress: nil, canCancel: false, isCancelling: false))
        }
        if isLUTImporting {
            items.append(BackgroundActivity(kind: .lutImport, title: "LUT 가져오기", detail: nil, progress: nil,
                                            canCancel: false, isCancelling: false))
        }
        if isPresetImporting {
            items.append(BackgroundActivity(kind: .presetImport, title: "Lightroom 프리셋 확인", detail: nil, progress: nil,
                                            canCancel: true, isCancelling: false))
        }
        return items
    }

    /// 작업 목록의 중지. 각 작업의 중지와 같다(지금 처리 중인 한 장은 끝까지 하는 작업도 있다).
    func cancelBackgroundActivity(_ kind: BackgroundActivity.Kind) {
        switch kind {
        case .importing: cancelImport()
        case .exporting: cancelExport()
        case .driveUpload: driveUpload.cancel()
        case .faces: cancelFaceAnalysis()
        case .bursts: cancelBurstAnalysis()
        case .flicker: cancelFlickerAnalysis()
        case .workflow: cancelWorkflow()
        case .presetImport: cancelPresetImport()
        case .sidecars, .lutImport: break
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}
