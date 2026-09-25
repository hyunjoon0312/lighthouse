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
    case all, picks, rejects, edited, bursts, missing, folder(String), collection(UUID)
}

/// 사진 목록 정렬. 카탈로그는 촬영 시각 순으로 보관하고 보이는 목록만 다시 정렬한다.
enum PhotoSortOrder: String, CaseIterable, Identifiable {
    case captureTime, fileName, rating
    var id: Self { self }
    var title: String {
        switch self {
        case .captureTime: "촬영 시각 순"
        case .fileName: "파일 이름 순"
        case .rating: "별점 높은 순"
        }
    }
}

/// 촬영 시각으로 묶은 연속 촬영과 사진마다의 위치(몇 번째 묶음의 몇 번째 컷).
struct BurstIndex {
    var groups: [BurstGroup] = []
    var positions: [UUID: (group: Int, shot: Int)] = [:]
}

struct MaskRequestKey: Equatable {
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
    let keywords: [String]
    let caption: String
    let options: ExportOptions
    let result: JPEGPreview

    /// 파일 이름 규칙은 데이터에 영향이 없으므로 비교하지 않는다.
    func matches(_ photo: PhotoAsset, _ other: ExportOptions) -> Bool {
        var mine = options, theirs = other
        mine.filenameTemplate = ""
        theirs.filenameTemplate = ""
        return photoID == photo.id && edits == photo.edits && keywords == photo.keywords &&
            caption == photo.caption && mine == theirs
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

final class ThumbnailEntry: NSObject {
    let image: NSImage
    let edits: EditSettings?
    /// 원본을 읽을 수 없어 디스크에 남은 마지막 썸네일을 보여 주는 중인지.
    let isFallback: Bool

    init(image: NSImage, edits: EditSettings?, isFallback: Bool = false) {
        self.image = image
        self.edits = edits
        self.isFallback = isFallback
    }
}

struct LibraryCounts {
    var total = 0
    var picks = 0
    var rejects = 0
    var edited = 0
    var bursts = 0
    var missing = 0
    /// 내 폴더별로 목록에 보이는 사진 수.
    var folders: [UUID: Int] = [:]
}

final class CancellationFlag: @unchecked Sendable {
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
    /// 사진만 크게 보는 보기(F). 패널을 숨기며, 그리드로 돌아가면 끝난다.
    @Published var isFocusView = false
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
    @Published var sortOrder = PhotoSortOrder(rawValue: UserDefaults.standard.string(forKey: "photoSortOrder") ?? "") ?? .captureTime {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "photoSortOrder")
            visibleCache = nil
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

    let pipeline = ImagePipeline()
    let previewPipeline = ImagePipeline(cachesDevelopment: true)
    let thumbnailStore = ThumbnailStore()
    let lutStore = LUTStore()
    let catalog = CatalogStore(url: CatalogStore.defaultURL)
    let folderStore = PhotoFolderStore(url: PhotoFolderStore.defaultURL)
    let presetStore = EditPresetStore(url: EditPresetStore.defaultURL)
    let backup = CatalogBackup(directory: CatalogBackup.defaultDirectory)
    var backupFailureReported = false
    let previewQueue = DispatchQueue(label: "com.rian.lighthouse.preview", qos: .userInitiated)
    let thumbnailQueue = DispatchQueue(label: "com.rian.lighthouse.thumbnails", qos: .utility)
    let placeholderQueue = DispatchQueue(label: "com.rian.lighthouse.placeholder", qos: .userInitiated)
    let prefetchQueue = DispatchQueue(label: "com.rian.lighthouse.prefetch", qos: .utility)
    let batchQueue = DispatchQueue(label: "com.rian.lighthouse.batch", qos: .userInitiated)
    let maskQueue = DispatchQueue(label: "com.rian.lighthouse.mask", qos: .userInitiated)
    let autoMaskQueue = DispatchQueue(label: "com.rian.lighthouse.automask", qos: .userInitiated)
    let lutQueue = DispatchQueue(label: "com.rian.lighthouse.lut", qos: .userInitiated)
    let retouchQueue = DispatchQueue(label: "com.rian.lighthouse.retouch", qos: .userInitiated)
    let saveQueue = DispatchQueue(label: "com.rian.lighthouse.catalog", qos: .utility)
    var saveDelay: DispatchWorkItem?
    var renderDelay: DispatchWorkItem?
    var generation = 0
    var renderedSource: String?
    var pinnedSource: String?
    var pinnedRenderedEdits: EditSettings?
    var retouchGeneration = 0
    var renderJob: DispatchWorkItem?
    var displayedToken = 0
    /// 슬라이더를 끄는 동안에는 RAW 노출·색온도·틴트를 근사로 그린다. 끝나면 정확히 다시 그린다.
    var editDragActive = false
    var showingApproximation = false
    var requestedApproximation = false
    var exactRenderFollowUp: DispatchWorkItem?
    var lastRenderDispatch = Date.distantPast
    var recentRenders: [(key: String, edits: EditSettings, image: NSImage, histogram: ImageHistogram?)] = []
    var overlayToken = 0
    var prefetching = Set<String>()
    var moveDirection = 1
    private var pendingCollapse: DispatchWorkItem?
    var exportCancellation: CancellationFlag?
    var importCancellation: CancellationFlag?
    private(set) var visibleCache: [PhotoAsset]?
    private(set) var indexCache: [UUID: Int]?
    private(set) var countsCache: LibraryCounts?
    private(set) var foldersCache: [String]?
    var burstCache: (signature: Int, index: BurstIndex)?
    /// 사진 목록의 ID·경로·촬영 정보만 본 서명. 보정·별점만 바뀌면 같아서 묶음·짝 계산을 다시 하지 않는다.
    private var structureSignatureCache: Int?
    private var pairCache: (signature: Int, companions: [UUID: [UUID]], pairedRAWs: Set<UUID>)?
    var burstRecommendationCache: [UUID: BurstRecommendation]?
    var burstCancellation: CancellationFlag?
    let burstQueue = DispatchQueue(label: "com.rian.lighthouse.burst", qos: .utility)
    /// 이번 실행에서 분석한 원본 품질. 앱을 다시 열면 다시 분석한다.
    @Published var burstQualities: [UUID: PhotoQuality] = [:] { didSet { burstRecommendationCache = nil } }
    /// 분석하려 했지만 읽지 못한 파일. 이 컷은 추천에서 빼고 표시도 바꾸지 않는다.
    @Published var burstFailedIDs = Set<UUID>() { didSet { burstRecommendationCache = nil } }
    @Published var isAnalyzingBursts = false
    @Published var burstAnalysisProgress = 0.0
    @Published var burstMessage: String?
    /// 삭제를 확인받는 중인 가상 사본.
    @Published var catalogRemoval: CatalogRemoval?
    var rawCapabilitiesPath: String?
    var rawCapabilitiesByPath: [String: RAWCapabilities?] = [:]
    static let renderInterval = 0.1
    static let recentRenderLimit = 6
    var maskGeneration = 0
    var selectionGeneration = 0
    var autoMaskGeneration = 0
    var lutLibraryGeneration = 0
    var maskSource: String?
    /// 화면의 마스크가 어떤 모양·구도로 그려졌는지. 같으면 효과 값만 바뀐 것이므로 다시 그리지 않는다.
    var displayedMaskKey: MaskRequestKey?
    /// 마스크는 한 번에 하나만 그리고, 그리는 동안 들어온 요청은 가장 마지막 것만 남긴다.
    var maskInFlight = false
    var pendingMaskJob: (() -> Void)?
    var draftPhotoID: UUID?
    var draftLocalID: UUID?
    private var started = false
    /// 마지막 확인에서 파일을 찾지 못한 원본 경로. 앱으로 돌아오거나 볼륨을 연결·해제하면 다시 확인한다.
    @Published var missingPaths: Set<String> = [] {
        didSet { visibleCache = nil; countsCache = nil; missingOriginalsDidChange() }
    }
    /// 원본이 없고 보관한 썸네일도 없는 사진. 원본이 돌아올 때까지 다시 찾지 않는다.
    var unavailableThumbnails = Set<UUID>()
    /// 마지막 썸네일로 대신 보여 주는 사진. 원본이 돌아오거나 다시 연결되면 새로 만든다.
    var fallbackThumbnailIDs = Set<UUID>()
    var missingScanRunning = false
    var missingScanAgain = false
    var fileObservers: [NSObjectProtocol] = []
    let fileCheckQueue = DispatchQueue(label: "com.rian.lighthouse.files", qos: .utility)
    var editHistory = EditHistory(limit: 100)
    let thumbnailCache = NSCache<NSString, ThumbnailEntry>()
    var loadingThumbnails = Set<String>()
    static let thumbnailPixels = 360
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
            cropSource != nil || catalogRemoval != nil
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
                (photo.edits.isModified ? 8 : 0) | (positions[photo.id] != nil ? 16 : 0) |
                (missingPaths.contains(photo.path) ? 32 : 0)
        }
        for photo in photos {
            var mask = masks[photo.id] ?? 0
            for raw in companions[photo.id] ?? [] { mask &= ~(masks[raw] ?? 0) }
            if mask & 1 != 0 { computed.total += 1 }
            if mask & 2 != 0 { computed.picks += 1 }
            if mask & 4 != 0 { computed.rejects += 1 }
            if mask & 8 != 0 { computed.edited += 1 }
            if mask & 16 != 0 { computed.bursts += 1 }
            if mask & 32 != 0 { computed.missing += 1 }
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

    var structureSignature: Int {
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

    var activeCompanions: [UUID: [UUID]] { collapsesRAWJPEGPairs ? pairs.companions : [:] }

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
        let missing = filter == .missing ? missingPaths : []
        var computed = collapsedFilter { photo in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .picks: matchesFilter = photo.flag == .pick
            case .rejects: matchesFilter = photo.flag == .reject
            case .edited: matchesFilter = photo.edits.isModified
            case .bursts: matchesFilter = positions[photo.id] != nil
            case .missing: matchesFilter = missing.contains(photo.path)
            case .folder(let path): matchesFilter = (photo.path as NSString).deletingLastPathComponent == path
            case .collection: matchesFilter = members?.contains(photo.id) ?? false
            }
            return matchesFilter && photo.rating >= minimumRating &&
                (search.isEmpty || photo.displayName.localizedCaseInsensitiveContains(search) ||
                 photo.keywords.contains { $0.localizedCaseInsensitiveContains(search) } ||
                 photo.caption.localizedCaseInsensitiveContains(search))
        }
        // 같은 값끼리는 촬영 시각 순서를 지킨다.
        switch sortOrder {
        case .captureTime: break
        case .fileName:
            computed = computed.enumerated().sorted { first, second in
                let order = first.element.displayName.localizedStandardCompare(second.element.displayName)
                return order != .orderedSame ? order == .orderedAscending : first.offset < second.offset
            }.map(\.element)
        case .rating:
            computed = computed.enumerated().sorted { first, second in
                first.element.rating != second.element.rating
                    ? first.element.rating > second.element.rating : first.offset < second.offset
            }.map(\.element)
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
                    case .failure(let error):
                        AppLog.catalog.error("folders.json load failed: \(error.localizedDescription, privacy: .private)")
                        self.folderLoadError = error.localizedDescription
                    }
                    switch presets {
                    case .success(let loaded):
                        self.presets = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    case .failure(let error):
                        AppLog.catalog.error("presets.json load failed: \(error.localizedDescription, privacy: .private)")
                        self.presetLoadError = error.localizedDescription
                    }
                    if let first = photos.first {
                        self.photoSelection.select(first.id, in: photos.map(\.id))
                    }
                    // 오늘 처음 연 상태를 남긴다. 이날 작업을 되돌리고 싶을 때 쓸 수 있다.
                    self.saveQueue.async { self.backUpIfNeeded(photos) }
                    self.observeFileAvailability()
                    self.refreshMissingOriginals()
                    self.refreshLUTLibrary()
                    self.requestRender()
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "--import"), arguments.indices.contains(index + 1) {
                        self.importURLs([URL(fileURLWithPath: arguments[index + 1])])
                    }
                case .failure(let error):
                    AppLog.catalog.fault("catalog load failed: \(error.localizedDescription, privacy: .private)")
                    self.loadError = """
                        카탈로그를 열 수 없습니다. 파일을 확인한 뒤 앱을 다시 실행하세요.
                        \(error.localizedDescription)

                        날짜별 보관본이 \(self.backup.directory.path)에 있습니다(파일 메뉴 › 카탈로그 보관본 보기). \
                        앱을 끝낸 뒤 원하는 날짜 폴더 안의 파일과 Masks 폴더를 \(self.catalog.url.deletingLastPathComponent().path)에 \
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

    func selectionDidChange(previousActive: UUID?, clearFocus: Bool = true) {
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
        if newMode == .grid { isFocusView = false }
        requestRender()
    }

    /// 그리드에서 누르면 사진 보기로 바꿔 들어간다.
    func toggleFocusView() {
        if isFocusView { isFocusView = false; return }
        guard selection != nil else { return }
        if mode == .grid { setMode(.edit) }
        isFocusView = true
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

    func copyEdits() {
        guard let selection else { return }
        clipboard = selection.edits
        operationMessage = "\(selection.displayName)의 보정을 복사했습니다. ⇧⌘V로 전체 보정과 LUT를 붙여넣습니다."
    }

    /// 복사한 보정 중 전체 보정·LUT를 선택한 사진(없으면 보고 있는 사진)에 붙여넣는다. 한 번에 실행 취소된다.
    /// 크롭·부분 보정·복구는 사진마다 달라 제외한다.
    func pasteEditsToSelection() {
        guard let clipboard else { return }
        let ids = actionTargets.map(\.id)
        guard !ids.isEmpty else { return }
        applyBatchEdits(source: clipboard, to: ids, components: Self.pasteComponents)
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

}

/// 카탈로그에서 뺄 항목. `hiddenCompanions`는 RAW+JPEG 한 장으로 보기에서 함께 빠지는 JPEG 수다.
struct CatalogRemoval: Equatable {
    var photos: [PhotoAsset]
    var hiddenCompanions: Int
    var isCopiesOnly: Bool { photos.allSatisfy(\.isVirtualCopy) }
}
