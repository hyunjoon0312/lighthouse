import AppKit
import Foundation
import LighthouseCore
import UniformTypeIdentifiers

enum WorkspaceMode: String, CaseIterable {
    case grid = "그리드"
    case edit = "사진"
    case compare = "비교"
}

enum LibraryFilter: Hashable {
    case all, picks, rejects, edited, folder(String), collection(UUID)
}

struct PhotoFolderSheetRequest: Identifiable {
    enum Kind { case create, rename(UUID) }
    let id = UUID()
    let kind: Kind
    let initialName: String
    let selectedIDs: [UUID]
}

enum AdjustmentPanel: String {
    case global = "전체 보정"
    case local = "부분 보정"
    case retouch = "복구"
}

enum BrushTool: String {
    case brush = "브러시"
    case eraser = "지우개"
}

enum ExportScope: String, CaseIterable {
    case current, selected, visible
}

struct PreparedJPEGExport: @unchecked Sendable {
    let photoID: UUID
    let edits: EditSettings
    let maxPixel: Int?
    let quality: Double
    let result: JPEGPreview
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var photos: [PhotoAsset] = []
    @Published var photoSelection = PhotoSelectionState()
    @Published var photoFolders: [PhotoFolder] = []
    @Published var foldersLoaded = false
    @Published var folderLoadError: String?
    @Published var folderSheetRequest: PhotoFolderSheetRequest?
    @Published var filter: LibraryFilter = .all
    @Published var search = ""
    @Published var minimumRating = 0
    @Published var mode: WorkspaceMode = .grid
    @Published var isOriginal = false
    @Published var actualSize = false
    @Published var rendered: NSImage?
    @Published var pinnedImage: NSImage?
    @Published var rendering = false
    @Published var imageError: String?
    @Published var pinnedError: String?
    @Published var pinnedID: UUID?
    @Published var loadError: String?
    @Published var catalogLoaded = false
    @Published var operationMessage: String?
    @Published var operationProgress: Double = 0
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var showExport = false
    @Published var showBatchEdit = false
    @Published var referenceMatchSource: PhotoAsset?
    @Published var cropSource: PhotoAsset?
    @Published var exportReport: String?
    @Published var clipboard: EditSettings?
    @Published var isLUTImporting = false
    @Published var lutError: String?
    @Published var savedLUTs: [LUTLibraryItem] = []
    @Published var isLUTLibraryLoading = false
    @Published var lutLibraryError: String?
    @Published var adjustmentPanel: AdjustmentPanel = .global
    @Published var selectedLocalID: UUID?
    @Published var brushTool: BrushTool = .brush
    @Published var brushRadius = 0.04
    @Published var showsMask = true
    @Published var isLocalEditing = false
    @Published var maskImage: NSImage?
    @Published var maskError: String?
    @Published var draftPoints: [MaskPoint] = []
    @Published var brushCursor: MaskPoint?
    @Published var isAutoMasking = false
    @Published var autoMaskError: String?
    @Published var retouchMode: RetouchMode = .heal
    @Published var retouchRadius = 0.02
    @Published var isPickingCloneSource = false
    @Published var cloneSource: MaskPoint?
    @Published var retouchDraftPoints: [MaskPoint] = []
    @Published var retouchCursor: MaskPoint?

    private let pipeline = ImagePipeline()
    private let lutStore = LUTStore()
    private let catalog = CatalogStore(url: CatalogStore.defaultURL)
    private let folderStore = PhotoFolderStore(url: PhotoFolderStore.defaultURL)
    private let previewQueue = DispatchQueue(label: "com.rian.lighthouse.preview", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "com.rian.lighthouse.thumbnails", qos: .utility)
    private let batchQueue = DispatchQueue(label: "com.rian.lighthouse.batch", qos: .userInitiated)
    private let maskQueue = DispatchQueue(label: "com.rian.lighthouse.mask", qos: .userInitiated)
    private let autoMaskQueue = DispatchQueue(label: "com.rian.lighthouse.automask", qos: .userInitiated)
    private let lutQueue = DispatchQueue(label: "com.rian.lighthouse.lut", qos: .userInitiated)
    private let saveQueue = DispatchQueue(label: "com.rian.lighthouse.catalog", qos: .utility)
    private var saveDelay: DispatchWorkItem?
    private var renderDelay: DispatchWorkItem?
    private var generation = 0
    private var renderedSource: String?
    private var maskGeneration = 0
    private var selectionGeneration = 0
    private var autoMaskGeneration = 0
    private var lutLibraryGeneration = 0
    private var maskSource: String?
    private var draftPhotoID: UUID?
    private var draftLocalID: UUID?
    private var started = false
    private var editHistory = EditHistory(limit: 100)
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var loadingThumbnails = Set<String>()

    init() {
        thumbnailCache.countLimit = 240
        thumbnailCache.totalCostLimit = 200 * 1024 * 1024
    }

    var selectedID: UUID? { photoSelection.activeID }
    var selectedPhotoIDs: Set<UUID> { photoSelection.selectedIDs }
    var selectedPhotos: [PhotoAsset] { visiblePhotos.filter { selectedPhotoIDs.contains($0.id) } }
    var selection: PhotoAsset? { photos.first { $0.id == selectedID } }
    var pinned: PhotoAsset? { photos.first { $0.id == pinnedID } }
    var canUndo: Bool { editHistory.canUndo }
    var canRedo: Bool { editHistory.canRedo }
    var hasModalPresentation: Bool {
        showBatchEdit || showExport || referenceMatchSource != nil || folderSheetRequest != nil || cropSource != nil
    }
    var selectedLocal: LocalAdjustment? { selection?.edits.localAdjustments.first { $0.id == selectedLocalID } }
    var canDrawLocal: Bool {
        adjustmentPanel == .local && isLocalEditing && selectedLocal != nil &&
        mode == .edit && !isOriginal && !actualSize && !rendering && rendered != nil && imageError == nil
    }
    var canUseRetouchCanvas: Bool {
        adjustmentPanel == .retouch && mode == .edit && !isOriginal && !actualSize &&
        !rendering && rendered != nil && imageError == nil
    }
    var canDrawRetouch: Bool {
        canUseRetouchCanvas && !isPickingCloneSource && (retouchMode == .heal || cloneSource != nil)
    }

    var folders: [String] {
        Array(Set(photos.map { $0.url.deletingLastPathComponent().path })).sorted()
    }

    func presentCreateFolder() {
        guard foldersLoaded, folderLoadError == nil else { return }
        folderSheetRequest = PhotoFolderSheetRequest(kind: .create, initialName: "",
                                                     selectedIDs: selectedPhotos.map(\.id))
    }

    func presentRenameFolder(_ folder: PhotoFolder) {
        guard foldersLoaded, folderLoadError == nil else { return }
        folderSheetRequest = PhotoFolderSheetRequest(kind: .rename(folder.id), initialName: folder.name,
                                                     selectedIDs: [])
    }

    private func validatedFolderName(_ name: String, excluding id: UUID? = nil) -> (String?, String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return (nil, "폴더 이름은 1–80자여야 합니다.") }
        let key = trimmed.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        if photoFolders.contains(where: {
            $0.id != id && $0.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) == key
        }) {
            return (nil, "같은 이름의 폴더가 이미 있습니다.")
        }
        return (trimmed, nil)
    }

    func commitFolderSheet(_ request: PhotoFolderSheetRequest, name: String, includeSelected: Bool) -> String? {
        guard foldersLoaded, folderLoadError == nil else { return folderLoadError ?? "폴더를 열 수 없습니다." }
        let excluding: UUID?
        switch request.kind { case .create: excluding = nil; case .rename(let id): excluding = id }
        let (validated, error) = validatedFolderName(name, excluding: excluding)
        guard let validated else { return error }
        switch request.kind {
        case .create:
            let existing = Set(photos.map(\.id))
            let members = includeSelected ? Set(request.selectedIDs).intersection(existing) : []
            let folder = PhotoFolder(name: validated, photoIDs: members)
            photoFolders.append(folder)
            photoFolders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            filter = .collection(folder.id)
            ensureSelectionVisible()
        case .rename(let id):
            guard let index = photoFolders.firstIndex(where: { $0.id == id }) else { return "폴더를 찾을 수 없습니다." }
            photoFolders[index].name = validated
            photoFolders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        scheduleSave()
        return nil
    }

    func deleteFolder(_ id: UUID) {
        guard foldersLoaded, folderLoadError == nil else { return }
        photoFolders.removeAll { $0.id == id }
        if filter == .collection(id) { filter = .all }
        ensureSelectionVisible()
        scheduleSave()
        operationMessage = "폴더만 삭제했습니다. 사진과 보정은 보관됩니다."
    }

    func addSelectedPhotos(to folderID: UUID) {
        guard foldersLoaded, folderLoadError == nil,
              let index = photoFolders.firstIndex(where: { $0.id == folderID }) else { return }
        let ids = Set(selectedPhotos.map(\.id))
        let before = photoFolders[index].photoIDs.count
        photoFolders[index].add(ids)
        let added = photoFolders[index].photoIDs.count - before
        if added > 0 { scheduleSave() }
        operationMessage = "\(photoFolders[index].name)에 \(added)장 추가했습니다."
    }

    func removeSelectedPhotosFromCurrentFolder() {
        guard foldersLoaded, folderLoadError == nil,
              case .collection(let id) = filter,
              let index = photoFolders.firstIndex(where: { $0.id == id }) else { return }
        let ids = Set(selectedPhotos.map(\.id))
        let before = photoFolders[index].photoIDs.count
        photoFolders[index].remove(ids)
        let removed = before - photoFolders[index].photoIDs.count
        if removed > 0 { scheduleSave() }
        ensureSelectionVisible()
        operationMessage = "폴더에서 \(removed)장을 뺐습니다. 사진과 보정은 보관됩니다."
    }

    var visiblePhotos: [PhotoAsset] {
        photos.filter { photo in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .picks: matchesFilter = photo.flag == .pick
            case .rejects: matchesFilter = photo.flag == .reject
            case .edited: matchesFilter = photo.edits.isModified
            case .folder(let path): matchesFilter = photo.url.deletingLastPathComponent().path == path
            case .collection(let id): matchesFilter = photoFolders.first(where: { $0.id == id })?.photoIDs.contains(photo.id) ?? false
            }
            return matchesFilter && photo.rating >= minimumRating &&
                (search.isEmpty || photo.filename.localizedCaseInsensitiveContains(search))
        }
    }

    func start() {
        guard !started else { return }
        started = true
        batchQueue.async { [catalog, folderStore] in
            let result = Result { try catalog.load() }
            let folders = Result { try folderStore.load() }
            DispatchQueue.main.async {
                switch result {
                case .success(let photos):
                    self.photos = photos
                    self.catalogLoaded = true
                    switch folders {
                    case .success(let loaded): self.photoFolders = loaded; self.foldersLoaded = true
                    case .failure(let error): self.folderLoadError = error.localizedDescription
                    }
                    if let first = photos.first {
                        self.photoSelection.select(first.id, in: photos.map(\.id))
                    }
                    self.refreshLUTLibrary()
                    self.requestRender()
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "--import"), arguments.indices.contains(index + 1) {
                        self.importURLs([URL(fileURLWithPath: arguments[index + 1])])
                    }
                case .failure(let error):
                    self.loadError = "카탈로그를 열 수 없습니다. 파일을 확인한 뒤 앱을 다시 실행하세요.\n\(error.localizedDescription)"
                }
            }
        }
    }

    func select(_ photo: PhotoAsset) {
        let previous = selectedID
        photoSelection.select(photo.id, in: visiblePhotos.map(\.id))
        selectionDidChange(previousActive: previous)
    }

    func selectFromClick(_ photo: PhotoAsset) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let mode: PhotoSelectionMode = flags.contains(.shift) ? .range : flags.contains(.command) ? .toggle : .single
        let previous = selectedID
        photoSelection.select(photo.id, in: visiblePhotos.map(\.id), mode: mode)
        selectionDidChange(previousActive: previous)
    }

    func togglePhotoSelection(_ photo: PhotoAsset) {
        let previous = selectedID
        photoSelection.select(photo.id, in: visiblePhotos.map(\.id), mode: .toggle)
        selectionDidChange(previousActive: previous)
    }

    func focusPhoto(_ photo: PhotoAsset) {
        let previous = selectedID
        photoSelection.focus(photo.id, in: visiblePhotos.map(\.id))
        selectionDidChange(previousActive: previous)
    }

    func selectAllVisible() {
        let previous = selectedID
        photoSelection.selectAll(in: visiblePhotos.map(\.id))
        selectionDidChange(previousActive: previous)
    }

    func clearPhotoSelection() {
        let previous = selectedID
        photoSelection.clear()
        selectionDidChange(previousActive: previous)
    }

    private func selectionDidChange(previousActive: UUID?, clearFocus: Bool = true) {
        if clearFocus { NSApp.keyWindow?.makeFirstResponder(nil) }
        cancelDraft()
        guard previousActive != selectedID else { objectWillChange.send(); return }
        selectionGeneration += 1
        cancelAutoMask()
        cancelRetouchDraft(clearSource: true)
        isLocalEditing = false
        lutError = nil
        reconcileLocalSelection()
        requestRender()
    }

    func ensureSelectionVisible() {
        guard catalogLoaded else { return }
        let previous = selectedID
        photoSelection.reconcile(with: visiblePhotos.map(\.id))
        selectionDidChange(previousActive: previous, clearFocus: false)
    }

    func move(_ direction: Int) {
        let visible = visiblePhotos
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex(where: { $0.id == selectedID }) ?? (direction > 0 ? -1 : visible.count)
        let next = min(max(index + direction, 0), visible.count - 1)
        focusPhoto(visible[next])
    }

    func setMode(_ newMode: WorkspaceMode) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if newMode != .edit { cancelDraft(); cancelRetouchDraft(); isLocalEditing = false }
        if newMode == .compare && mode != .compare {
            pinnedID = selectedID
            pinnedImage = nil
            pinnedError = nil
        }
        mode = newMode
        requestRender()
    }

    func toggleOriginal() {
        cancelDraft()
        cancelRetouchDraft()
        isOriginal.toggle()
        if isOriginal { isLocalEditing = false }
        requestRender()
    }
    func toggleActualSize() {
        cancelDraft()
        cancelRetouchDraft()
        actualSize.toggle()
        if actualSize { isLocalEditing = false }
        requestRender()
    }

    func updatePhoto(_ id: UUID, _ change: (inout PhotoAsset) -> Void, debounce: Bool = false) {
        guard catalogLoaded, loadError == nil, let index = photos.firstIndex(where: { $0.id == id }) else { return }
        change(&photos[index])
        scheduleSave(debounce: debounce)
        if selectedID == id { reconcileLocalSelection() }
        let previousSelection = selectedID
        ensureSelectionVisible()
        if previousSelection == selectedID && (selectedID == id || pinnedID == id) {
            requestRender(debounce: debounce)
        }
    }

    func updateEdits(_ edits: EditSettings) {
        guard let selected = selection, selected.edits != edits else { return }
        applyEditChanges([PhotoEditChange(id: selected.id, before: selected.edits, after: edits)],
                         useAfter: true, record: true, debounce: true)
    }

    func undo() {
        cancelDraft()
        cancelRetouchDraft()
        guard let changes = editHistory.undo() else { return }
        applyEditChanges(changes, useAfter: false, record: false)
    }

    func redo() {
        cancelDraft()
        cancelRetouchDraft()
        guard let changes = editHistory.redo() else { return }
        applyEditChanges(changes, useAfter: true, record: false)
    }

    private func applyEditChanges(_ changes: [PhotoEditChange], useAfter: Bool,
                                  record: Bool, debounce: Bool = false) {
        guard catalogLoaded, loadError == nil else { return }
        var updated = photos
        var indices: [UUID: Int] = [:]
        for (index, photo) in updated.enumerated() { indices[photo.id] = index }
        var actual: [PhotoEditChange] = []
        for change in changes {
            guard let index = indices[change.id] else { continue }
            let destination = useAfter ? change.after : change.before
            let before = updated[index].edits
            guard before != destination else { continue }
            updated[index].edits = destination
            actual.append(PhotoEditChange(id: change.id, before: before, after: destination))
        }
        guard !actual.isEmpty else { return }
        if record { editHistory.record(actual) }
        cancelDraft()
        cancelRetouchDraft()
        cancelAutoMask()
        photos = updated
        let previous = selectedID
        photoSelection.reconcile(with: visiblePhotos.map(\.id))
        if previous != selectedID {
            selectionGeneration += 1
            isLocalEditing = false
            lutError = nil
        }
        reconcileLocalSelection()
        scheduleSave(debounce: debounce)
        requestRender(debounce: debounce)
    }

    func applyBatchEdits(source: EditSettings, to ids: [UUID], components: EditComponents) {
        guard catalogLoaded, loadError == nil, !components.isEmpty else { return }
        let visible = Set(visiblePhotos.map(\.id))
        let requested = Set(ids).intersection(visible)
        let changes = photos.compactMap { photo -> PhotoEditChange? in
            guard requested.contains(photo.id) else { return nil }
            let after = photo.edits.merging(from: source, components: components)
            return after == photo.edits ? nil : PhotoEditChange(id: photo.id, before: photo.edits, after: after)
        }
        applyEditChanges(changes, useAfter: true, record: true)
        operationMessage = "선택 \(ids.count)장 중 \(changes.count)장 보정 변경"
    }

    func applyCurrentLUTToSelection() {
        guard let current = selection, current.edits.lut != nil, selectedPhotoIDs.count >= 2 else { return }
        applyBatchEdits(source: current.edits, to: selectedPhotos.map(\.id), components: .lut)
    }

    func setRating(_ rating: Int) {
        guard let id = selectedID else { return }
        updatePhoto(id, { $0.rating = rating })
    }

    func setFlag(_ flag: PhotoFlag) {
        guard let id = selectedID else { return }
        updatePhoto(id, { $0.flag = flag })
    }

    func copyEdits() { clipboard = selection?.edits }

    private func knownLUTNames() -> [String: String] {
        var names: [String: String] = [:]
        for photo in photos {
            if let lut = photo.edits.lut, names[lut.id] == nil { names[lut.id] = lut.name }
        }
        return names
    }

    func refreshLUTLibrary() {
        guard catalogLoaded, loadError == nil else { return }
        lutLibraryGeneration += 1
        let token = lutLibraryGeneration
        let names = knownLUTNames()
        isLUTLibraryLoading = true
        lutQueue.async { [lutStore] in
            let result = Result { try lutStore.library(knownNames: names) }
            DispatchQueue.main.async {
                guard token == self.lutLibraryGeneration else { return }
                self.isLUTLibraryLoading = false
                switch result {
                case .success(let items): self.savedLUTs = items; self.lutLibraryError = nil
                case .failure(let error): self.lutLibraryError = error.localizedDescription
                }
            }
        }
    }

    func presentLUTImport() {
        guard catalogLoaded, loadError == nil, !isLUTImporting, !isLUTLibraryLoading else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "사진용 SDR sRGB 3D .cube 파일을 추가합니다. V-Log, .vlt, 1D LUT는 지원하지 않습니다."
        panel.prompt = "LUT 추가"
        if panel.runModal() == .OK { importLUTs(from: panel.urls) }
    }

    private func importLUTs(from urls: [URL]) {
        guard !urls.isEmpty, catalogLoaded, loadError == nil, !isLUTImporting else { return }
        let photoID = selectedID
        let generation = selectionGeneration
        lutLibraryGeneration += 1
        let libraryToken = lutLibraryGeneration
        isLUTImporting = true
        isLUTLibraryLoading = true
        lutError = nil
        let names = knownLUTNames()
        lutQueue.async { [lutStore] in
            var imported: [LUTAdjustment] = []
            var failures: [String] = []
            for url in urls {
                do { imported.append(try lutStore.importCube(from: url)) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            var combinedNames = names
            for lut in imported { combinedNames[lut.id] = lut.name }
            let library = Result { try lutStore.library(knownNames: combinedNames) }
            DispatchQueue.main.async {
                self.isLUTImporting = false
                if libraryToken == self.lutLibraryGeneration {
                    self.isLUTLibraryLoading = false
                    switch library {
                    case .success(let items):
                        self.savedLUTs = items
                        self.lutLibraryError = nil
                    case .failure(let error):
                        var byID = Dictionary(uniqueKeysWithValues: self.savedLUTs.map { ($0.id, $0) })
                        for lut in imported { byID[lut.id] = LUTLibraryItem(id: lut.id, name: lut.name) }
                        self.savedLUTs = byID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                        self.lutLibraryError = error.localizedDescription
                    }
                }
                var skippedApplication = false
                if urls.count == 1, imported.count == 1 {
                    if self.selectedID == photoID, self.selectionGeneration == generation,
                       let current = self.selection {
                        var edits = current.edits
                        edits.lut = imported[0]
                        self.updateEdits(edits)
                        self.isOriginal = false
                        self.actualSize = false
                        self.setMode(.edit)
                    } else {
                        skippedApplication = true
                    }
                }
                let summary = "LUT \(imported.count)개 보관 · 실패 \(failures.count)개"
                if !failures.isEmpty, self.selectedID == photoID, self.selectionGeneration == generation {
                    self.lutError = failures.joined(separator: "\n")
                }
                self.operationMessage = summary + (skippedApplication ? " · 사진 선택이 바뀌어 적용하지 않음" : "") +
                    (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
            }
        }
    }

    func selectSavedLUT(_ id: String) {
        if id.isEmpty { removeLUT(); return }
        guard let current = selection, let item = savedLUTs.first(where: { $0.id == id }) else { return }
        guard item.error == nil else { lutError = "사용할 수 없는 LUT: \(item.error ?? "파일 오류")"; return }
        var edits = current.edits
        edits.lut = LUTAdjustment(id: item.id, name: item.name,
                                  intensity: edits.lut?.intensity ?? 1, isEnabled: true)
        updateEdits(edits)
        lutError = nil
        isOriginal = false
        actualSize = false
        setMode(.edit)
    }

    func presentReferenceMatch() {
        guard catalogLoaded, loadError == nil, referenceMatchSource == nil, let source = selection else { return }
        cancelDraft()
        isLocalEditing = false
        referenceMatchSource = source
    }

    func finishReferenceMatch(_ adjustment: LUTAdjustment, apply: Bool, source: PhotoAsset) {
        refreshLUTLibrary()
        guard apply else {
            operationMessage = "색감 LUT를 보관했습니다. 현재 사진의 보정은 유지됩니다."
            return
        }
        guard let current = selection, current.id == source.id, current.edits == source.edits else {
            operationMessage = "색감 LUT를 보관했지만 사진이나 보정이 바뀌어 적용하지 않았습니다."
            return
        }
        var edits = current.edits
        edits.lut = adjustment
        updateEdits(edits)
        isOriginal = false
        actualSize = false
        setMode(.edit)
    }

    func updateLUT(_ change: (inout LUTAdjustment) -> Void) {
        guard let current = selection, var lut = current.edits.lut else { return }
        var edits = current.edits
        change(&lut)
        edits.lut = lut
        updateEdits(edits)
    }

    func removeLUT() {
        guard let current = selection, current.edits.lut != nil else { return }
        var edits = current.edits
        edits.lut = nil
        updateEdits(edits)
        lutError = nil
    }

    func enterLocalPanel() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        adjustmentPanel = .local
        cancelDraft()
        cancelRetouchDraft()
        isOriginal = false
        actualSize = false
        mode = .edit
        reconcileLocalSelection()
        isLocalEditing = selectedLocal != nil
        requestRender()
    }

    func enterRetouchPanel() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        adjustmentPanel = .retouch
        cancelDraft()
        cancelRetouchDraft()
        isLocalEditing = false
        isOriginal = false
        actualSize = false
        mode = .edit
        maskImage = nil
        maskGeneration += 1
        requestRender()
    }

    func leaveLocalPanel() {
        cancelDraft()
        cancelRetouchDraft()
        isLocalEditing = false
        adjustmentPanel = .global
        maskImage = nil
        maskGeneration += 1
    }

    func chooseLocal(_ id: UUID) {
        enterLocalPanel()
        selectedLocalID = id
        isLocalEditing = true
        requestMask()
    }

    func addLocal() {
        guard let selected = selection else { return }
        enterLocalPanel()
        var edits = selected.edits
        let adjustment = LocalAdjustment(name: "영역 \(edits.localAdjustments.count + 1)")
        edits.localAdjustments.append(adjustment)
        selectedLocalID = adjustment.id
        isLocalEditing = true
        updateEdits(edits)
    }

    func addAutomaticLocal(background: Bool) {
        guard !isAutoMasking, let photo = selection else { return }
        enterLocalPanel()
        autoMaskGeneration += 1
        let token = autoMaskGeneration
        let photoID = photo.id
        let editsSnapshot = photo.edits
        let selectionToken = selectionGeneration
        isAutoMasking = true
        autoMaskError = nil
        autoMaskQueue.async { [pipeline] in
            let result = Result { try pipeline.subjectMask(url: photo.url) }
            DispatchQueue.main.async {
                guard token == self.autoMaskGeneration else { return }
                self.isAutoMasking = false
                guard self.selectedID == photoID, self.selectionGeneration == selectionToken,
                      let current = self.selection, current.edits == editsSnapshot else {
                    self.autoMaskError = "사진이나 보정이 바뀌어 자동 선택 결과를 적용하지 않았습니다."
                    return
                }
                switch result {
                case .success(let mask):
                    var edits = current.edits
                    let adjustment = LocalAdjustment(
                        name: background ? "자동 배경" : "자동 피사체",
                        baseMask: mask,
                        isInverted: background
                    )
                    edits.localAdjustments.append(adjustment)
                    self.selectedLocalID = adjustment.id
                    self.isLocalEditing = true
                    self.updateEdits(edits)
                case .failure(let error):
                    self.autoMaskError = "자동 선택 실패: \(error.localizedDescription) 브러시로 영역을 직접 추가할 수 있습니다."
                }
            }
        }
    }

    func cancelAutoMask() {
        autoMaskGeneration += 1
        isAutoMasking = false
    }

    func updateLocal(_ change: (inout LocalAdjustment) -> Void) {
        guard let selected = selection,
              let index = selected.edits.localAdjustments.firstIndex(where: { $0.id == selectedLocalID }) else { return }
        var edits = selected.edits
        change(&edits.localAdjustments[index])
        updateEdits(edits)
    }

    func deleteLocal() {
        guard let selected = selection, let id = selectedLocalID else { return }
        var edits = selected.edits
        edits.localAdjustments.removeAll { $0.id == id }
        selectedLocalID = edits.localAdjustments.first?.id
        if selectedLocalID == nil { isLocalEditing = false }
        updateEdits(edits)
    }

    func finishLocalDrawing() { cancelDraft(); isLocalEditing = false }

    func beginStroke(at displayPoint: MaskPoint) {
        guard canDrawLocal, let photoID = selectedID, let localID = selectedLocalID else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        draftPhotoID = photoID
        draftLocalID = localID
        draftPoints = [displayPoint]
        brushCursor = displayPoint
    }

    func extendStroke(to displayPoint: MaskPoint, shortSide: CGFloat) {
        guard draftPhotoID == selectedID, draftLocalID == selectedLocalID,
              let last = draftPoints.last else { return }
        brushCursor = displayPoint
        let dx = (displayPoint.x - last.x) * Double(shortSide)
        let dy = (displayPoint.y - last.y) * Double(shortSide)
        if hypot(dx, dy) >= max(1, brushRadius * Double(shortSide) * 0.2) {
            draftPoints.append(displayPoint)
        }
    }

    func commitStroke() {
        guard draftPhotoID == selectedID, draftLocalID == selectedLocalID,
              let selected = selection, let index = selected.edits.localAdjustments.firstIndex(where: { $0.id == selectedLocalID }),
              !draftPoints.isEmpty, selected.metadata.width > 0, selected.metadata.height > 0 else {
            cancelDraft(); return
        }
        let geometry = LocalMaskGeometry(sourceWidth: Double(selected.metadata.width),
                                         sourceHeight: Double(selected.metadata.height),
                                         edits: selected.edits)
        let points = draftPoints.map { geometry.sourcePoint(fromDisplay: $0) }
        let stroke = MaskStroke(points: points, radius: brushRadius, isErasing: brushTool == .eraser)
        var edits = selected.edits
        edits.localAdjustments[index].strokes.append(stroke)
        cancelDraft()
        updateEdits(edits)
    }

    func cancelDraft() {
        draftPoints = []
        draftPhotoID = nil
        draftLocalID = nil
        brushCursor = nil
    }

    private func reconcileLocalSelection() {
        let areas = selection?.edits.localAdjustments ?? []
        if !areas.contains(where: { $0.id == selectedLocalID }) {
            selectedLocalID = areas.first?.id
            if selectedLocalID == nil { isLocalEditing = false }
        }
        requestMask()
    }

    func requestMask() {
        maskGeneration += 1
        let token = maskGeneration
        guard adjustmentPanel == .local, showsMask, mode == .edit, !isOriginal, !actualSize,
              let photo = selection, let adjustment = selectedLocal,
              photo.metadata.width > 0, photo.metadata.height > 0 else {
            maskImage = nil; maskError = nil; maskSource = nil; return
        }
        let source = "\(photo.id):\(adjustment.id):\(photo.edits.rotationQuarterTurns):\(photo.edits.straightenDegrees):\(String(describing: photo.edits.cropRect)): \(photo.edits.cropAspect ?? 0)"
        if source != maskSource { maskImage = nil; maskSource = source }
        maskQueue.async { [pipeline] in
            let result = Result {
                try pipeline.renderMask(adjustment: adjustment,
                                        sourceWidth: photo.metadata.width,
                                        sourceHeight: photo.metadata.height,
                                        edits: photo.edits, maxPixel: 1600)
            }
            DispatchQueue.main.async {
                guard token == self.maskGeneration else { return }
                switch result {
                case .success(let cg):
                    self.maskError = nil
                    self.maskImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                case .failure(let error):
                    self.maskImage = nil
                    self.maskError = error.localizedDescription
                }
            }
        }
    }

    func pasteToNext() {
        guard let edits = clipboard else { return }
        move(1)
        updateEdits(edits)
    }

    func presentCrop() {
        guard cropSource == nil, let source = selection else { return }
        cancelDraft()
        cancelRetouchDraft()
        isLocalEditing = false
        cropSource = source
    }

    func applyCrop(source: PhotoAsset, crop: NormalizedCrop, straightenDegrees: Double) {
        guard let current = selection, current.id == source.id, current.edits == source.edits else {
            operationMessage = "사진이나 보정이 바뀌어 크롭을 적용하지 않았습니다."
            return
        }
        var edits = current.edits
        let clamped = crop.clamped
        edits.cropRect = clamped == .full ? nil : clamped
        edits.cropAspect = nil
        edits.straightenDegrees = min(20, max(-20, straightenDegrees.isFinite ? straightenDegrees : 0))
        updateEdits(edits)
    }

    func beginRetouch(at displayPoint: MaskPoint) {
        guard canUseRetouchCanvas else { return }
        if retouchMode == .clone && isPickingCloneSource {
            cloneSource = sourcePoint(fromDisplay: displayPoint)
            isPickingCloneSource = false
            retouchCursor = displayPoint
            return
        }
        guard canDrawRetouch else { return }
        retouchDraftPoints = [displayPoint]
        retouchCursor = displayPoint
    }

    func extendRetouch(to displayPoint: MaskPoint, shortSide: CGFloat) {
        guard canDrawRetouch, let last = retouchDraftPoints.last else { return }
        retouchCursor = displayPoint
        let dx = (displayPoint.x - last.x) * Double(shortSide)
        let dy = (displayPoint.y - last.y) * Double(shortSide)
        if hypot(dx, dy) >= max(1, retouchRadius * Double(shortSide) * 0.2) {
            retouchDraftPoints.append(displayPoint)
        }
    }

    func commitRetouch() {
        guard canDrawRetouch, let selected = selection, !retouchDraftPoints.isEmpty else {
            cancelRetouchDraft(); return
        }
        let geometry = PhotoGeometry(sourceWidth: Double(selected.metadata.width),
                                     sourceHeight: Double(selected.metadata.height), edits: selected.edits)
        let points = retouchDraftPoints.map { geometry.sourcePoint(fromDisplay: $0) }
        let offset: MaskPoint?
        if retouchMode == .clone, let source = cloneSource, let destination = points.first {
            offset = MaskPoint(x: source.x - destination.x, y: source.y - destination.y)
        } else {
            offset = nil
        }
        var edits = selected.edits
        edits.retouchStrokes.append(RetouchStroke(mode: retouchMode, points: points,
                                                  radius: retouchRadius, sourceOffset: offset))
        cancelRetouchDraft()
        updateEdits(edits)
    }

    func cancelRetouchDraft(clearSource: Bool = false) {
        retouchDraftPoints = []
        retouchCursor = nil
        isPickingCloneSource = false
        if clearSource { cloneSource = nil }
    }

    func setRetouchStrokeEnabled(_ id: UUID, enabled: Bool) {
        guard let selected = selection,
              let index = selected.edits.retouchStrokes.firstIndex(where: { $0.id == id }) else { return }
        var edits = selected.edits
        edits.retouchStrokes[index].isEnabled = enabled
        updateEdits(edits)
    }

    func deleteRetouchStroke(_ id: UUID) {
        guard let selected = selection else { return }
        var edits = selected.edits
        edits.retouchStrokes.removeAll { $0.id == id }
        updateEdits(edits)
    }

    func clearRetouchStrokes() {
        guard let selected = selection, !selected.edits.retouchStrokes.isEmpty else { return }
        var edits = selected.edits
        edits.retouchStrokes = []
        updateEdits(edits)
    }

    func displayPoint(fromSource point: MaskPoint) -> MaskPoint? {
        guard let selected = selection, selected.metadata.width > 0, selected.metadata.height > 0 else { return nil }
        return PhotoGeometry(sourceWidth: Double(selected.metadata.width),
                             sourceHeight: Double(selected.metadata.height), edits: selected.edits)
            .displayPoint(fromSource: point)
    }

    private func sourcePoint(fromDisplay point: MaskPoint) -> MaskPoint {
        guard let selected = selection else { return point }
        return PhotoGeometry(sourceWidth: Double(selected.metadata.width),
                             sourceHeight: Double(selected.metadata.height), edits: selected.edits)
            .sourcePoint(fromDisplay: point)
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
            catch { DispatchQueue.main.async { self.operationMessage = "사진 또는 폴더 정보 저장 실패: \(error.localizedDescription)" } }
        }
    }

    func flushSave() throws {
        guard catalogLoaded, loadError == nil else { return }
        saveDelay?.cancel()
        let snapshot = photos
        let folderSnapshot = photoFolders
        let canSaveFolders = foldersLoaded && folderLoadError == nil
        try saveQueue.sync {
            try catalog.save(snapshot)
            if canSaveFolders { try folderStore.save(folderSnapshot) }
        }
    }

    func thumbnail(for photo: PhotoAsset) -> NSImage? {
        thumbnailCache.object(forKey: photo.path as NSString)
    }

    func requestThumbnail(for photo: PhotoAsset) {
        guard thumbnail(for: photo) == nil, !loadingThumbnails.contains(photo.path) else { return }
        loadingThumbnails.insert(photo.path)
        thumbnailQueue.async { [pipeline] in
            let result = try? pipeline.thumbnail(for: photo.url, maxPixel: 360)
            DispatchQueue.main.async {
                self.loadingThumbnails.remove(photo.path)
                if let result {
                    let image = NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
                    self.thumbnailCache.setObject(image, forKey: photo.path as NSString, cost: result.width * result.height * 4)
                    self.objectWillChange.send()
                }
            }
        }
    }

    func requestRender(debounce: Bool = false) {
        renderDelay?.cancel()
        generation += 1
        let token = generation
        let source = "\(selectedID?.uuidString ?? "none"):\(isOriginal):\(actualSize)"
        if renderedSource != source {
            rendered = nil
            imageError = nil
            renderedSource = source
        }
        if mode != .compare { pinnedImage = nil; pinnedError = nil }
        requestMask()
        guard mode != .grid, let photo = selection else { rendering = false; return }
        rendering = true
        let compare = mode == .compare ? pinned : nil
        let edits = isOriginal ? EditSettings.neutral : photo.edits
        let maxPixel: Int? = actualSize ? nil : 2200
        let job = DispatchWorkItem { [pipeline] in
            let current = Result { try pipeline.render(url: photo.url, edits: edits, maxPixel: maxPixel) }
            let reference = compare.map { fixed in
                Result { try pipeline.render(url: fixed.url, edits: .neutral, maxPixel: maxPixel) }
            }
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.rendering = false
                switch current {
                case .success(let cg):
                    self.imageError = nil
                    self.rendered = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                case .failure(let error):
                    self.rendered = nil
                    self.imageError = error.localizedDescription
                }
                if let reference {
                    switch reference {
                    case .success(let cg):
                        self.pinnedError = nil
                        self.pinnedImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    case .failure(let error):
                        self.pinnedImage = nil
                        self.pinnedError = error.localizedDescription
                    }
                }
            }
        }
        renderDelay = job
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.22 : 0), execute: DispatchWorkItem {
            self.previewQueue.async(execute: job)
        })
    }

    func presentImport() {
        guard catalogLoaded, loadError == nil, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "가져오기"
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func importURLs(_ urls: [URL]) {
        guard catalogLoaded, loadError == nil, !isImporting else { return }
        isImporting = true
        operationProgress = 0
        operationMessage = "파일을 찾는 중…"
        let existing = Set(photos.map(\.path))
        batchQueue.async { [pipeline] in
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
            var seen = existing
            let candidates = paths.filter { seen.insert($0.path).inserted }
            var added: [PhotoAsset] = []
            var failed: [String] = []
            for (index, url) in candidates.enumerated() {
                do { added.append(PhotoAsset(url: url, metadata: try pipeline.metadata(for: url))) }
                catch { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                let progress = Double(index + 1) / Double(max(1, candidates.count))
                DispatchQueue.main.async { self.operationProgress = progress; self.operationMessage = "가져오는 중 \(index + 1)/\(candidates.count)" }
            }
            DispatchQueue.main.async {
                self.photos.append(contentsOf: added)
                self.photos.sort { ($0.metadata.capturedAt ?? $0.importedAt) < ($1.metadata.capturedAt ?? $1.importedAt) }
                if self.selectedID == nil, let first = added.first {
                    self.photoSelection.select(first.id, in: self.visiblePhotos.map(\.id))
                }
                self.isImporting = false
                self.operationMessage = "\(added.count)장 가져옴 · 중복 \(paths.count - candidates.count)장 · 실패 \(failed.count)장" + (failed.isEmpty ? "" : "\n" + failed.prefix(5).joined(separator: "\n"))
                if !added.isEmpty { self.scheduleSave(); self.requestRender() }
            }
        }
    }

    func exportTargets(for scope: ExportScope) -> [PhotoAsset] {
        switch scope {
        case .current: selection.map { [$0] } ?? []
        case .selected: selectedPhotos
        case .visible: visiblePhotos
        }
    }

    func export(scope: ExportScope, maxPixel: Int?, quality: Double, directory: URL,
                prepared: PreparedJPEGExport? = nil) {
        guard !isExporting, catalogLoaded, loadError == nil else { return }
        let targets = exportTargets(for: scope)
        guard !targets.isEmpty else { return }
        isExporting = true
        operationProgress = 0
        exportReport = nil
        batchQueue.async { [pipeline] in
            var successes = 0
            var failures: [String] = []
            for (index, photo) in targets.enumerated() {
                do {
                    if let prepared, prepared.photoID == photo.id, prepared.edits == photo.edits,
                       prepared.maxPixel == maxPixel, prepared.quality == quality {
                        _ = try pipeline.writeJPEG(prepared.result.data, sourceURL: photo.url, to: directory)
                    } else {
                        _ = try pipeline.exportJPEG(url: photo.url, edits: photo.edits, to: directory,
                                                    maxPixel: maxPixel, quality: quality)
                    }
                    successes += 1
                }
                catch { failures.append("\(photo.filename): \(error.localizedDescription)") }
                let progress = Double(index + 1) / Double(targets.count)
                DispatchQueue.main.async { self.operationProgress = progress }
            }
            DispatchQueue.main.async {
                self.isExporting = false
                self.exportReport = "\(successes)장 내보냄 · 실패 \(failures.count)장" + (failures.isEmpty ? "" : "\n" + failures.prefix(8).joined(separator: "\n"))
            }
        }
    }
}
