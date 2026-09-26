import Foundation
import LighthouseCore

/// 촬영 정보 조건과 스마트 폴더.
@MainActor
extension LibraryModel {
    /// 스마트 폴더를 보고 있으면 그 조건.
    var smartFolderCriteria: PhotoCriteria? {
        guard case .smart(let id) = filter else { return nil }
        return smartFolders.first { $0.id == id }?.criteria
    }

    var cameraChoices: [String] { Array(Set(photos.compactMap(\.metadata.camera))).sorted() }
    var lensChoices: [String] { Array(Set(photos.compactMap(\.metadata.lens))).sorted() }

    /// 카탈로그의 가장 이른·늦은 촬영일. 날짜 조건을 켤 때 처음 값으로 쓴다.
    var captureDateRange: ClosedRange<Date>? {
        let dates = photos.compactMap(\.metadata.capturedAt)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
    }

    /// 목록 위에 걸린 검색어·별점·조건을 합친 조건.
    var combinedCriteria: PhotoCriteria {
        var combined = criteria
        combined.text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        combined.minimumRating = max(criteria.minimumRating, minimumRating)
        return combined
    }

    /// 지금 걸린 검색어·별점·조건을 스마트 폴더로 저장하고 연다. 걸었던 조건은 폴더로 옮겨 가므로 비운다.
    func saveSmartFolder(name: String) -> String? {
        guard smartFolderLoadError == nil else { return "스마트 폴더 파일을 읽지 못해 저장할 수 없습니다." }
        let combined = combinedCriteria
        guard !combined.isEmpty else { return "저장할 조건이 없습니다. 조건이나 검색어·별점을 먼저 정하세요." }
        let folder = SmartFolder(name: name, criteria: combined)
        if let error = writeSmartFolders(smartFolders + [folder]) { return error }
        criteria = PhotoCriteria()
        search = ""
        minimumRating = 0
        filter = .smart(folder.id)
        ensureSelectionVisible()
        operationMessage = "스마트 폴더 ‘\(folder.name)’을 만들었습니다. 조건에 맞는 사진이 자동으로 보입니다."
        return nil
    }

    func renameSmartFolder(_ id: UUID, to name: String) -> String? {
        guard let index = smartFolders.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = smartFolders
        updated[index].name = name
        return writeSmartFolders(updated)
    }

    func deleteSmartFolder(_ id: UUID) {
        guard writeSmartFolders(smartFolders.filter { $0.id != id }) == nil else { return }
        if filter == .smart(id) { filter = .all }
        ensureSelectionVisible()
        operationMessage = "스마트 폴더를 삭제했습니다. 사진은 그대로입니다."
    }

    private func writeSmartFolders(_ updated: [SmartFolder]) -> String? {
        do {
            let normalized = try SmartFolderStore.validated(updated)
            try saveQueue.sync { try smartFolderStore.save(normalized) }
            smartFolders = normalized.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return nil
        } catch {
            AppLog.catalog.error("smart folder save failed: \(error.localizedDescription, privacy: .private)")
            return error.localizedDescription
        }
    }

    /// 초점거리를 기록하기 전에 가져온 사진은 원본에서 다시 읽어 채운다. 실행마다 한 번, 찾은 값만 바꾼다.
    func backfillFocalLengths() {
        let exifExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "tif", "tiff"]
        let paths = Set(photos.filter { photo in
            photo.metadata.focalLength == nil && !isMissing(photo) &&
                (photo.isRAW || exifExtensions.contains(photo.url.pathExtension.lowercased()))
        }.map(\.path))
        guard !paths.isEmpty else { return }
        batchQueue.async { [pipeline] in
            var found: [String: Double] = [:]
            for path in paths {
                if let focal = try? pipeline.metadata(for: URL(fileURLWithPath: path)).focalLength { found[path] = focal }
            }
            DispatchQueue.main.async {
                var updated = self.photos
                var changed = 0
                for index in updated.indices where updated[index].metadata.focalLength == nil {
                    guard let focal = found[updated[index].path] else { continue }
                    updated[index].metadata.focalLength = focal
                    changed += 1
                }
                guard changed > 0 else { return }
                AppLog.catalog.info("filled focal length for \(changed, privacy: .public) photos")
                self.photos = updated
                self.scheduleSave()
            }
        }
    }
}
