import AppKit
import Foundation
import LighthouseCore

@MainActor
final class LibrarySession: ObservableObject {
    @Published private(set) var library: LibraryModel
    @Published private(set) var isSwitching = false
    @Published var errorMessage: String?

    private let usesEnvironmentRoot: Bool

    init(initialDirectory: URL? = nil) {
        usesEnvironmentRoot = ProcessInfo.processInfo.environment["LIGHTHOUSE_DATA_DIR"]?.isEmpty == false
        library = LibraryModel(dataDirectory: initialDirectory, allowsLaunchImport: true)
    }

    @discardableResult
    func openLibrary(at directory: URL) async -> Bool {
        guard !isSwitching, !library.hasConflictingWorkflow else {
            errorMessage = "진행 중인 작업을 마친 뒤 라이브러리를 열어 주세요."
            return false
        }
        let target = directory.standardizedFileURL
        guard target != library.dataDirectory else { return true }
        isSwitching = true
        defer { isSwitching = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                let catalogURL = target.appendingPathComponent("catalog.json")
                guard FileManager.default.fileExists(atPath: catalogURL.path) else { throw CocoaError(.fileNoSuchFile) }
                let photos = try CatalogStore(url: catalogURL).load()
                _ = try PhotoFolderStore(url: target.appendingPathComponent("folders.json")).load()
                _ = try EditPresetStore(url: target.appendingPathComponent("presets.json")).load()
                _ = try SmartFolderStore(url: target.appendingPathComponent("smart-folders.json")).load()
                _ = try PeopleStore(url: target.appendingPathComponent("people.json")).load()
                _ = try LUTStore(directory: target.appendingPathComponent("LUTs", isDirectory: true)).library()
                let previews = SmartPreviewStore(directory: target.appendingPathComponent("SmartPreviews", isDirectory: true))
                for photo in photos { _ = try previews.record(for: photo) }
            }.value
            await library.cancelWorkflowAndWait()
            library.cancelAutoMask()
            library.cancelFlickerAnalysis()
            library.cancelExport()
            library.cancelImport()
            library.cancelFaceAnalysis()
            try library.flushSave()
            let next = LibraryModel(dataDirectory: target, allowsLaunchImport: false)
            library = next
            if !usesEnvironmentRoot { UserDefaults.standard.set(target.path, forKey: "activeLibraryDirectory") }
            next.start()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "라이브러리를 열 수 없습니다: \(error.localizedDescription)"
            return false
        }
    }

    func presentOpenLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "라이브러리 열기"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in _ = await self?.openLibrary(at: url) }
        }
    }
}
