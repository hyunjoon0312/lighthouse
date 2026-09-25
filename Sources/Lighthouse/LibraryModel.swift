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
    case all, picks, rejects, edited, bursts, folder(String), collection(UUID)
}

/// 촬영 시각으로 묶은 연속 촬영과 사진마다의 위치(몇 번째 묶음의 몇 번째 컷).
struct BurstIndex {
    var groups: [BurstGroup] = []
    var positions: [UUID: (group: Int, shot: Int)] = [:]
}

private struct MaskRequestKey: Equatable {
    let photoID: UUID
    let definition: LocalMaskDefinition
    let rotationQuarterTurns: Int
    let straightenDegrees: Double
    let cropRect: NormalizedCrop?
    let cropAspect: Double?
}

struct BurstBadge: Equatable {
    var shot: Int
    var count: Int
    /// nil이면 아직 분석하지 않았다.
    var isBest: Bool?
}

struct PresetSheetRequest: Identifiable {
    enum Kind { case save, rename(UUID) }
    let id = UUID()
    let kind: Kind
    let initialName: String
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
    let options: ExportOptions
    let result: JPEGPreview

    /// 파일 이름 규칙은 데이터에 영향이 없으므로 비교하지 않는다.
    func matches(_ photo: PhotoAsset, _ other: ExportOptions) -> Bool {
        var mine = options, theirs = other
        mine.filenameTemplate = ""
        theirs.filenameTemplate = ""
        return photoID == photo.id && edits == photo.edits && mine == theirs
    }
}

/// 포인터를 움직일 때마다 바뀌는 브러시 상태. 작업 공간 전체가 아니라 캔버스만 다시 그리도록 분리한다.
@MainActor
final class CanvasStrokeState: ObservableObject {
    @Published var draftPoints: [MaskPoint] = []
    @Published var brushCursor: MaskPoint?
    @Published var retouchDraftPoints: [MaskPoint] = []
    @Published var retouchCursor: MaskPoint?
}

private final class ThumbnailEntry: NSObject {
    let image: NSImage
    let edits: EditSettings?

    init(image: NSImage, edits: EditSettings?) {
        self.image = image
        self.edits = edits
    }
}

struct LibraryCounts {
    var total = 0
    var picks = 0
    var rejects = 0
    var edited = 0
    var bursts = 0
    /// 내 폴더별로 목록에 보이는 사진 수.
    var folders: [UUID: Int] = [:]
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var photos: [PhotoAsset] = [] { didSet { invalidateLibraryCaches() } }
    @Published var photoSelection = PhotoSelectionState()
    @Published var photoFolders: [PhotoFolder] = [] { didSet { visibleCache = nil; countsCache = nil } }
    @Published var foldersLoaded = false
    @Published var folderLoadError: String?
    @Published var folderSheetRequest: PhotoFolderSheetRequest?
    @Published var filter: LibraryFilter = .all { didSet { visibleCache = nil } }
    @Published var search = "" { didSet { visibleCache = nil } }
    @Published var minimumRating = 0 { didSet { visibleCache = nil } }
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
    @Published var isCancellingExport = false
    @Published var showExport = false
    @Published var showBatchEdit = false
    @Published var showCardImport = false
    @Published var presets: [EditPreset] = []
    @Published var presetLoadError: String?
    @Published var presetSheet: PresetSheetRequest?
    @Published var importPresetID: UUID? = UserDefaults.standard.string(forKey: "importPresetID").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(importPresetID?.uuidString, forKey: "importPresetID") }
    }
    @Published var isCancellingImport = false
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
    @Published var isAutoMasking = false
    @Published var autoMaskError: String?
    @Published var retouchMode: RetouchMode = .heal
    @Published var retouchRadius = 0.02
    @Published var isPickingCloneSource = false
    @Published var cloneSource: MaskPoint?
    @Published var isFindingHealSource = false
    @Published var retouchError: String?
    @Published var rawCapabilities: RAWCapabilities?
    @Published var histogram: ImageHistogram?
    @Published var showsClipping = false { didSet { refreshClippingOverlay() } }
    @Published var clippingOverlay: NSImage?
    @Published var zoomAnchor = CGPoint(x: 0.5, y: 0.5)
    /// 비교 모드의 기준 사진을 보정한 모습으로 보인다. 끄면 보정 전 원본이다.
    @Published var compareShowsPinnedEdits = UserDefaults.standard.object(forKey: "comparePinnedEdits") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(compareShowsPinnedEdits, forKey: "comparePinnedEdits")
            requestRender()
        }
    }
    /// RAW+JPEG로 찍은 사진은 RAW만 보인다. JPEG는 카탈로그에 남고 끄면 다시 보인다.
    @Published var collapsesRAWJPEGPairs = UserDefaults.standard.object(forKey: "collapseRAWJPEGPairs") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(collapsesRAWJPEGPairs, forKey: "collapseRAWJPEGPairs")
            visibleCache = nil
            countsCache = nil
            ensureSelectionVisible()
        }
    }
    @Published var autoAdvance = UserDefaults.standard.bool(forKey: "autoAdvanceAfterMark") {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: "autoAdvanceAfterMark") }
    }
    let canvas = CanvasStrokeState()
    var gridColumnCount = 1

    var draftPoints: [MaskPoint] {
        get { canvas.draftPoints }
        set { canvas.draftPoints = newValue }
    }
    var brushCursor: MaskPoint? {
        get { canvas.brushCursor }
        set { canvas.brushCursor = newValue }
    }
    var retouchDraftPoints: [MaskPoint] {
        get { canvas.retouchDraftPoints }
        set { canvas.retouchDraftPoints = newValue }
    }
    var retouchCursor: MaskPoint? {
        get { canvas.retouchCursor }
        set { canvas.retouchCursor = newValue }
    }

    private let pipeline = ImagePipeline()
    private let previewPipeline = ImagePipeline(cachesDevelopment: true)
    private let thumbnailStore = ThumbnailStore()
    private let lutStore = LUTStore()
    private let catalog = CatalogStore(url: CatalogStore.defaultURL)
    private let folderStore = PhotoFolderStore(url: PhotoFolderStore.defaultURL)
    private let presetStore = EditPresetStore(url: EditPresetStore.defaultURL)
    private let backup = CatalogBackup(directory: CatalogBackup.defaultDirectory)
    private var backupFailureReported = false
    private let previewQueue = DispatchQueue(label: "com.rian.lighthouse.preview", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "com.rian.lighthouse.thumbnails", qos: .utility)
    private let placeholderQueue = DispatchQueue(label: "com.rian.lighthouse.placeholder", qos: .userInitiated)
    private let prefetchQueue = DispatchQueue(label: "com.rian.lighthouse.prefetch", qos: .utility)
    private let batchQueue = DispatchQueue(label: "com.rian.lighthouse.batch", qos: .userInitiated)
    private let maskQueue = DispatchQueue(label: "com.rian.lighthouse.mask", qos: .userInitiated)
    private let autoMaskQueue = DispatchQueue(label: "com.rian.lighthouse.automask", qos: .userInitiated)
    private let lutQueue = DispatchQueue(label: "com.rian.lighthouse.lut", qos: .userInitiated)
    private let retouchQueue = DispatchQueue(label: "com.rian.lighthouse.retouch", qos: .userInitiated)
    private let saveQueue = DispatchQueue(label: "com.rian.lighthouse.catalog", qos: .utility)
    private var saveDelay: DispatchWorkItem?
    private var renderDelay: DispatchWorkItem?
    private var generation = 0
    private var renderedSource: String?
    private var pinnedSource: String?
    private var pinnedRenderedEdits: EditSettings?
    private var retouchGeneration = 0
    private var renderJob: DispatchWorkItem?
    private var displayedToken = 0
    /// 슬라이더를 끄는 동안에는 RAW 노출·색온도·틴트를 근사로 그린다. 끝나면 정확히 다시 그린다.
    private var editDragActive = false
    private var showingApproximation = false
    private var requestedApproximation = false
    private var exactRenderFollowUp: DispatchWorkItem?
    private var lastRenderDispatch = Date.distantPast
    private var recentRenders: [(key: String, edits: EditSettings, image: NSImage, histogram: ImageHistogram?)] = []
    private var overlayToken = 0
    private var prefetching = Set<String>()
    private var moveDirection = 1
    private var pendingCollapse: DispatchWorkItem?
    private var exportCancellation: CancellationFlag?
    private var importCancellation: CancellationFlag?
    private var visibleCache: [PhotoAsset]?
    private var indexCache: [UUID: Int]?
    private var countsCache: LibraryCounts?
    private var foldersCache: [String]?
    private var burstCache: (signature: Int, index: BurstIndex)?
    /// 사진 목록의 ID·경로·촬영 정보만 본 서명. 보정·별점만 바뀌면 같아서 묶음·짝 계산을 다시 하지 않는다.
    private var structureSignatureCache: Int?
    private var pairCache: (signature: Int, companions: [UUID: [UUID]], pairedRAWs: Set<UUID>)?
    private var burstRecommendationCache: [UUID: BurstRecommendation]?
    private var burstCancellation: CancellationFlag?
    private let burstQueue = DispatchQueue(label: "com.rian.lighthouse.burst", qos: .utility)
    /// 이번 실행에서 분석한 원본 품질. 앱을 다시 열면 다시 분석한다.
    @Published private(set) var burstQualities: [UUID: PhotoQuality] = [:] { didSet { burstRecommendationCache = nil } }
    /// 분석하려 했지만 읽지 못한 파일. 이 컷은 추천에서 빼고 표시도 바꾸지 않는다.
    @Published private(set) var burstFailedIDs = Set<UUID>() { didSet { burstRecommendationCache = nil } }
    @Published private(set) var isAnalyzingBursts = false
    @Published private(set) var burstAnalysisProgress = 0.0
    @Published var burstMessage: String?
    /// 삭제를 확인받는 중인 가상 사본.
    @Published var copyDeletionRequest: [PhotoAsset]?
    private var rawCapabilitiesPath: String?
    private var rawCapabilitiesByPath: [String: RAWCapabilities?] = [:]
    private static let renderInterval = 0.1
    private static let recentRenderLimit = 6
    private var maskGeneration = 0
    private var selectionGeneration = 0
    private var autoMaskGeneration = 0
    private var lutLibraryGeneration = 0
    private var maskSource: String?
    /// 화면의 마스크가 어떤 모양·구도로 그려졌는지. 같으면 효과 값만 바뀐 것이므로 다시 그리지 않는다.
    private var displayedMaskKey: MaskRequestKey?
    /// 마스크는 한 번에 하나만 그리고, 그리는 동안 들어온 요청은 가장 마지막 것만 남긴다.
    private var maskInFlight = false
    private var pendingMaskJob: (() -> Void)?
    private var draftPhotoID: UUID?
    private var draftLocalID: UUID?
    private var started = false
    private var editHistory = EditHistory(limit: 100)
    private let thumbnailCache = NSCache<NSString, ThumbnailEntry>()
    private var loadingThumbnails = Set<String>()
    private static let thumbnailPixels = 360
    private static let pasteComponents: EditComponents = [.global, .lut]

    init() {
        thumbnailCache.countLimit = 240
        thumbnailCache.totalCostLimit = 200 * 1024 * 1024
    }

    var selectedID: UUID? { photoSelection.activeID }
    var selectedPhotoIDs: Set<UUID> { photoSelection.selectedIDs }
    var selectedPhotos: [PhotoAsset] { visiblePhotos.filter { selectedPhotoIDs.contains($0.id) } }
    var selection: PhotoAsset? { selectedID.flatMap(photo(withID:)) }
    var pinned: PhotoAsset? { photos.first { $0.id == pinnedID } }
    var canUndo: Bool { editHistory.canUndo }
    var canRedo: Bool { editHistory.canRedo }
    var hasModalPresentation: Bool {
        showBatchEdit || showExport || showCardImport || presetSheet != nil || referenceMatchSource != nil || folderSheetRequest != nil ||
            cropSource != nil || copyDeletionRequest != nil
    }
    var selectedLocal: LocalAdjustment? { selection?.edits.localAdjustments.first { $0.id == selectedLocalID } }
    var canDrawLocal: Bool {
        adjustmentPanel == .local && isLocalEditing && selectedLocal != nil &&
        mode == .edit && !isOriginal && !actualSize && !rendering && rendered != nil && imageError == nil
    }
    /// 그라데이션 조절점은 그리기 모드가 아닐 때 드래그한다. 드래그 중 렌더링이 이어져도 조절점을 유지한다.
    var canEditGradient: Bool {
        adjustmentPanel == .local && !isLocalEditing && selectedLocal?.gradient != nil &&
        mode == .edit && !isOriginal && !actualSize && rendered != nil && imageError == nil
    }
    var canUseRetouchCanvas: Bool {
        adjustmentPanel == .retouch && mode == .edit && !isOriginal && !actualSize &&
        !rendering && rendered != nil && imageError == nil
    }
    var canDrawRetouch: Bool {
        canUseRetouchCanvas && !isPickingCloneSource && !isFindingHealSource &&
        (retouchMode == .heal || cloneSource != nil)
    }

    var folders: [String] {
        if let foldersCache { return foldersCache }
        let computed = Array(Set(photos.map { ($0.path as NSString).deletingLastPathComponent })).sorted()
        foldersCache = computed
        return computed
    }

    /// 화면을 다시 그릴 때마다 여러 번 읽히므로 사진 목록이 바뀔 때만 다시 계산한다.
    var counts: LibraryCounts {
        if let countsCache { return countsCache }
        var computed = LibraryCounts()
        // 사진마다 속한 목록(전체·선택·제외·보정·연속 촬영)을 비트로 한 번만 구한다. JPEG 짝은 RAW와 같은 목록에서 뺀다.
        let companions = activeCompanions
        let positions = burstIndex.positions
        var masks = [UUID: UInt8](minimumCapacity: photos.count)
        for photo in photos {
            masks[photo.id] = 1 | (photo.flag == .pick ? 2 : 0) | (photo.flag == .reject ? 4 : 0) |
                (photo.edits.isModified ? 8 : 0) | (positions[photo.id] != nil ? 16 : 0)
        }
        for photo in photos {
            var mask = masks[photo.id] ?? 0
            for raw in companions[photo.id] ?? [] { mask &= ~(masks[raw] ?? 0) }
            if mask & 1 != 0 { computed.total += 1 }
            if mask & 2 != 0 { computed.picks += 1 }
            if mask & 4 != 0 { computed.rejects += 1 }
            if mask & 8 != 0 { computed.edited += 1 }
            if mask & 16 != 0 { computed.bursts += 1 }
        }
        for folder in photoFolders {
            let members = folder.photoIDs
            computed.folders[folder.id] = members.filter { id in
                masks[id] != nil && !(companions[id]?.contains(where: members.contains) ?? false)
            }.count
        }
        countsCache = computed
        return computed
    }

    func photo(withID id: UUID) -> PhotoAsset? {
        if indexCache == nil {
            indexCache = Dictionary(photos.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return indexCache?[id].map { photos[$0] }
    }

    private func invalidateLibraryCaches() {
        visibleCache = nil
        indexCache = nil
        countsCache = nil
        foldersCache = nil
        structureSignatureCache = nil
    }

    private var structureSignature: Int {
        if let structureSignatureCache { return structureSignatureCache }
        var hasher = Hasher()
        for photo in photos {
            hasher.combine(photo.id)
            hasher.combine(photo.path)
            hasher.combine(photo.metadata.capturedAt)
            hasher.combine(photo.metadata.camera)
            hasher.combine(photo.copyName)
        }
        let signature = hasher.finalize()
        structureSignatureCache = signature
        return signature
    }

    /// RAW와 함께 찍힌 JPEG. 한 장으로 보기를 켜면 목록·개수에서 뺀다.
    private var pairs: (companions: [UUID: [UUID]], pairedRAWs: Set<UUID>) {
        let signature = structureSignature
        if let pairCache, pairCache.signature == signature { return (pairCache.companions, pairCache.pairedRAWs) }
        let companions = RAWJPEGPairs.companions(in: photos)
        let raws = Set(companions.values.flatMap { $0 })
        pairCache = (signature, companions, raws)
        return (companions, raws)
    }

    /// `matches`에 드는 사진 중 같은 이름의 RAW도 `matches`에 드는 JPEG 짝을 뺀다.
    /// RAW가 없는 폴더·필터에서는 JPEG를 그대로 보인다.
    private func collapsedFilter(_ matches: (PhotoAsset) -> Bool) -> [PhotoAsset] {
        let companions = activeCompanions
        return photos.filter { matches($0) && !isHiddenCompanion($0, companions, matches) }
    }

    private var activeCompanions: [UUID: [UUID]] { collapsesRAWJPEGPairs ? pairs.companions : [:] }

    private func isHiddenCompanion(_ photo: PhotoAsset, _ companions: [UUID: [UUID]],
                                   _ matches: (PhotoAsset) -> Bool) -> Bool {
        guard let raws = companions[photo.id] else { return false }
        return raws.contains { id in self.photo(withID: id).map(matches) ?? false }
    }

    /// 한 장으로 보기에서 JPEG 짝을 숨긴 RAW인지.
    func hidesCompanion(of photo: PhotoAsset) -> Bool {
        collapsesRAWJPEGPairs && pairs.pairedRAWs.contains(photo.id)
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
        if let visibleCache { return visibleCache }
        var members: Set<UUID>?
        if case .collection(let id) = filter {
            members = photoFolders.first(where: { $0.id == id })?.photoIDs ?? []
        }
        let search = search, filter = filter, minimumRating = minimumRating
        let positions = filter == .bursts ? burstIndex.positions : [:]
        let computed = collapsedFilter { photo in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .picks: matchesFilter = photo.flag == .pick
            case .rejects: matchesFilter = photo.flag == .reject
            case .edited: matchesFilter = photo.edits.isModified
            case .bursts: matchesFilter = positions[photo.id] != nil
            case .folder(let path): matchesFilter = (photo.path as NSString).deletingLastPathComponent == path
            case .collection: matchesFilter = members?.contains(photo.id) ?? false
            }
            return matchesFilter && photo.rating >= minimumRating &&
                (search.isEmpty || photo.displayName.localizedCaseInsensitiveContains(search))
        }
        visibleCache = computed
        return computed
    }

    func start() {
        guard !started else { return }
        started = true
        batchQueue.async { [catalog, folderStore, presetStore] in
            let result = Result { try catalog.load() }
            let folders = Result { try folderStore.load() }
            let presets = Result { try presetStore.load() }
            DispatchQueue.main.async {
                switch result {
                case .success(let photos):
                    self.photos = photos
                    self.catalogLoaded = true
                    switch folders {
                    case .success(let loaded): self.photoFolders = loaded; self.foldersLoaded = true
                    case .failure(let error): self.folderLoadError = error.localizedDescription
                    }
                    switch presets {
                    case .success(let loaded):
                        self.presets = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    case .failure(let error): self.presetLoadError = error.localizedDescription
                    }
                    if let first = photos.first {
                        self.photoSelection.select(first.id, in: photos.map(\.id))
                    }
                    // 오늘 처음 연 상태를 남긴다. 이날 작업을 되돌리고 싶을 때 쓸 수 있다.
                    self.saveQueue.async { self.backUpIfNeeded(photos) }
                    self.refreshLUTLibrary()
                    self.requestRender()
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "--import"), arguments.indices.contains(index + 1) {
                        self.importURLs([URL(fileURLWithPath: arguments[index + 1])])
                    }
                case .failure(let error):
                    self.loadError = """
                        카탈로그를 열 수 없습니다. 파일을 확인한 뒤 앱을 다시 실행하세요.
                        \(error.localizedDescription)

                        날짜별 보관본이 \(self.backup.directory.path)에 있습니다(파일 메뉴 › 카탈로그 보관본 보기). \
                        앱을 끝낸 뒤 원하는 날짜 폴더의 파일을 \(self.catalog.url.deletingLastPathComponent().path)에 \
                        덮어 두면 그날 처음 연 상태로 돌아갑니다.
                        """
                }
            }
        }
    }

    func select(_ photo: PhotoAsset) {
        let previous = selectedID
        photoSelection.select(photo.id, in: visiblePhotos.map(\.id))
        selectionDidChange(previousActive: previous)
    }

    /// 한 번 클릭은 바로 선택한다. 여러 장 선택 중 이미 선택된 사진을 누른 경우만
    /// 더블클릭(그룹을 유지한 채 열기)일 수 있어 더블클릭 판정 시간 뒤에 단일 선택으로 바꾼다.
    func handleTileClick(_ photo: PhotoAsset, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        pendingCollapse?.cancel()
        pendingCollapse = nil
        if clickCount >= 2 {
            focusPhoto(photo)
            setMode(.edit)
            return
        }
        let mode: PhotoSelectionMode = modifiers.contains(.shift) ? .range
            : modifiers.contains(.command) ? .toggle : .single
        if mode == .single, selectedPhotoIDs.count > 1, selectedPhotoIDs.contains(photo.id) {
            let group = selectedPhotoIDs
            let collapse = DispatchWorkItem { [weak self] in
                guard let self, self.selectedPhotoIDs == group else { return }
                self.select(photo)
            }
            pendingCollapse = collapse
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: collapse)
            return
        }
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
        editDragActive = false
        cancelAutoMask()
        cancelRetouchDraft(clearSource: true)
        retouchError = nil
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
        if direction != 0 { moveDirection = direction > 0 ? 1 : -1 }
        focusPhoto(visible[next])
    }

    func setMode(_ newMode: WorkspaceMode) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if newMode != .edit { cancelDraft(); cancelRetouchDraft(); isLocalEditing = false }
        if newMode == .compare && mode != .compare {
            pinnedID = selectedID
            pinnedImage = nil
            pinnedError = nil
            pinnedSource = nil
            pinnedRenderedEdits = nil
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
    /// `anchor`는 화면 맞춤 사진에서 클릭한 위치(0…1). 100%로 들어갈 때 그 위치를 가운데에 둔다.
    func toggleActualSize(at anchor: CGPoint? = nil) {
        cancelDraft()
        cancelRetouchDraft()
        if !actualSize { zoomAnchor = anchor ?? CGPoint(x: 0.5, y: 0.5) }
        actualSize.toggle()
        if actualSize { isLocalEditing = false }
        requestRender()
    }

    func updatePhoto(_ id: UUID, _ change: (inout PhotoAsset) -> Void, debounce: Bool = false) {
        guard catalogLoaded, loadError == nil, let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let editsBefore = photos[index].edits
        change(&photos[index])
        let editsChanged = photos[index].edits != editsBefore
        scheduleSave(debounce: debounce)
        if editsChanged && selectedID == id { reconcileLocalSelection() }
        let previousSelection = selectedID
        ensureSelectionVisible()
        if editsChanged && previousSelection == selectedID && (selectedID == id || pinnedID == id) {
            requestRender(debounce: debounce)
        }
    }

    /// `continuous`는 슬라이더 드래그처럼 이어지는 변경이다. `endContinuousEdit()`까지 한 실행 취소 단계로 묶는다.
    func updateEdits(_ edits: EditSettings, continuous: Bool = false) {
        guard let selected = selection, selected.edits != edits else { return }
        applyEditChanges([PhotoEditChange(id: selected.id, before: selected.edits, after: edits)],
                         useAfter: true, record: true, continuous: continuous, debounce: true)
    }

    func endContinuousEdit() {
        editHistory.commitContinuous()
        editDragActive = false
        // 근사로 그리는 중이던 결과가 아직 도착하지 않았어도 정확한 렌더를 바로 시작한다.
        if showingApproximation || (rendering && requestedApproximation) { requestRender() }
        objectWillChange.send()
    }

    func undo() {
        cancelDraft()
        cancelRetouchDraft()
        guard let step = editHistory.undo() else { return }
        apply(step, useAfter: false)
    }

    func redo() {
        cancelDraft()
        cancelRetouchDraft()
        guard let step = editHistory.redo() else { return }
        apply(step, useAfter: true)
    }

    private func apply(_ step: HistoryStep, useAfter: Bool) {
        switch step {
        case .edits(let changes):
            applyEditChanges(changes, useAfter: useAfter, record: false)
        case .marks(let changes):
            for change in changes { applyMarks(useAfter ? change.after : change.before, to: change.id) }
            objectWillChange.send()
        }
    }

    private func applyEditChanges(_ changes: [PhotoEditChange], useAfter: Bool,
                                  record: Bool, continuous: Bool = false, debounce: Bool = false) {
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
        if record {
            if continuous, actual.count == 1 { editHistory.recordContinuous(actual[0]) }
            else { editHistory.record(actual) }
            editDragActive = continuous
        }
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
        changeMarks(of: id) { $0.rating = rating }
    }

    func setFlag(_ flag: PhotoFlag) {
        guard let id = selectedID else { return }
        changeMarks(of: id) { $0.flag = flag }
    }

    /// 키보드로 별점·표시를 바꾼다. 자동 다음 사진이 켜져 있으면 바꾸기 전에 정한 다음 사진으로 넘어가므로
    /// 필터 때문에 방금 표시한 사진이 목록에서 빠져도 한 장을 건너뛰지 않는다.
    func markFromKeyboard(rating: Int? = nil, flag: PhotoFlag? = nil) {
        guard let id = selectedID else { return }
        let visible = visiblePhotos
        let next = autoAdvance ? visible.firstIndex(where: { $0.id == id }).flatMap { index in
            visible.indices.contains(index + 1) ? visible[index + 1].id : nil
        } : nil
        changeMarks(of: id) { marks in
            if let rating { marks.rating = rating }
            if let flag { marks.flag = flag }
        }
        if let next, let photo = visiblePhotos.first(where: { $0.id == next }) {
            moveDirection = 1
            focusPhoto(photo)
        }
    }

    private func changeMarks(of id: UUID, _ change: (inout PhotoMarks) -> Void) {
        guard catalogLoaded, loadError == nil, let photo = photo(withID: id) else { return }
        let before = PhotoMarks(rating: photo.rating, flag: photo.flag)
        var after = before
        change(&after)
        guard after != before else { return }
        editHistory.recordMarks([PhotoMarkChange(id: id, before: before, after: after)])
        applyMarks(after, to: id)
    }

    private func applyMarks(_ marks: PhotoMarks, to id: UUID) {
        updatePhoto(id) {
            $0.rating = marks.rating
            $0.flag = marks.flag
        }
    }

    // MARK: 연속 촬영

    /// 보정·별점만 바뀐 경우는 다시 묶지 않는다. 사진 5000장에서 묶기는 약 25ms, 이 비교는 약 1ms다.
    var burstIndex: BurstIndex {
        let signature = structureSignature
        if let burstCache, burstCache.signature == signature { return burstCache.index }
        var index = BurstIndex(groups: BurstGrouping.groups(for: photos))
        for (groupIndex, group) in index.groups.enumerated() {
            for (shotIndex, shot) in group.shots.enumerated() {
                for id in shot { index.positions[id] = (groupIndex, shotIndex) }
            }
        }
        burstCache = (signature, index)
        burstRecommendationCache = nil
        return index
    }

    /// 모든 컷을 분석했거나 읽지 못한 묶음만 추천한다. 분석을 중간에 멈춘 묶음은 일부 컷만 보고 고르지 않는다.
    var burstRecommendations: [UUID: BurstRecommendation] {
        if let burstRecommendationCache { return burstRecommendationCache }
        var computed: [UUID: BurstRecommendation] = [:]
        if !burstQualities.isEmpty {
            for group in burstIndex.groups where isBurstAnalyzed(group) {
                if let recommendation = BurstRanking.recommend(group, qualities: burstQualities) {
                    computed[group.id] = recommendation
                }
            }
        }
        burstRecommendationCache = computed
        return computed
    }

    private func isBurstAnalyzed(_ group: BurstGroup) -> Bool {
        group.shots.allSatisfy { shot in
            shot.contains { burstQualities[$0] != nil || burstFailedIDs.contains($0) }
        }
    }

    func burstBadge(for photo: PhotoAsset) -> BurstBadge? {
        guard let position = burstIndex.positions[photo.id] else { return nil }
        let group = burstIndex.groups[position.group]
        let recommendation = burstRecommendations[group.id]
        return BurstBadge(shot: position.shot + 1, count: group.shots.count,
                          isBest: recommendation.map { $0.bestShot == position.shot })
    }

    /// 지금 목록에 한 장이라도 보이는 묶음.
    private var visibleBurstGroups: [BurstGroup] {
        let visible = Set(visiblePhotos.map(\.id))
        return burstIndex.groups.filter { $0.photoIDs.contains(where: visible.contains) }
    }

    /// 보이는 묶음의 컷마다 원본 미리보기 한 장(RAW+JPEG이면 RAW)을 기기 안에서 분석한다.
    /// 선명도와 Vision 얼굴 촬영 품질만 계산하며 원본·표시·보정은 바꾸지 않는다.
    func analyzeBursts() {
        guard catalogLoaded, loadError == nil, !isAnalyzingBursts else { return }
        let groups = visibleBurstGroups
        guard !groups.isEmpty else { burstMessage = "지금 목록에 연속 촬영 묶음이 없습니다."; return }
        let targets: [(id: UUID, url: URL)] = groups.flatMap(\.shots).compactMap { shot in
            guard !shot.contains(where: { burstQualities[$0] != nil }) else { return nil }
            let members = shot.compactMap { photo(withID: $0) }
            guard let chosen = members.first(where: \.isRAW) ?? members.first else { return nil }
            return (chosen.id, chosen.url)
        }
        guard !targets.isEmpty else { burstMessage = burstSummary(groups, failed: 0, cancelled: false); return }
        isAnalyzingBursts = true
        burstAnalysisProgress = 0
        burstMessage = "연속 촬영 \(groups.count)묶음 분석 중…"
        let cancellation = CancellationFlag()
        burstCancellation = cancellation
        burstQueue.async { [pipeline] in
            var failed = 0
            var cancelled = false
            for (index, target) in targets.enumerated() {
                if cancellation.isCancelled { cancelled = true; break }
                let quality = try? PhotoQualityAnalyzer.analyze(url: target.url, pipeline: pipeline)
                if quality == nil { failed += 1 }
                let progress = Double(index + 1) / Double(targets.count)
                DispatchQueue.main.async {
                    guard self.burstCancellation === cancellation else { return }
                    if let quality {
                        self.burstQualities[target.id] = quality
                        self.burstFailedIDs.remove(target.id)
                    } else {
                        self.burstFailedIDs.insert(target.id)
                    }
                    self.burstAnalysisProgress = progress
                }
            }
            DispatchQueue.main.async {
                guard self.burstCancellation === cancellation else { return }
                self.burstCancellation = nil
                self.isAnalyzingBursts = false
                self.burstMessage = self.burstSummary(groups, failed: failed, cancelled: cancelled)
            }
        }
    }

    /// 지금 분석 중인 한 장은 끝까지 하고 나머지를 건너뛴다. 이미 분석한 결과는 남긴다.
    func cancelBurstAnalysis() {
        burstCancellation?.cancel()
    }

    private func burstSummary(_ groups: [BurstGroup], failed: Int, cancelled: Bool) -> String {
        let recommendations = burstRecommendations
        let analyzed = groups.filter { recommendations[$0.id] != nil }
        let unfinished = groups.filter { !isBurstAnalyzed($0) }.count
        let faceGroups = analyzed.filter { recommendations[$0.id]?.usedFaces == true }.count
        let noFaceModel = groups.flatMap(\.photoIDs).contains { burstQualities[$0].map { $0.faceQualities == nil } ?? false }
        return "연속 촬영 \(groups.count)묶음 중 \(analyzed.count)묶음 추천 완료" +
            (unfinished > 0 ? " · 분석이 끝나지 않은 \(unfinished)묶음은 추천하지 않음" : "") +
            (faceGroups > 0 ? " · 얼굴 반영 \(faceGroups)묶음" : "") +
            (failed > 0 ? " · 읽지 못한 컷 \(failed)장은 표시하지 않음" : "") +
            (noFaceModel ? " · 얼굴 분석을 쓸 수 없어 선명도만 반영한 컷이 있음" : "") +
            (cancelled ? " · 중지함" : "")
    }

    /// 보이는 묶음의 추천 컷만 선택한다. RAW+JPEG이면 두 파일을 함께 선택한다.
    func selectBurstRecommendations() {
        let recommendations = burstRecommendations
        var picks = Set<UUID>()
        for group in visibleBurstGroups {
            guard let recommendation = recommendations[group.id] else { continue }
            picks.formUnion(group.shots[recommendation.bestShot])
        }
        let ordered = visiblePhotos.map(\.id).filter(picks.contains)
        guard !ordered.isEmpty else { burstMessage = "먼저 연속 촬영을 분석하세요."; return }
        let previous = selectedID
        photoSelection.selectAll(in: ordered)
        selectionDidChange(previousActive: previous)
        burstMessage = "추천 컷 \(ordered.count)장을 선택했습니다."
    }

    /// 분석한 묶음에서 추천 컷은 선택(P), 나머지는 제외(X)로 표시한다. 이미 표시한 사진은 그대로 둔다.
    /// 한 번에 실행 취소된다.
    func markBurstRecommendations() {
        guard catalogLoaded, loadError == nil else { return }
        let recommendations = burstRecommendations
        let visible = Set(visiblePhotos.map(\.id))
        var changes: [PhotoMarkChange] = []
        for group in visibleBurstGroups {
            guard let recommendation = recommendations[group.id] else { continue }
            for (shotIndex, shot) in group.shots.enumerated() where recommendation.scores[shotIndex] != nil {
                for id in shot where visible.contains(id) {
                    guard let photo = photo(withID: id), photo.flag == .none else { continue }
                    let before = PhotoMarks(rating: photo.rating, flag: photo.flag)
                    var after = before
                    after.flag = shotIndex == recommendation.bestShot ? .pick : .reject
                    changes.append(PhotoMarkChange(id: id, before: before, after: after))
                }
            }
        }
        let unfinished = visibleBurstGroups.filter { !isBurstAnalyzed($0) }.count
        let skipped = unfinished > 0 ? " 분석이 끝나지 않은 \(unfinished)묶음은 건너뛰었습니다. ‘베스트 컷 분석’을 다시 누르면 남은 컷만 분석합니다." : ""
        guard !changes.isEmpty else {
            burstMessage = (recommendations.isEmpty && unfinished == 0 ? "먼저 연속 촬영을 분석하세요." :
                            recommendations.isEmpty ? "추천할 수 있는 묶음이 없습니다." :
                            "새로 표시할 사진이 없습니다. 이미 표시한 사진은 바꾸지 않습니다.") + skipped
            return
        }
        editHistory.recordMarks(changes)
        let flags = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0.after.flag) })
        var updated = photos
        for index in updated.indices { if let flag = flags[updated[index].id] { updated[index].flag = flag } }
        photos = updated
        scheduleSave()
        ensureSelectionVisible()
        let picks = changes.filter { $0.after.flag == .pick }.count
        burstMessage = "추천 \(picks)장 선택 · \(changes.count - picks)장 제외로 표시했습니다. ⌘Z로 되돌릴 수 있습니다." + skipped
    }

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

    /// 선택한 사진 중 가상 사본만 카탈로그에서 뺀다. 원본 파일과 원래 항목은 그대로다. 실행 취소할 수 없다.
    var selectedVirtualCopies: [PhotoAsset] {
        let targets = selectedPhotos.isEmpty ? selection.map { [$0] } ?? [] : selectedPhotos
        return targets.filter(\.isVirtualCopy)
    }

    func requestDeleteVirtualCopies() {
        let copies = selectedVirtualCopies
        guard !copies.isEmpty else { return }
        copyDeletionRequest = copies
    }

    func deleteVirtualCopies(_ ids: Set<UUID>) {
        guard catalogLoaded, loadError == nil else { return }
        let removed = photos.filter { ids.contains($0.id) && $0.isVirtualCopy }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        let fallbackPath = selection.flatMap { removedIDs.contains($0.id) ? $0.path : nil }
        photos.removeAll { removedIDs.contains($0.id) }
        if foldersLoaded, folderLoadError == nil {
            for index in photoFolders.indices { photoFolders[index].remove(removedIDs) }
        }
        for id in removedIDs {
            burstQualities[id] = nil
            burstFailedIDs.remove(id)
            thumbnailCache.removeObject(forKey: id.uuidString as NSString)
        }
        editHistory.removeChanges(for: removedIDs)
        thumbnailQueue.async { [thumbnailStore] in
            for id in removedIDs { thumbnailStore.remove(photoID: id) }
        }
        if pinnedID.map(removedIDs.contains) == true { pinnedID = nil }
        scheduleSave()
        ensureSelectionVisible()
        // 보고 있던 사본을 지우면 같은 파일의 남은 항목으로 옮긴다.
        if selectedID == nil, let fallbackPath, let sibling = visiblePhotos.first(where: { $0.path == fallbackPath }) {
            focusPhoto(sibling)
        }
        operationMessage = "가상 사본 \(removed.count)개를 지웠습니다. 원본 파일은 그대로입니다."
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

    func updateLUT(continuous: Bool = false, _ change: (inout LUTAdjustment) -> Void) {
        guard let current = selection, var lut = current.edits.lut else { return }
        var edits = current.edits
        change(&lut)
        edits.lut = lut
        updateEdits(edits, continuous: continuous)
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
        isLocalEditing = selectedLocal != nil && selectedLocal?.gradient == nil
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

    /// 그라데이션 영역은 조절점 모드로, 브러시 영역은 그리기 모드로 연다. `drawing`을 주면 그 모드로 연다.
    func chooseLocal(_ id: UUID, drawing: Bool? = nil) {
        enterLocalPanel()
        selectedLocalID = id
        isLocalEditing = drawing ?? (selectedLocal?.gradient == nil)
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

    /// 화면 기준 기본 위치에 그라데이션 영역을 만든다. 직선은 위쪽 하늘을 어둡게, 원형은 가운데를 밝게 시작한다.
    func addGradientLocal(radial: Bool) {
        guard let selected = selection, selected.metadata.width > 0, selected.metadata.height > 0 else { return }
        enterLocalPanel()
        let geometry = LocalMaskGeometry(sourceWidth: Double(selected.metadata.width),
                                         sourceHeight: Double(selected.metadata.height),
                                         edits: selected.edits)
        var edits = selected.edits
        let number = edits.localAdjustments.count + 1
        let adjustment: LocalAdjustment
        if radial {
            adjustment = LocalAdjustment(
                name: "원형 \(number)", exposure: 0.4, feather: 0,
                gradient: .radial(center: geometry.sourcePoint(fromDisplay: MaskPoint(x: 0.5, y: 0.5)),
                                  radiusX: 0.3, radiusY: 0.3, softness: 0.5))
        } else {
            adjustment = LocalAdjustment(
                name: "그라데이션 \(number)", exposure: -0.5, feather: 0,
                gradient: .linear(start: geometry.sourcePoint(fromDisplay: MaskPoint(x: 0.5, y: 0)),
                                  end: geometry.sourcePoint(fromDisplay: MaskPoint(x: 0.5, y: 0.45))))
        }
        edits.localAdjustments.append(adjustment)
        selectedLocalID = adjustment.id
        isLocalEditing = false
        updateEdits(edits)
    }

    /// 드래그 중인 조절점을 화면 좌표 `displayPoint`로 옮긴다. 드래그 한 번은 `endContinuousEdit()`에서 한 단계가 된다.
    func moveGradientHandle(_ handle: MaskGradientHandle, toDisplay displayPoint: MaskPoint) {
        guard canEditGradient, let photo = selection, photo.metadata.width > 0, photo.metadata.height > 0 else { return }
        let geometry = LocalMaskGeometry(sourceWidth: Double(photo.metadata.width),
                                         sourceHeight: Double(photo.metadata.height),
                                         edits: photo.edits)
        let point = geometry.sourcePoint(fromDisplay: displayPoint)
        updateLocal(continuous: true) { area in area.gradient = area.gradient?.moving(handle, to: point) }
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

    func updateLocal(continuous: Bool = false, _ change: (inout LocalAdjustment) -> Void) {
        guard let selected = selection,
              let index = selected.edits.localAdjustments.firstIndex(where: { $0.id == selectedLocalID }) else { return }
        var edits = selected.edits
        change(&edits.localAdjustments[index])
        updateEdits(edits, continuous: continuous)
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
    }

    /// 선택한 영역의 마스크 표시를 새로 그린다. 모양·구도가 그대로면 건너뛰고, 그리는 중에 들어온 요청은
    /// 마지막 것만 이어서 그려 조절점을 끄는 동안 작업이 쌓이지 않게 한다.
    func requestMask() {
        maskGeneration += 1
        let token = maskGeneration
        guard adjustmentPanel == .local, showsMask, mode == .edit, !isOriginal, !actualSize,
              let photo = selection, let adjustment = selectedLocal,
              photo.metadata.width > 0, photo.metadata.height > 0 else {
            maskImage = nil; maskError = nil; maskSource = nil; displayedMaskKey = nil; pendingMaskJob = nil; return
        }
        let source = "\(photo.id):\(adjustment.id):\(photo.edits.rotationQuarterTurns):\(photo.edits.straightenDegrees):\(String(describing: photo.edits.cropRect)): \(photo.edits.cropAspect ?? 0)"
        if source != maskSource { maskImage = nil; maskSource = source }
        let key = MaskRequestKey(photoID: photo.id, definition: adjustment.maskDefinition,
                                 rotationQuarterTurns: photo.edits.rotationQuarterTurns,
                                 straightenDegrees: photo.edits.straightenDegrees,
                                 cropRect: photo.edits.cropRect, cropAspect: photo.edits.cropAspect)
        if key == displayedMaskKey, maskImage != nil { pendingMaskJob = nil; return }
        let job = { [pipeline] in
            self.maskQueue.async {
                let result = Result {
                    try pipeline.renderMask(adjustment: adjustment,
                                            sourceWidth: photo.metadata.width,
                                            sourceHeight: photo.metadata.height,
                                            edits: photo.edits, maxPixel: 1600)
                }
                DispatchQueue.main.async {
                    self.maskInFlight = false
                    if token == self.maskGeneration {
                        switch result {
                        case .success(let cg):
                            self.maskError = nil
                            self.maskImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                            self.displayedMaskKey = key
                        case .failure(let error):
                            self.maskImage = nil
                            self.maskError = error.localizedDescription
                            self.displayedMaskKey = nil
                        }
                    }
                    if let next = self.pendingMaskJob {
                        self.pendingMaskJob = nil
                        self.maskInFlight = true
                        next()
                    }
                }
            }
        }
        if maskInFlight { pendingMaskJob = job } else { maskInFlight = true; job() }
    }

    func pasteToNext() {
        guard let clipboard else { return }
        move(1)
        guard let target = selection else { return }
        updateEdits(target.edits.merging(from: clipboard, components: Self.pasteComponents))
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
        retouchError = nil
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
        let stroke = RetouchStroke(mode: retouchMode, points: points,
                                   radius: retouchRadius, sourceOffset: offset)
        guard stroke.mode == .heal else {
            var edits = selected.edits
            edits.retouchStrokes.append(stroke)
            cancelRetouchDraft()
            updateEdits(edits)
            return
        }
        findHealSource(for: stroke, in: selected)
    }

    /// 패치 위치를 한 번 찾아 stroke에 저장한다. 찾는 동안 그린 경로는 화면에 남겨 둔다.
    private func findHealSource(for stroke: RetouchStroke, in photo: PhotoAsset) {
        retouchGeneration += 1
        let token = retouchGeneration
        let selectionToken = selectionGeneration
        isFindingHealSource = true
        let maxPixel: Int? = actualSize ? nil : 2200
        retouchQueue.async { [previewPipeline] in
            let result = Result {
                try previewPipeline.healingSourceOffset(url: photo.url, edits: photo.edits, stroke: stroke,
                                                        maxPixel: maxPixel)
            }
            DispatchQueue.main.async {
                guard token == self.retouchGeneration else { return }
                self.isFindingHealSource = false
                self.retouchDraftPoints = []
                guard self.selectedID == photo.id, self.selectionGeneration == selectionToken,
                      let current = self.selection, current.edits == photo.edits else {
                    self.retouchError = "사진이나 보정이 바뀌어 스팟 복구를 적용하지 않았습니다."
                    return
                }
                switch result {
                case .success(let offset):
                    var healed = stroke
                    healed.sourceOffset = offset
                    var edits = current.edits
                    edits.retouchStrokes.append(healed)
                    self.updateEdits(edits)
                case .failure(let error):
                    self.retouchError = error.localizedDescription
                }
            }
        }
    }

    func cancelRetouchDraft(clearSource: Bool = false) {
        retouchGeneration += 1
        isFindingHealSource = false
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
            // 앱을 켜 둔 채 날짜가 바뀌면 그날 첫 저장 때 보관본을 만든다.
            self.backUpIfNeeded(snapshot)
        }
    }

    /// `saveQueue`에서 부른다. 실패는 한 번만 알린다.
    nonisolated private func backUpIfNeeded(_ photos: [PhotoAsset]) {
        do {
            try backup.backUpIfNeeded(photos: photos, copying: [folderStore.url, presetStore.url])
        } catch {
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
        let snapshot = photos
        let folderSnapshot = photoFolders
        let canSaveFolders = foldersLoaded && folderLoadError == nil
        try saveQueue.sync {
            try catalog.save(snapshot)
            if canSaveFolders { try folderStore.save(folderSnapshot) }
        }
    }

    func thumbnail(for photo: PhotoAsset) -> NSImage? {
        thumbnailCache.object(forKey: photo.id.uuidString as NSString)?.image
    }

    /// 보정한 사진은 보정 결과로 썸네일을 만든다. 편집 화면의 사진은 미리보기 렌더가 썸네일을 갱신한다.
    /// 보정 썸네일은 디스크에도 보관해 다음 실행 때 RAW를 다시 현상하지 않는다.
    func requestThumbnail(for photo: PhotoAsset) {
        let wanted: EditSettings? = photo.edits.isModified ? photo.edits : nil
        // 가상 사본은 같은 파일을 가리키므로 파일 경로가 아니라 항목 ID로 캐시한다.
        let cacheKey = photo.id.uuidString
        let entry = thumbnailCache.object(forKey: cacheKey as NSString)
        if let entry, entry.edits == wanted { return }
        if entry != nil, wanted != nil, photo.id == selectedID, mode != .grid, !isOriginal { return }
        guard !loadingThumbnails.contains(cacheKey) else { return }
        loadingThumbnails.insert(cacheKey)
        let size = Self.thumbnailPixels
        thumbnailQueue.async { [pipeline, thumbnailStore] in
            var image: CGImage?
            if let wanted {
                let key = ThumbnailStore.key(for: photo)
                image = key.flatMap { thumbnailStore.load(photoID: photo.id, key: $0) }
                if image == nil, let rendered = try? pipeline.renderPreview(url: photo.url, edits: wanted, maxPixel: size).image {
                    image = rendered
                    if let key { thumbnailStore.store(rendered, photoID: photo.id, key: key) }
                }
            }
            image = image ?? (try? pipeline.thumbnail(for: photo.url, maxPixel: size))
            DispatchQueue.main.async {
                self.loadingThumbnails.remove(cacheKey)
                if let image { self.storeThumbnail(image, id: photo.id, edits: wanted) }
                if let latest = self.photo(withID: photo.id),
                   (latest.edits.isModified ? latest.edits : nil) != wanted {
                    self.requestThumbnail(for: latest)
                }
            }
        }
    }

    private func storeThumbnail(_ image: CGImage, id: UUID, edits: EditSettings?) {
        let entry = ThumbnailEntry(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                                   edits: edits)
        thumbnailCache.setObject(entry, forKey: id.uuidString as NSString, cost: image.width * image.height * 4)
        objectWillChange.send()
    }

    nonisolated private static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 슬라이더를 움직이는 동안에도 `renderInterval`마다 그린다. 같은 사진의 중간 결과는 순서대로 보여 주고,
    /// 다른 사진이나 원본·100% 보기로 바뀐 뒤 도착한 결과는 버린다.
    func requestRender(debounce: Bool = false) {
        renderDelay?.cancel()
        renderJob?.cancel()
        generation += 1
        let token = generation
        let source = "\(selectedID?.uuidString ?? "none"):\(isOriginal):\(actualSize)"
        if renderedSource != source {
            rendered = nil
            imageError = nil
            renderedSource = source
            displayedToken = 0
            histogram = nil
            clippingOverlay = nil
        }
        if mode != .compare { pinnedImage = nil; pinnedError = nil; pinnedSource = nil; pinnedRenderedEdits = nil }
        requestMask()
        refreshRAWCapabilities()
        guard mode != .grid, let photo = selection else { rendering = false; return }
        let edits = isOriginal ? EditSettings.neutral : photo.edits
        let maxPixel: Int? = actualSize ? nil : 2200
        let compare = mode == .compare ? pinned : nil
        let pinnedKey = compare.map { "\($0.id):\(maxPixel ?? 0)" }
        let pinnedEdits = compare.map { compareShowsPinnedEdits ? $0.edits : EditSettings.neutral }
        let reference = pinnedKey != pinnedSource || pinnedEdits != pinnedRenderedEdits ? compare : nil
        let recentKey = actualSize ? nil : "\(photo.id):\(isOriginal)"
        let recent = recentKey.flatMap { key in recentRenders.last { $0.key == key } }
        let renderCurrent = recent?.edits != edits
        if let recent, let recentKey, !renderCurrent {
            rendered = recent.image
            imageError = nil
            displayedToken = token
            histogram = recent.histogram
            refreshClippingOverlay()
            rememberRender(recent.image, key: recentKey, edits: edits, histogram: recent.histogram)
            if reference == nil {
                rendering = false
                prefetchNeighbor()
                return
            }
        } else if rendered == nil {
            if let recent {
                rendered = recent.image
                histogram = recent.histogram
            } else if photo.isRAW, !actualSize, isOriginal || !photo.edits.isModified {
                requestPlaceholder(for: photo, source: source)
            }
        }
        rendering = true
        exactRenderFollowUp?.cancel()
        let approximate = editDragActive && !isOriginal && !actualSize
        requestedApproximation = approximate
        let thumbnailSize = renderCurrent && !isOriginal && edits.isModified ? Self.thumbnailPixels : nil
        let job = DispatchWorkItem { [previewPipeline] in
            let preview = renderCurrent
                ? Result { try previewPipeline.renderPreview(url: photo.url, edits: edits, maxPixel: maxPixel,
                                                             allowApproximation: approximate) } : nil
            let current = preview.map { result in result.map(\.image) }
            let isApproximate = (try? preview?.get())?.isApproximate ?? false
            let thumbnail = isApproximate ? nil : thumbnailSize.flatMap { size in
                (try? current?.get()).flatMap { Self.downscaled($0, maxPixel: size) }
            }
            let histogram = (try? current?.get()).flatMap { ImageHistogram.make(from: $0) }
            // 기준 사진도 편집 미리보기 파이프라인으로 그려 같은 사진을 편집하는 동안 현상을 재사용한다.
            let referenceResult = reference.map { fixed in
                Result { try previewPipeline.renderPreview(url: fixed.url, edits: pinnedEdits ?? .neutral,
                                                           maxPixel: maxPixel, allowApproximation: approximate) }
            }
            DispatchQueue.main.async {
                guard token == self.generation else {
                    guard source == self.renderedSource, token > self.displayedToken,
                          case .success(let cg)? = current else { return }
                    self.displayedToken = token
                    self.rendered = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.histogram = histogram
                    return
                }
                self.rendering = false
                switch current {
                case .success(let cg)?:
                    self.imageError = nil
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.rendered = image
                    self.displayedToken = token
                    self.histogram = histogram
                    self.refreshClippingOverlay()
                    self.showingApproximation = isApproximate
                    if isApproximate {
                        // 끝을 알리지 않는 입력(키보드로 슬라이더 조절 등)도 잠시 멈추면 정확히 다시 그린다.
                        let followUp = DispatchWorkItem { [weak self] in
                            guard let self, token == self.generation, self.showingApproximation else { return }
                            self.editDragActive = false
                            self.requestRender()
                        }
                        self.exactRenderFollowUp = followUp
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: followUp)
                    } else if let recentKey {
                        self.rememberRender(image, key: recentKey, edits: edits, histogram: histogram)
                    }
                case .failure(let error)?:
                    self.rendered = nil
                    self.imageError = error.localizedDescription
                    self.histogram = nil
                    self.clippingOverlay = nil
                case nil:
                    break
                }
                if let thumbnail, let latest = self.photo(withID: photo.id), latest.edits == edits {
                    self.storeThumbnail(thumbnail, id: photo.id, edits: edits)
                    self.thumbnailQueue.async { [thumbnailStore = self.thumbnailStore] in
                        if let key = ThumbnailStore.key(for: latest) {
                            thumbnailStore.store(thumbnail, photoID: latest.id, key: key)
                        }
                    }
                }
                if let referenceResult {
                    switch referenceResult {
                    case .success(let result):
                        self.pinnedError = nil
                        self.pinnedImage = NSImage(cgImage: result.image,
                                                   size: NSSize(width: result.image.width, height: result.image.height))
                        // 근사로 그린 기준 사진은 다음 렌더에서 정확히 다시 그린다.
                        self.pinnedRenderedEdits = result.isApproximate ? nil : pinnedEdits
                    case .failure(let error):
                        self.pinnedImage = nil
                        self.pinnedError = error.localizedDescription
                        self.pinnedRenderedEdits = pinnedEdits
                    }
                    self.pinnedSource = pinnedKey
                }
                self.prefetchNeighbor()
            }
        }
        renderJob = job
        let delay = debounce ? max(0, Self.renderInterval - Date().timeIntervalSince(lastRenderDispatch)) : 0
        let dispatch = DispatchWorkItem {
            self.lastRenderDispatch = Date()
            self.previewQueue.async(execute: job)
        }
        renderDelay = dispatch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dispatch)
    }

    /// 선택한 RAW에서 조절할 수 있는 디코더 항목과 기본값을 읽는다. 파일마다 한 번만 읽는다.
    private func refreshRAWCapabilities() {
        guard let photo = selection else { rawCapabilities = nil; rawCapabilitiesPath = nil; return }
        guard rawCapabilitiesPath != photo.path else { return }
        rawCapabilitiesPath = photo.path
        if let known = rawCapabilitiesByPath[photo.path] { rawCapabilities = known; return }
        rawCapabilities = nil
        guard photo.isRAW else { return }
        let path = photo.path
        placeholderQueue.async { [pipeline] in
            let capabilities = pipeline.rawCapabilities(for: photo.url)
            DispatchQueue.main.async {
                self.rawCapabilitiesByPath[path] = capabilities
                if self.rawCapabilitiesPath == path { self.rawCapabilities = capabilities }
            }
        }
    }

    private func rememberRender(_ image: NSImage, key: String, edits: EditSettings, histogram: ImageHistogram?) {
        recentRenders.removeAll { $0.key == key }
        recentRenders.append((key, edits, image, histogram))
        if recentRenders.count > Self.recentRenderLimit {
            recentRenders.removeFirst(recentRenders.count - Self.recentRenderLimit)
        }
    }

    /// 현상한 결과가 보일 때만 클리핑 표시를 만든다. 카메라 미리보기에는 히스토그램과 표시를 만들지 않는다.
    private func refreshClippingOverlay() {
        overlayToken += 1
        let token = overlayToken
        guard showsClipping, histogram != nil,
              let image = rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            clippingOverlay = nil
            return
        }
        placeholderQueue.async {
            let overlay = ImageHistogram.clippingOverlay(for: image)
            DispatchQueue.main.async {
                guard token == self.overlayToken else { return }
                self.clippingOverlay = overlay.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
    }

    /// RAW 안의 카메라 미리보기를 현상이 끝날 때까지 먼저 보여 준다. 보정하지 않은 사진에만 쓴다.
    private func requestPlaceholder(for photo: PhotoAsset, source: String) {
        placeholderQueue.async { [pipeline] in
            let image = pipeline.embeddedPreview(for: photo.url, maxPixel: 2200)
            DispatchQueue.main.async {
                guard let image, self.renderedSource == source, self.rendered == nil, self.rendering else { return }
                self.rendered = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    /// 방금 이동한 방향의 다음 사진을 미리 현상해 두면 넘기는 즉시 보인다.
    private func prefetchNeighbor() {
        guard mode != .grid, !actualSize, let current = selectedID else { return }
        let visible = visiblePhotos
        guard let index = visible.firstIndex(where: { $0.id == current }),
              visible.indices.contains(index + moveDirection) else { return }
        let photo = visible[index + moveDirection]
        let originalView = isOriginal
        let edits = originalView ? EditSettings.neutral : photo.edits
        let key = "\(photo.id):\(originalView)"
        guard !prefetching.contains(key), !recentRenders.contains(where: { $0.key == key && $0.edits == edits }) else {
            return
        }
        prefetching.insert(key)
        prefetchQueue.async { [pipeline] in
            let cg = try? pipeline.renderPreview(url: photo.url, edits: edits, maxPixel: 2200).image
            let histogram = cg.flatMap { ImageHistogram.make(from: $0) }
            DispatchQueue.main.async {
                self.prefetching.remove(key)
                guard let cg, let latest = self.photo(withID: photo.id),
                      (originalView ? EditSettings.neutral : latest.edits) == edits else { return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.rememberRender(image, key: key, edits: edits, histogram: histogram)
                if self.renderedSource == "\(photo.id):\(originalView):false", self.displayedToken == 0,
                   self.rendering {
                    self.rendered = image
                    self.histogram = histogram
                }
            }
        }
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
                catch { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
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
                        data = try pipeline.prepareJPEG(url: photo.url, edits: photo.edits, maxPixel: options.maxPixel,
                                                        quality: options.quality, includeLocation: options.includeLocation,
                                                        watermark: options.watermark).data
                    }
                    let baseName = ExportOptions.baseName(template: options.filenameTemplate, sourceURL: photo.url,
                                                          capturedAt: photo.metadata.capturedAt, sequence: index + 1,
                                                          copyName: photo.copyName)
                    _ = try pipeline.writeJPEG(data, baseName: baseName, to: directory)
                    successes += 1
                }
                catch { failures.append("\(photo.filename): \(error.localizedDescription)") }
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
