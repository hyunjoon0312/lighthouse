import AppKit
import Foundation
import LighthouseCore

/// 가져오기(파일·폴더·카드 복사)와 보정 프리셋.
@MainActor
extension LibraryModel {
    func presentImport() {
        guard catalogLoaded, loadError == nil, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "가져오기"
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    nonisolated static func supportedFiles(in urls: [URL]) -> [URL] {
        let manager = FileManager.default
        var paths: [URL] = []
        for input in urls {
            let canonical = input.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let items = manager.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in items where ImagePipeline.supportedExtensions.contains(url.pathExtension.lowercased()) {
                        paths.append(url.standardizedFileURL.resolvingSymlinksInPath())
                    }
                }
            } else if ImagePipeline.supportedExtensions.contains(canonical.pathExtension.lowercased()) {
                paths.append(canonical)
            }
        }
        return paths
    }

    func importURLs(_ urls: [URL], summaryPrefix: String? = nil) {
        guard catalogLoaded, loadError == nil, !isImporting else { return }
        isImporting = true
        operationProgress = 0
        operationMessage = "파일을 찾는 중…"
        let existing = Set(photos.map(\.path))
        batchQueue.async { [pipeline] in
            let paths = Self.supportedFiles(in: urls)
            var seen = existing
            let candidates = paths.filter { seen.insert($0.path).inserted }
            var added: [PhotoAsset] = []
            var failed: [String] = []
            for (index, url) in candidates.enumerated() {
                do { added.append(PhotoAsset(url: url, metadata: try pipeline.metadata(for: url))) }
                catch {
                    AppLog.files.error("import failed: \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                let progress = Double(index + 1) / Double(max(1, candidates.count))
                DispatchQueue.main.async { self.operationProgress = progress; self.operationMessage = "가져오는 중 \(index + 1)/\(candidates.count)" }
            }
            DispatchQueue.main.async {
                if let preset = self.importPreset {
                    for index in added.indices { added[index].edits = preset.applied(to: added[index].edits) }
                }
                // 같은 시각끼리는 원래 순서를 지켜 가상 사본이 원래 항목 바로 뒤에 남게 한다.
                self.photos = (self.photos + added).enumerated().sorted { first, second in
                    let a = first.element.metadata.capturedAt ?? first.element.importedAt
                    let b = second.element.metadata.capturedAt ?? second.element.importedAt
                    return a != b ? a < b : first.offset < second.offset
                }.map(\.element)
                if self.selectedID == nil, let first = added.first {
                    self.photoSelection.select(first.id, in: self.visiblePhotos.map(\.id))
                }
                self.isImporting = false
                let onExternalVolume = added.contains { $0.path.hasPrefix("/Volumes/") }
                self.operationMessage = (summaryPrefix.map { $0 + " · " } ?? "") +
                    (self.importPreset.map { "프리셋 ‘\($0.name)’ 적용 · " } ?? "") +
                    "\(added.count)장 가져옴 · 중복 \(paths.count - candidates.count)장 · 실패 \(failed.count)장" +
                    (onExternalVolume ? " · 외장 볼륨의 사진은 연결을 해제하면 열 수 없습니다. 카드는 ‘카드에서 복사해 가져오기’를 쓰세요." : "") +
                    (failed.isEmpty ? "" : "\n" + failed.prefix(5).joined(separator: "\n"))
                if !added.isEmpty { self.scheduleSave(); self.requestRender() }
            }
        }
    }

    var canCancelImport: Bool { importCancellation != nil }

    var importPreset: EditPreset? { importPresetID.flatMap { id in presets.first { $0.id == id } } }

    /// 현재 사진의 보정에서 고른 항목만 새 프리셋으로 저장한다. 실패하면 이유를 돌려준다.
    func savePreset(name: String, components: EditComponents) -> String? {
        guard presetLoadError == nil else { return "프리셋 파일을 읽지 못해 저장할 수 없습니다." }
        guard let current = selection else { return "사진을 선택하세요." }
        let preset = EditPreset(name: name, source: current.edits, components: components)
        return writePresets(presets + [preset], message: "프리셋 ‘\(preset.name)’을 저장했습니다.")
    }

    func renamePreset(_ id: UUID, to name: String) -> String? {
        guard presetLoadError == nil, let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = presets
        updated[index].name = name
        return writePresets(updated, message: nil)
    }

    func deletePreset(_ id: UUID) {
        guard presetLoadError == nil else { return }
        if importPresetID == id { importPresetID = nil }
        _ = writePresets(presets.filter { $0.id != id }, message: "프리셋을 삭제했습니다. 이미 적용한 사진의 보정은 그대로입니다.")
    }

    private func writePresets(_ updated: [EditPreset], message: String?) -> String? {
        do {
            let normalized = try EditPresetStore.validated(updated)
            try saveQueue.sync { try presetStore.save(normalized) }
            presets = normalized.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let message { operationMessage = message }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 여러 장이 선택되어 있으면 선택한 사진 전체에, 아니면 현재 사진에 적용한다. 한 번에 실행 취소된다.
    func applyPreset(_ preset: EditPreset) {
        let targets = selectedPhotoIDs.count >= 2 ? selectedPhotos.map(\.id) : selectedID.map { [$0] } ?? []
        guard !targets.isEmpty else { return }
        applyBatchEdits(source: preset.settings, to: targets, components: preset.components)
        operationMessage = "프리셋 ‘\(preset.name)’ 적용 · " + (operationMessage ?? "")
    }

    /// 카드의 사진을 `root`로 복사한 뒤 복사본을 가져온다. 카드의 원본은 읽기만 한다.
    func importByCopying(from source: URL, to root: URL, organizeByDate: Bool) {
        guard catalogLoaded, loadError == nil, !isImporting else { return }
        isImporting = true
        isCancellingImport = false
        operationProgress = 0
        operationMessage = "카드에서 사진을 찾는 중…"
        let cancellation = CancellationFlag()
        importCancellation = cancellation
        batchQueue.async { [pipeline] in
            let files = Self.supportedFiles(in: [source])
            var destinations: [URL] = []
            var copied = 0, present = 0, skipped = 0
            var failures: [String] = []
            for (index, file) in files.enumerated() {
                if cancellation.isCancelled {
                    skipped = files.count - index
                    break
                }
                let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
                let captured = (try? pipeline.metadata(for: file))?.capturedAt ?? modified
                let folder = PhotoCopier.folder(for: captured, in: root, organizeByDate: organizeByDate)
                do {
                    let result = try PhotoCopier.copy(file, into: folder)
                    destinations.append(result.url)
                    if case .copied = result { copied += 1 } else { present += 1 }
                } catch {
                    AppLog.files.error("card copy failed: \(error.localizedDescription, privacy: .private)")
                    failures.append(error.localizedDescription)
                }
                let progress = Double(index + 1) / Double(max(1, files.count))
                DispatchQueue.main.async {
                    self.operationProgress = progress
                    self.operationMessage = "복사하는 중 \(index + 1)/\(files.count)"
                }
            }
            DispatchQueue.main.async {
                self.isImporting = false
                self.isCancellingImport = false
                self.importCancellation = nil
                let summary = "복사 \(copied)장 · 이미 있음 \(present)장" +
                    (skipped > 0 ? " · 중지해서 \(skipped)장 건너뜀" : "") +
                    (failures.isEmpty ? "" : " · 복사 실패 \(failures.count)장\n" + failures.prefix(5).joined(separator: "\n"))
                guard !destinations.isEmpty else {
                    self.operationMessage = files.isEmpty ? "선택한 위치에 가져올 수 있는 사진이 없습니다." : summary
                    return
                }
                self.importURLs(destinations, summaryPrefix: summary)
            }
        }
    }

    /// 지금 복사 중인 한 장은 끝까지 복사하고 나머지를 건너뛴다. 이미 복사한 사진은 가져온다.
    func cancelImport() {
        guard isImporting, let importCancellation else { return }
        importCancellation.cancel()
        isCancellingImport = true
    }
}
