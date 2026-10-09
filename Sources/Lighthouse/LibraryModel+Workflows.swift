import AppKit
import Foundation
import LighthouseCore

struct WorkflowFileFailure: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let message: String
}

struct BatchWorkflowReport: Equatable {
    let changed: Int
    let skipped: Int
    let failures: [WorkflowFileFailure]
    let cancelled: Bool
}

struct RangeMaskSheetRequest: Identifiable {
    let id = UUID()
    let photoID: UUID
    let path: String
    let edits: EditSettings
    let localID: UUID?
    let initial: RangeSelection
}

@MainActor
extension LibraryModel {
    var hasConflictingWorkflow: Bool {
        isRunningWorkflow || isImporting || isExporting || isAnalyzingFaces || driveUpload.isBusy ||
            isLUTImporting || isLUTLibraryLoading || isPresetImporting || isAutoMasking || isAutoAdjusting || isFindingHealSource ||
            isPickingWhiteBalance || isAnalyzingBursts || isAnalyzingFlicker
    }

    func analyzeFlicker() {
        guard !isAnalyzingFlicker, let photo = selection, !isMissing(photo) else { return }
        flickerGeneration += 1
        let token = flickerGeneration
        let snapshot = photo.edits
        isAnalyzingFlicker = true
        flickerAnalysisMessage = nil
        batchQueue.async { [pipeline] in
            let result = Result { try pipeline.analyzeFlicker(url: photo.url) }
            DispatchQueue.main.async {
                guard token == self.flickerGeneration else { return }
                self.isAnalyzingFlicker = false
                guard let current = self.photo(withID: photo.id), current.path == photo.path,
                      current.edits == snapshot, self.selectedID == photo.id else {
                    self.flickerAnalysisMessage = "사진이나 보정이 바뀌어 분석 결과를 적용하지 않았습니다."
                    return
                }
                switch result {
                case .success(let analysis):
                    var edits = current.edits
                    edits.flicker = analysis.settings
                    self.updateEdits(edits)
                    self.flickerAnalysisMessage = analysis.message
                case .failure(let error):
                    self.flickerAnalysisMessage = "띠 분석 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelFlickerAnalysis() {
        flickerGeneration += 1
        isAnalyzingFlicker = false
        flickerAnalysisMessage = "띠 분석을 취소했습니다."
    }

    func presentRangeMask(_ kind: RangeSelectionKind, reediting localID: UUID? = nil) {
        guard let photo = selection, !isMissing(photo) else { return }
        let current = localID.flatMap { id in photo.edits.localAdjustments.first { $0.id == id }?.rangeSelection }
        rangeMaskRequest = RangeMaskSheetRequest(photoID: photo.id, path: photo.path, edits: photo.edits,
                                                 localID: localID, initial: current ?? RangeSelection(kind: kind))
    }

    func applyRangeMask(_ request: RangeMaskSheetRequest, selection range: RangeSelection) {
        guard !isRunningWorkflow else { return }
        rangeMaskGeneration += 1
        let token = rangeMaskGeneration
        let cancellation = CancellationFlag()
        workflowCancellation = cancellation
        isRunningWorkflow = true
        workflowMessage = nil
        batchQueue.async { [pipeline] in
            let result = Result { try pipeline.rangeMask(url: URL(fileURLWithPath: request.path), selection: range) }
            DispatchQueue.main.async {
                guard token == self.rangeMaskGeneration else { return }
                self.isRunningWorkflow = false
                self.workflowCancellation = nil
                self.resumeWorkflowWaiters()
                guard !cancellation.isCancelled else {
                    self.workflowMessage = "범위 마스크 작업을 취소했습니다."
                    return
                }
                guard let photo = self.photo(withID: request.photoID), photo.path == request.path,
                      photo.edits == request.edits, self.selectedID == request.photoID else {
                    self.workflowMessage = "사진이나 보정이 바뀌어 범위 결과를 적용하지 않았습니다."
                    return
                }
                switch result {
                case .success(let mask):
                    var edits = photo.edits
                    if let localID = request.localID,
                       let index = edits.localAdjustments.firstIndex(where: { $0.id == localID }) {
                        edits.localAdjustments[index].baseMask = mask
                        edits.localAdjustments[index].rangeSelection = range
                        self.selectedLocalID = localID
                    } else {
                        let name = range.kind == .luminance ? "밝기 범위" : "색상 범위"
                        let area = LocalAdjustment(name: name, baseMask: mask, rangeSelection: range)
                        edits.localAdjustments.append(area)
                        self.selectedLocalID = area.id
                    }
                    self.updateEdits(edits)
                    self.enterLocalPanel()
                    self.rangeMaskRequest = nil
                case .failure(let error):
                    self.workflowMessage = "범위 마스크 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func applyBatchEditsWithAutomaticMasks(source: EditSettings, to ids: [UUID],
                                           components: EditComponents, reRecognize: Bool) {
        let automatic = source.localAdjustments.filter { $0.automaticMaskKind != nil }
        guard reRecognize, components.contains(.local), !automatic.isEmpty else {
            applyBatchEdits(source: source, to: ids, components: components)
            return
        }
        guard !hasConflictingWorkflow else { return }
        let requested = Set(ids).intersection(visiblePhotos.map(\.id))
        let targets = photos.filter { requested.contains($0.id) }
        workflowGeneration += 1
        let token = workflowGeneration
        let cancellation = CancellationFlag()
        workflowCancellation = cancellation
        isRunningWorkflow = true
        workflowProgress = 0
        workflowMessage = nil
        batchWorkflowReport = nil
        batchQueue.async { [pipeline] in
            var prepared: [(PhotoAsset, EditSettings)] = []
            var failures: [WorkflowFileFailure] = []
            for (offset, target) in targets.enumerated() {
                if cancellation.isCancelled { break }
                do {
                    let mask = try pipeline.subjectMask(url: target.url)
                    var edits = target.edits.merging(from: source, components: components)
                    for index in edits.localAdjustments.indices {
                        guard let kind = edits.localAdjustments[index].automaticMaskKind else { continue }
                        edits.localAdjustments[index].baseMask = mask
                        edits.localAdjustments[index].isInverted = kind == .background
                    }
                    prepared.append((target, edits))
                } catch {
                    failures.append(WorkflowFileFailure(filename: target.filename, message: error.localizedDescription))
                }
                DispatchQueue.main.async {
                    guard token == self.workflowGeneration else { return }
                    self.workflowProgress = Double(offset + 1) / Double(max(1, targets.count))
                }
            }
            DispatchQueue.main.async {
                guard token == self.workflowGeneration else { return }
                self.isRunningWorkflow = false
                self.workflowCancellation = nil
                self.resumeWorkflowWaiters()
                let cancelled = cancellation.isCancelled
                guard !cancelled else {
                    self.batchWorkflowReport = BatchWorkflowReport(changed: 0, skipped: targets.count,
                                                                   failures: failures, cancelled: true)
                    return
                }
                let changes = prepared.compactMap { original, after -> PhotoEditChange? in
                    guard let current = self.photo(withID: original.id), current.path == original.path,
                          current.edits == original.edits, current.edits != after else { return nil }
                    return PhotoEditChange(id: original.id, before: original.edits, after: after)
                }
                self.applyEditChanges(changes, useAfter: true, record: true)
                let skipped = targets.count - changes.count - failures.count
                self.batchWorkflowReport = BatchWorkflowReport(changed: changes.count, skipped: max(0, skipped),
                                                               failures: failures, cancelled: false)
            }
        }
    }

    func findSimilarPhotos() {
        guard !hasConflictingWorkflow else { return }
        let scope = selectedPhotos.count >= 2 ? selectedPhotos : visiblePhotos
        workflowGeneration += 1
        let token = workflowGeneration
        let cancellation = CancellationFlag()
        workflowCancellation = cancellation
        isRunningWorkflow = true
        workflowProgress = 0
        similarPhotoResult = nil
        batchQueue.async { [pipeline] in
            let result = Result {
                try SimilarPhotoFinder.analyze(photos: scope, pipeline: pipeline,
                                               isCancelled: { cancellation.isCancelled }) { completed, total in
                    DispatchQueue.main.async {
                        guard token == self.workflowGeneration else { return }
                        self.workflowProgress = Double(completed) / Double(max(1, total))
                    }
                }
            }
            DispatchQueue.main.async {
                guard token == self.workflowGeneration else { return }
                self.isRunningWorkflow = false
                self.workflowCancellation = nil
                self.resumeWorkflowWaiters()
                switch result {
                case .success(let value): self.similarPhotoResult = value
                case .failure(let error): self.workflowMessage = "중복·유사 사진 분석 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func showSimilarGroup(_ group: SimilarPhotoGroup) {
        let available = visiblePhotos.map(\.id).filter { group.photoIDs.contains($0) }
        guard let first = available.first else { return }
        photoSelection.select(first, in: visiblePhotos.map(\.id))
        for id in available.dropFirst() { photoSelection.select(id, in: visiblePhotos.map(\.id), mode: .toggle) }
        mode = .survey
        showSimilarPhotos = false
        selectionDidChange(previousActive: nil)
    }

    func refreshSmartPreviewRecords() {
        previewRefreshGeneration += 1
        let token = previewRefreshGeneration
        let photos = photos
        let store = smartPreviewStore
        batchQueue.async {
            var records: [UUID: SmartPreviewRecord] = [:]
            var urls: [UUID: URL] = [:]
            for photo in photos {
                if let record = try? store.record(for: photo), let url = try? store.previewURL(for: photo) {
                    records[photo.id] = record
                    urls[photo.id] = url
                }
            }
            DispatchQueue.main.async {
                if token == self.previewRefreshGeneration {
                    let changed = self.smartPreviewRecords != records || self.smartPreviewURLs != urls
                    self.smartPreviewRecords = records
                    self.smartPreviewURLs = urls
                    if changed { self.invalidateWorkflowRenderCaches() }
                }
            }
        }
    }

    func createSmartPreviews(for ids: Set<UUID>) {
        guard !hasConflictingWorkflow else { return }
        let targets = photos.filter { ids.contains($0.id) }
        workflowGeneration += 1
        let token = workflowGeneration
        let cancellation = CancellationFlag()
        workflowCancellation = cancellation
        isRunningWorkflow = true
        workflowProgress = 0
        smartPreviewFailures = []
        batchQueue.async { [smartPreviewStore, pipeline] in
            var records: [UUID: SmartPreviewRecord] = [:]
            var urls: [UUID: URL] = [:]
            var failures: [WorkflowFileFailure] = []
            for (offset, photo) in targets.enumerated() {
                if cancellation.isCancelled { break }
                do {
                    records[photo.id] = try smartPreviewStore.create(for: photo, pipeline: pipeline)
                    urls[photo.id] = try smartPreviewStore.previewURL(for: photo)
                }
                catch { failures.append(WorkflowFileFailure(filename: photo.filename, message: error.localizedDescription)) }
                DispatchQueue.main.async {
                    guard token == self.workflowGeneration else { return }
                    self.workflowProgress = Double(offset + 1) / Double(max(1, targets.count))
                }
            }
            DispatchQueue.main.async {
                guard token == self.workflowGeneration else { return }
                self.isRunningWorkflow = false
                self.workflowCancellation = nil
                self.resumeWorkflowWaiters()
                if !cancellation.isCancelled {
                    self.smartPreviewRecords.merge(records) { _, new in new }
                    self.smartPreviewURLs.merge(urls) { _, new in new }
                }
                self.smartPreviewFailures = failures
                self.invalidateWorkflowRenderCaches()
            }
        }
    }

    func deleteSmartPreviews(for ids: Set<UUID>) {
        for photo in photos where ids.contains(photo.id) {
            do {
                try smartPreviewStore.remove(for: photo)
                smartPreviewRecords.removeValue(forKey: photo.id)
                smartPreviewURLs.removeValue(forKey: photo.id)
            }
            catch { smartPreviewFailures.append(WorkflowFileFailure(filename: photo.filename, message: error.localizedDescription)) }
        }
        invalidateWorkflowRenderCaches()
    }

    func inspectLibraryArchive(at url: URL) {
        guard !hasConflictingWorkflow else { return }
        archiveSummary = nil
        workflowGeneration += 1
        let token = workflowGeneration
        let cancellation = CancellationFlag()
        workflowCancellation = cancellation
        isRunningWorkflow = true
        workflowMessage = nil
        batchQueue.async {
            let result = Result { try LibraryArchive.inspect(at: url) }
            DispatchQueue.main.async {
                guard token == self.workflowGeneration else { return }
                self.isRunningWorkflow = false
                self.workflowCancellation = nil
                self.resumeWorkflowWaiters()
                guard !cancellation.isCancelled else { self.workflowMessage = "보관본 확인을 취소했습니다."; return }
                switch result {
                case .success(let summary): self.archiveSummary = summary
                case .failure(let error):
                    self.archiveSummary = nil
                    self.workflowMessage = "보관본 확인 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func startLibraryBackup(to destination: URL, includeOriginals: Bool) {
        guard !hasConflictingWorkflow, catalogLoaded, loadError == nil else { return }
        do { try flushSave(requireCompleteLibrary: true) }
        catch { workflowMessage = "라이브러리 저장 실패: \(error.localizedDescription)"; return }
        workflowGeneration += 1
        let token = workflowGeneration
        let cancellation = CancellationFlag()
        workflowCancellation = cancellation
        isRunningWorkflow = true
        workflowProgress = 0
        batchQueue.async { [dataDirectory] in
            let result = Result {
                try LibraryArchive.create(dataDirectory: dataDirectory, destination: destination,
                                          includeOriginals: includeOriginals,
                                          isCancelled: { cancellation.isCancelled }) { completed, total in
                    DispatchQueue.main.async {
                        if token == self.workflowGeneration {
                            self.workflowProgress = Double(completed) / Double(max(1, total))
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                guard token == self.workflowGeneration else { return }
                self.isRunningWorkflow = false
                self.workflowCancellation = nil
                self.resumeWorkflowWaiters()
                switch result {
                case .success(let summary) where !cancellation.isCancelled:
                    self.archiveSummary = summary
                    self.workflowMessage = "라이브러리 보관본을 만들었습니다."
                case .success: self.workflowMessage = "라이브러리 백업을 취소했습니다."
                case .failure(let error): self.workflowMessage = "라이브러리 백업 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func startLibraryRestore(from archive: URL, to destination: URL) {
        guard !hasConflictingWorkflow else { return }
        let current = dataDirectory.standardizedFileURL.path
        let target = destination.standardizedFileURL.path
        guard target != current, !target.hasPrefix(current + "/"), !current.hasPrefix(target + "/") else {
            workflowMessage = "현재 라이브러리 안이나 그 상위 폴더에는 복원할 수 없습니다. 별도의 새 위치를 선택하세요."
            return
        }
        workflowGeneration += 1
        let token = workflowGeneration
        let cancellation = CancellationFlag()
        workflowCancellation = cancellation
        restoredLibraryDirectory = nil
        isRunningWorkflow = true
        workflowProgress = 0
        batchQueue.async {
            let result = Result {
                try LibraryArchive.restore(from: archive, to: destination,
                                           isCancelled: { cancellation.isCancelled }) { completed, total in
                    DispatchQueue.main.async {
                        if token == self.workflowGeneration {
                            self.workflowProgress = Double(completed) / Double(max(1, total))
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                guard token == self.workflowGeneration else { return }
                self.isRunningWorkflow = false
                self.workflowCancellation = nil
                self.resumeWorkflowWaiters()
                switch result {
                case .success(let directory) where !cancellation.isCancelled:
                    self.restoredLibraryDirectory = directory
                    self.workflowMessage = "기존 라이브러리는 그대로 두고 새 위치에 복원했습니다."
                case .success: self.workflowMessage = "라이브러리 복원을 취소했습니다."
                case .failure(let error): self.workflowMessage = "라이브러리 복원 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelWorkflow() {
        workflowCancellation?.cancel()
        if !isRunningWorkflow { workflowMessage = "작업을 취소했습니다." }
    }

    func cancelWorkflowAndWait() async {
        cancelWorkflow()
        guard isRunningWorkflow else { return }
        await withCheckedContinuation { workflowCompletionWaiters.append($0) }
    }

    private func resumeWorkflowWaiters() {
        let waiters = workflowCompletionWaiters
        workflowCompletionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func validatedPreviewSource(for photo: PhotoAsset) -> (url: URL, edits: EditSettings)? {
        guard isMissing(photo), smartPreviewRecords[photo.id]?.sourcePath == photo.path,
              let url = smartPreviewURLs[photo.id] else { return nil }
        return (url, SmartPreviewStore.previewEdits(photo.edits))
    }

    var selectionUsesSmartPreview: Bool {
        selection.map { validatedPreviewSource(for: $0) != nil } ?? false
    }

    func invalidateWorkflowRenderCaches() {
        thumbnailGeneration += 1
        loadingThumbnails.removeAll()
        unavailableThumbnails.removeAll()
        recentRenders.removeAll()
        thumbnailCache.removeAllObjects()
        invalidateSurveyImages(clearAll: true)
        pinnedImage = nil
        pinnedError = nil
        pinnedSource = nil
        pinnedRenderedEdits = nil
        splitBefore = nil
        splitBeforeState = nil
        generation += 1
        requestRender()
    }
}
