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
        isExporting = true
        isCancellingExport = false
        operationProgress = 0
        exportReport = nil
        let cancellation = CancellationFlag()
        exportCancellation = cancellation
        batchQueue.async { [pipeline] in
            var successes = 0
            var failures: [String] = []
            var skipped = 0
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
                    _ = try pipeline.writeExport(data, format: options.format, baseName: baseName, to: directory)
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
                self.isExporting = false
                self.isCancellingExport = false
                self.exportCancellation = nil
                self.exportReport = "\(successes)장 내보냄 · 실패 \(failures.count)장" +
                    (skipped > 0 ? " · 중지해서 \(skipped)장 건너뜀" : "") +
                    (failures.isEmpty ? "" : "\n" + failures.prefix(8).joined(separator: "\n"))
            }
        }
    }

    /// 지금 처리 중인 한 장은 끝까지 저장하고 나머지를 건너뛴다.
    func cancelExport() {
        guard isExporting else { return }
        exportCancellation?.cancel()
        isCancellingExport = true
    }
}
