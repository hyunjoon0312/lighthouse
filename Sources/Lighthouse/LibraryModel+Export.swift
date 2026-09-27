import Foundation
import LighthouseCore

/// 내보내기.
@MainActor
extension LibraryModel {
    func exportTargets(for scope: ExportScope) -> [PhotoAsset] {
        switch scope {
        case .current: selection.map { [$0] } ?? []
        case .selected: selectedPhotos
        case .visible: visiblePhotos
        }
    }

    func export(scope: ExportScope, options: ExportOptions, directory: URL, prepared: PreparedJPEGExport? = nil) {
        guard !isExporting, catalogLoaded, loadError == nil else { return }
        let targets = exportTargets(for: scope)
        guard !targets.isEmpty else { return }
        let cancellation = beginExport()
        batchQueue.async { [pipeline] in
            var records: [UUID: ExportRecord] = [:]
            var failures: [String] = []
            var successes = 0, skipped = 0
            for (index, photo) in targets.enumerated() {
                if cancellation.isCancelled {
                    skipped = targets.count - index
                    break
                }
                do {
                    let data: Data
                    if let prepared, prepared.matches(photo, options) {
                        data = prepared.result.data
                    } else {
                        data = try pipeline.prepareExport(url: photo.url, edits: photo.edits, options: options,
                                                          keywords: photo.keywords, caption: photo.caption).data
                    }
                    let baseName = ExportOptions.baseName(template: options.filenameTemplate, sourceURL: photo.url,
                                                          capturedAt: photo.metadata.capturedAt, sequence: index + 1,
                                                          copyName: photo.copyName)
                    let file = try pipeline.writeExport(data, format: options.format, baseName: baseName, to: directory)
                    records[photo.id] = ExportRecord.make(photo: photo, file: file, baseName: baseName, options: options)
                    successes += 1
                }
                catch {
                    AppLog.export.error("export failed: \(photo.filename, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    failures.append("\(photo.filename): \(error.localizedDescription)")
                }
                let progress = Double(index + 1) / Double(targets.count)
                DispatchQueue.main.async { self.operationProgress = progress }
            }
            DispatchQueue.main.async {
                self.finishExport(records: records)
                self.exportReport = "\(successes)장 내보냄 · 실패 \(failures.count)장" +
                    (skipped > 0 ? " · 중지해서 \(skipped)장 건너뜀" : "") +
                    (failures.isEmpty ? "" : "\n" + failures.prefix(8).joined(separator: "\n"))
            }
        }
    }

    /// 마지막으로 내보낸 뒤 보정·키워드·설명이 바뀐 사진. 원본이 없는 사진은 다시 내보낼 수 없어 뺀다.
    var changedSinceExport: [PhotoAsset] {
        photos.filter { $0.lastExport?.isChanged($0) == true && !isMissing($0) }
    }

    /// 바뀐 사진을 마지막 내보내기와 같은 설정·폴더·이름으로 다시 내보낸다. `trashPrevious`이면 이전 파일이
    /// 카탈로그 원본이 아니고 앱이 쓴 그대로일 때만 휴지통으로 옮긴다. 아니면 보존하고 새 파일에 번호를 붙인다.
    func reexport(_ targets: [PhotoAsset], trashPrevious: Bool) {
        guard !isExporting, catalogLoaded, loadError == nil else { return }
        let work = targets.compactMap { photo in photo.lastExport.map { (photo, $0) } }
        guard !work.isEmpty else { return }
        let cancellation = beginExport()
        batchQueue.async { [pipeline] in
            var records: [UUID: ExportRecord] = [:]
            var failures: [String] = []
            var trashed = 0, protectedOriginals = 0, keptChanged = 0, skipped = 0
            for (index, (photo, previous)) in work.enumerated() {
                if cancellation.isCancelled {
                    skipped = work.count - index
                    break
                }
                let previousFile = URL(fileURLWithPath: previous.path)
                do {
                    // 새 파일을 만들 수 있을 때만 이전 파일을 옮긴다. 원본이 없거나 현상에 실패하면 이전 파일은 그대로다.
                    let data = try pipeline.prepareExport(url: photo.url, edits: photo.edits, options: previous.options,
                                                          keywords: photo.keywords, caption: photo.caption).data
                    if trashPrevious {
                        let handling = try DispatchQueue.main.sync {
                            try self.handlePreviousExport(previous, at: previousFile)
                        }
                        switch handling {
                        case .missing: break
                        case .trashed: trashed += 1
                        case .protectedOriginal: protectedOriginals += 1
                        case .externallyChanged: keptChanged += 1
                        }
                    }
                    let file = try pipeline.writeExport(data, format: previous.options.format, baseName: previous.baseName,
                                                        to: previousFile.deletingLastPathComponent())
                    records[photo.id] = ExportRecord.make(photo: photo, file: file, baseName: previous.baseName,
                                                          options: previous.options)
                } catch {
                    AppLog.export.error("re-export failed: \(photo.filename, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    failures.append("\(photo.filename): \(error.localizedDescription)")
                }
                let progress = Double(index + 1) / Double(work.count)
                DispatchQueue.main.async { self.operationProgress = progress }
            }
            DispatchQueue.main.async {
                self.finishExport(records: records)
                self.exportReport = "\(records.count)장 다시 내보냄" +
                    (trashed > 0 ? " · 이전 파일 \(trashed)장 휴지통으로" : "") +
                    (protectedOriginals > 0 ? " · 카탈로그 원본 \(protectedOriginals)장 보존" : "") +
                    (keptChanged > 0 ? " · \(keptChanged)장은 이전 파일이 외부에서 바뀌어 그대로 둠" : "") +
                    " · 실패 \(failures.count)장" + (skipped > 0 ? " · 중지해서 \(skipped)장 건너뜀" : "") +
                    (failures.isEmpty ? "" : "\n" + failures.prefix(8).joined(separator: "\n"))
            }
        }
    }

    private enum PreviousExportHandling {
        case missing, trashed, protectedOriginal, externallyChanged
    }

    /// 카탈로그 변경과 이전 파일 이동 사이에 다른 메인 액터 작업이 끼어들지 않게 한 임계 구간이다.
    private func handlePreviousExport(_ previous: ExportRecord, at file: URL) throws -> PreviousExportHandling {
        guard FileManager.default.fileExists(atPath: previous.path) else { return .missing }
        let resolvedPath = file.standardizedFileURL.resolvingSymlinksInPath().path
        if isImporting || photos.contains(where: {
            $0.url.standardizedFileURL.resolvingSymlinksInPath().path == resolvedPath
        }) {
            return .protectedOriginal
        }
        guard previous.fileIsUntouched else { return .externallyChanged }
        try moveToTrash(file)
        return .trashed
    }

    private func beginExport() -> CancellationFlag {
        isExporting = true
        isCancellingExport = false
        operationProgress = 0
        exportReport = nil
        lastExportedFiles = []
        let cancellation = CancellationFlag()
        exportCancellation = cancellation
        return cancellation
    }

    /// 내보낸 사진에 기록을 남긴다. 보정이 아니라 실행 취소에 넣지 않는다.
    private func finishExport(records: [UUID: ExportRecord]) {
        isExporting = false
        isCancellingExport = false
        exportCancellation = nil
        lastExportedFiles = records.values.map { URL(fileURLWithPath: $0.path) }.sorted { $0.path < $1.path }
        guard !records.isEmpty else { return }
        var updated = photos
        for index in updated.indices {
            if let record = records[updated[index].id] { updated[index].lastExport = record }
        }
        photos = updated
        scheduleSave()
    }

    /// 지금 처리 중인 한 장은 끝까지 저장하고 나머지를 건너뛴다.
    func cancelExport() {
        guard isExporting else { return }
        exportCancellation?.cancel()
        isCancellingExport = true
    }
}
