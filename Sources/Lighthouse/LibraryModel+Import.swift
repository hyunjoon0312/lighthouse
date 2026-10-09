import AppKit
import Foundation
import LighthouseCore

/// 가져오기(파일·폴더·카드 복사)와 보정 프리셋.
@MainActor
extension LibraryModel {
    func presentImport() {
        guard canBeginLocalImport() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "가져오기"
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    nonisolated static func supportedFiles(in urls: [URL], cancellation: CancellationFlag? = nil) -> [URL] {
        let manager = FileManager.default
        var paths: [URL] = []
        var seen = Set<String>()
        for input in urls {
            if cancellation?.isCancelled == true { break }
            let canonical = input.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let items = manager.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in items {
                        if cancellation?.isCancelled == true { return paths }
                        let item = url.standardizedFileURL.resolvingSymlinksInPath()
                        guard ImagePipeline.supportedExtensions.contains(item.pathExtension.lowercased()),
                              (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                              seen.insert(item.path).inserted else { continue }
                        paths.append(item)
                    }
                }
            } else if ImagePipeline.supportedExtensions.contains(canonical.pathExtension.lowercased()),
                      (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      seen.insert(canonical.path).inserted {
                paths.append(canonical)
            }
        }
        return paths
    }

    func importURLs(_ urls: [URL], summaryPrefix: String? = nil) {
        guard canBeginLocalImport() else { return }
        let cancellation = beginImport(message: "파일을 찾는 중…")
        let existing = Set(photos.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path })
        let preset = importPreset
        batchQueue.async { [pipeline] in
            let paths = Self.supportedFiles(in: urls, cancellation: cancellation)
            var seen = existing
            let candidates = paths.filter { seen.insert($0.path).inserted }
            var added: [PhotoAsset] = []
            var failed: [String] = []
            var skipped = 0
            for (index, url) in candidates.enumerated() {
                if cancellation.isCancelled {
                    skipped = candidates.count - index
                    break
                }
                do {
                    var photo = PhotoAsset(url: url, metadata: try pipeline.metadata(for: url))
                    if let preset { photo.edits = preset.applied(to: photo.edits) }
                    added.append(photo)
                }
                catch {
                    AppLog.files.error("import failed: \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                let progress = Double(index + 1) / Double(max(1, candidates.count))
                DispatchQueue.main.async { self.operationProgress = progress; self.operationMessage = "가져오는 중 \(index + 1)/\(candidates.count)" }
            }
            DispatchQueue.main.async {
                let onExternalVolume = added.contains { $0.path.hasPrefix("/Volumes/") }
                let summary = (summaryPrefix.map { $0 + " · " } ?? "") +
                    (preset.map { "프리셋 ‘\($0.name)’ 적용 · " } ?? "") +
                    "\(added.count)장 가져옴 · 중복 \(paths.count - candidates.count)장 · 실패 \(failed.count)장" +
                    (cancellation.isCancelled ? " · 중지됨" : "") +
                    (skipped > 0 ? " · \(skipped)장 건너뜀" : "") +
                    (onExternalVolume ? " · 외장 볼륨의 사진은 연결을 해제하면 열 수 없습니다. 카드는 ‘카드에서 복사해 가져오기’를 쓰세요." : "") +
                    (failed.isEmpty ? "" : "\n" + failed.prefix(5).joined(separator: "\n"))
                self.finishImport(added: added, message: paths.isEmpty && !cancellation.isCancelled
                    ? "선택한 위치에 가져올 수 있는 사진이 없습니다." : summary)
            }
        }
    }

    var canCancelImport: Bool { importCancellation != nil }

    private func canBeginLocalImport() -> Bool {
        guard catalogLoaded, loadError == nil else { return false }
        guard !isImporting, !isExporting else {
            operationMessage = isImporting ? "가져오기가 진행 중입니다." : "내보내기가 끝난 뒤 가져오세요."
            return false
        }
        return true
    }

    private func beginImport(message: String) -> CancellationFlag {
        let cancellation = CancellationFlag()
        importCancellation = cancellation
        isImporting = true
        isCancellingImport = false
        operationProgress = 0
        operationMessage = message
        return cancellation
    }

    private func finishImport(added: [PhotoAsset], message: String) {
        if !added.isEmpty {
            photos = (photos + added).enumerated().sorted { first, second in
                let a = first.element.metadata.capturedAt ?? first.element.importedAt
                let b = second.element.metadata.capturedAt ?? second.element.importedAt
                return a != b ? a < b : first.offset < second.offset
            }.map(\.element)
            if selectedID == nil, let first = added.first {
                photoSelection.select(first.id, in: visiblePhotos.map(\.id))
            }
            scheduleSave()
            requestRender()
        }
        operationMessage = message
        isImporting = false
        isCancellingImport = false
        importCancellation = nil
        let waiters = importCompletionWaiters
        importCompletionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

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

    func writePresets(_ updated: [EditPreset], message: String?) -> String? {
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
        let visibleIDs = Set(visiblePhotos.map(\.id))
        let targets = selectedPhotoIDs.intersection(visibleIDs)
        guard !targets.isEmpty else { return }
        let changes = photos.compactMap { photo -> PhotoEditChange? in
            guard targets.contains(photo.id) else { return nil }
            let after = preset.applied(to: photo.edits)
            return after == photo.edits ? nil : PhotoEditChange(id: photo.id, before: photo.edits, after: after)
        }
        applyEditChanges(changes, useAfter: true, record: true)
        operationMessage = "프리셋 ‘\(preset.name)’ · 선택 \(targets.count)장 중 \(changes.count)장 보정 변경"
    }

    /// 카드의 사진을 `root`로 복사한 뒤 복사본을 가져온다. 카드의 원본은 읽기만 한다.
    func importByCopying(from source: URL, to root: URL, organizeByDate: Bool) {
        guard canBeginLocalImport() else { return }
        let cancellation = beginImport(message: "카드에서 사진을 찾는 중…")
        let existing = Set(photos.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path })
        let preset = importPreset
        batchQueue.async { [pipeline] in
            let files = Self.supportedFiles(in: [source], cancellation: cancellation)
            var seen = existing
            var added: [PhotoAsset] = []
            var copied = 0, present = 0, duplicates = 0, skipped = 0
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
                    if case .copied = result { copied += 1 } else { present += 1 }
                    let destination = result.url.standardizedFileURL.resolvingSymlinksInPath()
                    if seen.insert(destination.path).inserted {
                        var photo = PhotoAsset(url: destination, metadata: try pipeline.metadata(for: destination))
                        if let preset { photo.edits = preset.applied(to: photo.edits) }
                        added.append(photo)
                    } else {
                        duplicates += 1
                    }
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
                let summary = "복사 \(copied)장 · 이미 있음 \(present)장" +
                    (duplicates > 0 ? " · 카탈로그 중복 \(duplicates)장" : "") +
                    (skipped > 0 ? " · 중지해서 \(skipped)장 건너뜀" : "") +
                    (cancellation.isCancelled ? " · 중지됨" : "") +
                    (failures.isEmpty ? "" : " · 복사 실패 \(failures.count)장\n" + failures.prefix(5).joined(separator: "\n"))
                self.finishImport(added: added, message: files.isEmpty && !cancellation.isCancelled
                    ? "선택한 위치에 가져올 수 있는 사진이 없습니다." : summary +
                        (preset.map { " · 프리셋 ‘\($0.name)’ 적용" } ?? "") + " · \(added.count)장 가져옴")
            }
        }
    }

    /// 지금 복사 중인 한 장은 끝까지 복사하고 나머지를 건너뛴다. 이미 복사한 사진은 가져온다.
    func cancelImport() {
        guard isImporting, let importCancellation else { return }
        importCancellation.cancel()
        isCancellingImport = true
    }

    func cancelImportAndWait() async {
        guard isImporting else { return }
        importCancellation?.cancel()
        isCancellingImport = true
        await withCheckedContinuation { continuation in
            importCompletionWaiters.append(continuation)
        }
    }
}
