import AppKit
import Foundation
import LighthouseCore

/// 카탈로그 밖 원본 파일: 원본 없음 확인과 위치 다시 찾기.
@MainActor
extension LibraryModel {
    // MARK: 원본 없음

    func isMissing(_ photo: PhotoAsset) -> Bool { missingPaths.contains(photo.path) }

    /// 모든 원본 경로가 있는지 백그라운드에서 확인한다. 확인 중에 다시 불리면 끝난 뒤 한 번 더 확인한다.
    func refreshMissingOriginals() {
        guard catalogLoaded, loadError == nil else { return }
        guard !missingScanRunning else { missingScanAgain = true; return }
        missingScanRunning = true
        let paths = Set(photos.map(\.path))
        fileCheckQueue.async {
            let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
            DispatchQueue.main.async {
                self.missingScanRunning = false
                if self.missingPaths != missing {
                    AppLog.files.info("missing originals: \(missing.count, privacy: .public) of \(paths.count, privacy: .public) paths")
                    self.missingPaths = missing
                }
                if self.missingScanAgain {
                    self.missingScanAgain = false
                    self.refreshMissingOriginals()
                }
            }
        }
    }

    func observeFileAvailability() {
        guard fileObservers.isEmpty else { return }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMissingOriginals() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        fileObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                   queue: .main, using: refresh),
            workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main, using: refresh),
            workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main, using: refresh),
        ]
    }

    func presentRelocate(for photo: PhotoAsset) {
        guard catalogLoaded, loadError == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "‘\(photo.url.lastPathComponent)’이 지금 들어 있는 폴더를 고르세요. 그 상위 폴더를 골라도 됩니다."
        panel.prompt = "다시 찾기"
        if panel.runModal() == .OK, let folder = panel.url { relocateMissing(from: photo, to: folder) }
    }

    /// `photo`가 `folder` 아래 어디에 있는지로 옛 폴더와 새 폴더의 대응을 정하고, 같은 옛 폴더 아래에서
    /// 원본을 찾지 못한 항목을 모두 새 위치로 옮겨 적는다. 새 위치에 파일이 있을 때만 바꾸며 파일은 건드리지 않는다.
    func relocateMissing(from photo: PhotoAsset, to folder: URL) {
        guard catalogLoaded, loadError == nil else { return }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let mapping = PhotoRelocation.mapping(for: photo.path, in: root) else {
            operationMessage = "\(root)에서 \(photo.url.lastPathComponent)을 찾지 못했습니다. 파일이 든 폴더나 그 상위 폴더를 고르세요."
            return
        }
        let known = Set(photos.map(\.path))
        var moves: [String: String] = [:]
        var notFound = 0, alreadyInCatalog = 0
        for path in missingPaths {
            guard let target = PhotoRelocation.relocated(path, from: mapping.from, to: mapping.to) else { continue }
            if known.contains(target) { alreadyInCatalog += 1 }
            else if FileManager.default.fileExists(atPath: target) { moves[path] = target }
            else { notFound += 1 }
        }
        guard !moves.isEmpty else {
            operationMessage = "새 위치로 옮길 수 있는 사진이 없습니다." +
                (alreadyInCatalog > 0 ? " \(alreadyInCatalog)개는 새 위치의 파일이 이미 카탈로그에 있습니다." : "")
            return
        }
        AppLog.files.info("relinked \(moves.count, privacy: .public) files, \(notFound, privacy: .public) not found, \(alreadyInCatalog, privacy: .public) already in catalog")
        var updated = photos
        for index in updated.indices {
            if let target = moves[updated[index].path] { updated[index].path = target }
        }
        photos = updated
        missingPaths.subtract(moves.keys)
        ensureSelectionVisible()
        scheduleSave()
        requestRender()
        operationMessage = "파일 \(moves.count)개를 새 위치에서 다시 연결했습니다." +
            (notFound > 0 ? " \(notFound)개는 새 위치에서 찾지 못했습니다." : "") +
            (alreadyInCatalog > 0 ? " \(alreadyInCatalog)개는 새 위치의 파일이 이미 카탈로그에 있어 그대로 두었습니다." : "")
    }
}
