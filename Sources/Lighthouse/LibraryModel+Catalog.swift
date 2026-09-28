import AppKit
import Foundation
import LighthouseCore

/// 가상 사본, 카탈로그에서 빼기, 저장과 날짜별 보관본.
@MainActor
extension LibraryModel {
    // MARK: 가상 사본

    /// 현재 사진의 가상 사본을 원래 항목 바로 뒤에 만들고 선택한다. 원본 파일은 복제하지 않는다.
    /// 지금 내 폴더를 보고 있으면 사본도 그 폴더에 넣어 목록에서 사라지지 않게 한다.
    func createVirtualCopy() {
        guard catalogLoaded, loadError == nil, let source = selection else { return }
        let copy = source.virtualCopy(among: photos)
        let insertAt = (photos.lastIndex { $0.path == source.path } ?? photos.count - 1) + 1
        photos.insert(copy, at: insertAt)
        if case .collection(let folderID) = filter, foldersLoaded, folderLoadError == nil,
           let index = photoFolders.firstIndex(where: { $0.id == folderID }) {
            photoFolders[index].add([copy.id])
        }
        scheduleSave()
        focusPhoto(copy)
        operationMessage = "\(copy.displayName)을 만들었습니다. 원본 파일은 하나이며 보정·별점만 따로 저장됩니다."
    }

    // MARK: 카탈로그에서 빼기

    /// 여러 장을 골랐으면 그 사진들, 아니면 보고 있는 사진.
    var actionTargets: [PhotoAsset] {
        selectedPhotos.isEmpty ? selection.map { [$0] } ?? [] : selectedPhotos
    }

    /// 선택한 사진 중 가상 사본만. 원본 파일과 원래 항목은 그대로다.
    var selectedVirtualCopies: [PhotoAsset] { actionTargets.filter(\.isVirtualCopy) }

    func requestDeleteVirtualCopies() {
        let copies = selectedVirtualCopies
        guard !copies.isEmpty else { return }
        catalogRemoval = CatalogRemoval(photos: copies, hiddenCompanions: 0)
    }

    /// 선택한 사진을 카탈로그에서 빼도록 확인을 요청한다. RAW+JPEG를 한 장으로 보고 있으면
    /// 뺄 RAW 뒤에 숨어 있던 JPEG도 함께 뺀다. 남겨 두면 RAW가 사라진 뒤 따로 나타나기 때문이다.
    func requestRemoveFromCatalog() {
        guard catalogLoaded, loadError == nil else { return }
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let companions = activeCompanions
        let hidden = photos.filter { photo in
            guard !ids.contains(photo.id), let raws = companions[photo.id] else { return false }
            return raws.allSatisfy(ids.contains)
        }
        catalogRemoval = CatalogRemoval(photos: targets + hidden, hiddenCompanions: hidden.count)
    }

    /// 항목을 카탈로그에서 뺀다. 원본 파일은 지우거나 옮기지 않는다. ⌘Z로 원래 자리·보정·내 폴더와 함께 되돌린다.
    func removeFromCatalog(_ ids: Set<UUID>) {
        guard catalogLoaded, loadError == nil else { return }
        let removed = photos.enumerated().compactMap { index, photo -> RemovedPhoto? in
            guard ids.contains(photo.id) else { return nil }
            let folders = photoFolders.filter { $0.photoIDs.contains(photo.id) }.map(\.id)
            return RemovedPhoto(index: index, photo: photo, folderIDs: folders)
        }
        guard !removed.isEmpty else { return }
        editHistory.recordRemoval(removed)
        performRemoval(Set(removed.map(\.photo.id)))
        let copiesOnly = removed.allSatisfy(\.photo.isVirtualCopy)
        operationMessage = (copiesOnly ? "가상 사본 \(removed.count)개를 지웠습니다." : "카탈로그에서 \(removed.count)장을 뺐습니다.") +
            " 원본 파일은 그대로이며 ⌘Z로 되돌릴 수 있습니다."
    }

    /// 빼기와 다시 실행에서 쓴다. 기록은 남기지 않는다. 디스크의 썸네일은 되돌릴 때를 위해 다음 실행까지 둔다.
    func performRemoval(_ removedIDs: Set<UUID>) {
        // 보고 있던 사진을 빼면 같은 파일의 남은 항목(사본을 지운 경우), 없으면 목록에서 그 뒤(끝이면 앞) 사진으로 옮긴다.
        let removedCurrent = selection.map { removedIDs.contains($0.id) } ?? false
        let fallbackPath = removedCurrent ? selection?.path : nil
        var nextID: UUID?
        if removedCurrent {
            let visible = visiblePhotos
            if let index = visible.firstIndex(where: { $0.id == selectedID }) {
                nextID = (visible[(index + 1)...].first { !removedIDs.contains($0.id) } ??
                          visible[..<index].last { !removedIDs.contains($0.id) })?.id
            }
        }
        photos.removeAll { removedIDs.contains($0.id) }
        if foldersLoaded, folderLoadError == nil {
            for index in photoFolders.indices { photoFolders[index].remove(removedIDs) }
        }
        for id in removedIDs {
            burstQualities[id] = nil
            burstFailedIDs.remove(id)
            thumbnailCache.removeObject(forKey: id.uuidString as NSString)
        }
        if pinnedID.map(removedIDs.contains) == true { pinnedID = nil }
        scheduleSave()
        ensureSelectionVisible()
        guard removedCurrent else { return }
        let visible = visiblePhotos
        if let fallbackPath, let sibling = visible.first(where: { $0.path == fallbackPath }) {
            focusPhoto(sibling)
        } else if let nextID, let next = visible.first(where: { $0.id == nextID }) {
            focusPhoto(next)
        }
    }

    /// 뺐던 사진을 빼기 전 순서와 내 폴더에 되돌린다. 그사이 같은 파일을 다시 가져왔으면 그 항목은 건너뛴다.
    func restoreRemoved(_ removed: [RemovedPhoto]) {
        var updated = photos
        let present = Set(updated.map { "\($0.path)|\($0.copyName ?? "")" })
        var restored: [RemovedPhoto] = []
        for item in removed.sorted(by: { $0.index < $1.index })
        where updated.allSatisfy({ $0.id != item.photo.id }) && !present.contains("\(item.photo.path)|\(item.photo.copyName ?? "")") {
            updated.insert(item.photo, at: min(item.index, updated.count))
            restored.append(item)
        }
        guard !restored.isEmpty else {
            operationMessage = "되돌릴 사진이 이미 카탈로그에 있습니다."
            return
        }
        photos = updated
        if foldersLoaded, folderLoadError == nil {
            for item in restored {
                for folderID in item.folderIDs {
                    photoFolders.firstIndex { $0.id == folderID }.map { photoFolders[$0].add([item.photo.id]) }
                }
            }
        }
        scheduleSave()
        // 되돌린 사진을 보여 준다. 빼기 뒤에는 다음 사진이 선택되어 있으므로 선택이 비었는지와 관계없이 옮긴다.
        focusPhoto(restored[0].photo)
        ensureSelectionVisible()
        let skipped = removed.count - restored.count
        operationMessage = "\(restored.count)장을 카탈로그에 되돌렸습니다." +
            (skipped > 0 ? " \(skipped)장은 그사이 다시 가져와 건너뛰었습니다." : "")
    }

    func scheduleSave(debounce: Bool = false) {
        guard catalogLoaded, loadError == nil else { return }
        saveDelay?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveDelay = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.45 : 0.05), execute: item)
    }

    private func saveNow() {
        guard catalogLoaded, loadError == nil else { return }
        let snapshot = photos
        let folderSnapshot = photoFolders
        let canSaveFolders = foldersLoaded && folderLoadError == nil
        saveQueue.async { [catalog, folderStore] in
            do {
                try catalog.save(snapshot)
                if canSaveFolders { try folderStore.save(folderSnapshot) }
            }
            catch {
                AppLog.catalog.error("catalog save failed: \(error.localizedDescription, privacy: .private)")
                DispatchQueue.main.async { self.operationMessage = "사진 또는 폴더 정보 저장 실패: \(error.localizedDescription)" }
            }
            // 앱을 켜 둔 채 날짜가 바뀌면 그날 첫 저장 때 보관본을 만든다.
            self.backUpIfNeeded(snapshot)
        }
    }

    /// `saveQueue`에서 부른다. 실패는 한 번만 알린다.
    nonisolated func backUpIfNeeded(_ photos: [PhotoAsset]) {
        do {
            try backup.backUpIfNeeded(photos: photos, copying: [folderStore.url, presetStore.url, smartFolderStore.url, peopleStore.url],
                                      linkingMasksFrom: catalog.maskDirectory)
        } catch {
            AppLog.catalog.error("daily backup failed: \(error.localizedDescription, privacy: .private)")
            DispatchQueue.main.async {
                guard !self.backupFailureReported else { return }
                self.backupFailureReported = true
                self.operationMessage = "카탈로그 보관본을 만들지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    func revealBackups() {
        try? FileManager.default.createDirectory(at: backup.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(backup.directory)
    }

    func flushSave() throws {
        guard catalogLoaded, loadError == nil else { return }
        saveDelay?.cancel()
        peopleSaveDelay?.cancel()
        peopleSaveScheduled = false
        let snapshot = photos
        let folderSnapshot = photoFolders
        let canSaveFolders = foldersLoaded && folderLoadError == nil
        try saveQueue.sync {
            try catalog.save(snapshot)
            if canSaveFolders { try folderStore.save(folderSnapshot) }
        }
        if peopleLoaded, peopleLoadError == nil {
            peopleSaveRevision &+= 1
            let peopleSnapshot = peopleCatalog
            do {
                try saveQueue.sync { try peopleStore.save(peopleSnapshot) }
                peopleSaveDirty = false
                peopleSaveUrgent = false
                peopleSaveError = nil
            } catch {
                peopleSaveError = "사람 정보 저장 실패: \(error.localizedDescription)"
                throw error
            }
        }
        try flushSidecars()
    }
}
