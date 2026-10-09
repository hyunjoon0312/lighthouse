import Foundation

public struct EditComponents: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let global = EditComponents(rawValue: 1)
    public static let lut = EditComponents(rawValue: 2)
    public static let geometry = EditComponents(rawValue: 4)
    public static let local = EditComponents(rawValue: 8)
    public static let retouch = EditComponents(rawValue: 16)
    public static let all: EditComponents = [.global, .lut, .geometry, .local, .retouch]
}

public extension EditSettings {
    func merging(from source: EditSettings, components: EditComponents) -> EditSettings {
        var result = self
        if components.contains(.global) {
            result.exposure = source.exposure
            result.contrast = source.contrast
            result.saturation = source.saturation
            result.temperatureShift = source.temperatureShift
            result.tintShift = source.tintShift
            result.whiteBalance = source.whiteBalance
            result.highlights = source.highlights
            result.shadows = source.shadows
            result.whites = source.whites
            result.blacks = source.blacks
            result.colorProfile = source.colorProfile
            result.sharpness = source.sharpness
            result.curves = source.curves
            result.colorRanges = source.colorRanges
            result.colorGrading = source.colorGrading
            result.grain = source.grain
            result.rawDevelop = source.rawDevelop
            result.noiseReduction = source.noiseReduction
            result.flicker = source.flicker
            result.vibrance = source.vibrance
            result.clarity = source.clarity
            result.texture = source.texture
            result.dehaze = source.dehaze
            result.vignette = source.vignette
            result.hdrAmount = source.hdrAmount
        }
        if components.contains(.lut) {
            result.lut = source.lut
        }
        if components.contains(.geometry) {
            result.rotationQuarterTurns = source.rotationQuarterTurns
            result.cropAspect = source.cropAspect
            result.straightenDegrees = source.straightenDegrees
            result.cropRect = source.cropRect
        }
        if components.contains(.local) {
            result.localAdjustments = source.localAdjustments
        }
        if components.contains(.retouch) {
            result.retouchStrokes = source.retouchStrokes
        }
        return result
    }
}

public enum PhotoSelectionMode: Sendable {
    case single
    case toggle
    case range
}

public struct PhotoSelectionState: Equatable, Sendable {
    public private(set) var selectedIDs: Set<UUID> = []
    public private(set) var activeID: UUID?
    public private(set) var anchorID: UUID?

    public init() {}

    public mutating func select(_ id: UUID, in visibleIDs: [UUID], mode: PhotoSelectionMode = .single) {
        guard visibleIDs.contains(id) else { return }
        switch mode {
        case .single:
            selectedIDs = [id]
            activeID = id
            anchorID = id
        case .toggle:
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
                if activeID == id {
                    activeID = visibleIDs.first(where: { selectedIDs.contains($0) })
                }
                if anchorID == id {
                    anchorID = activeID
                }
            } else {
                selectedIDs.insert(id)
                activeID = id
                anchorID = id
            }
            if selectedIDs.isEmpty {
                activeID = nil
                anchorID = nil
            }
        case .range:
            let start = [anchorID, activeID, id].compactMap { $0 }
                .first(where: { visibleIDs.contains($0) }) ?? id
            guard let first = visibleIDs.firstIndex(of: start),
                  let last = visibleIDs.firstIndex(of: id) else { return }
            selectedIDs = Set(visibleIDs[min(first, last)...max(first, last)])
            activeID = id
            anchorID = start
        }
    }

    public mutating func selectAll(in visibleIDs: [UUID]) {
        selectedIDs = Set(visibleIDs)
        guard !selectedIDs.isEmpty else {
            activeID = nil
            anchorID = nil
            return
        }
        if activeID.map({ selectedIDs.contains($0) }) != true {
            activeID = visibleIDs.first
        }
        if anchorID.map({ selectedIDs.contains($0) }) != true {
            anchorID = activeID
        }
    }

    public mutating func clear() {
        selectedIDs = []
        activeID = nil
        anchorID = nil
    }

    public mutating func reconcile(with visibleIDs: [UUID], selectFirstIfEmpty: Bool = false) {
        selectedIDs.formIntersection(visibleIDs)
        if selectedIDs.isEmpty {
            if selectFirstIfEmpty, let first = visibleIDs.first {
                select(first, in: visibleIDs)
            } else {
                clear()
            }
            return
        }
        if activeID.map({ selectedIDs.contains($0) }) != true {
            activeID = visibleIDs.first(where: { selectedIDs.contains($0) })
        }
        if anchorID.map({ selectedIDs.contains($0) }) != true {
            anchorID = activeID
        }
    }

    public mutating func focus(_ id: UUID, in visibleIDs: [UUID]) {
        guard visibleIDs.contains(id) else { return }
        if selectedIDs.contains(id) {
            activeID = id
        } else {
            select(id, in: visibleIDs)
        }
    }
}

public struct PhotoEditChange: Equatable, Sendable {
    public let id: UUID
    public let before: EditSettings
    public let after: EditSettings

    public init(id: UUID, before: EditSettings, after: EditSettings) {
        self.id = id
        self.before = before
        self.after = after
    }
}

public struct PhotoMarks: Equatable, Sendable {
    public var rating: Int
    public var flag: PhotoFlag
    public var keywords: [String]
    public var caption: String
    public var colorLabel: PhotoColorLabel?

    public init(rating: Int, flag: PhotoFlag, keywords: [String] = [], caption: String = "",
                colorLabel: PhotoColorLabel? = nil) {
        self.rating = rating
        self.flag = flag
        self.keywords = keywords
        self.caption = caption
        self.colorLabel = colorLabel
    }
}

public struct PhotoMarkChange: Equatable, Sendable {
    public let id: UUID
    public let before: PhotoMarks
    public let after: PhotoMarks

    public init(id: UUID, before: PhotoMarks, after: PhotoMarks) {
        self.id = id
        self.before = before
        self.after = after
    }
}

/// 카탈로그에서 뺀 한 장. 되돌릴 때 빼기 전 순서(`index`)와 들어 있던 내 폴더를 되살린다.
public struct RemovedPhoto: Equatable, Sendable {
    public let index: Int
    public let photo: PhotoAsset
    public let folderIDs: [UUID]

    public init(index: Int, photo: PhotoAsset, folderIDs: [UUID]) {
        self.index = index
        self.photo = photo
        self.folderIDs = folderIDs
    }
}

/// 실행 취소 한 단계. 보정값 변경, 별점·플래그 변경, 카탈로그에서 빼기를 같은 순서로 되돌린다.
public enum HistoryStep: Equatable, Sendable {
    case edits([PhotoEditChange])
    case marks([PhotoMarkChange])
    case removal([RemovedPhoto])
}

public struct EditHistory: Sendable {
    private let limit: Int
    private var undoStack: [HistoryStep] = []
    private var redoStack: [HistoryStep] = []
    private var pendingContinuous: PhotoEditChange?

    public init(limit: Int = 100) {
        self.limit = max(0, limit)
    }

    private var hasPendingContinuous: Bool {
        pendingContinuous.map { $0.before != $0.after } ?? false
    }
    public var canUndo: Bool { !undoStack.isEmpty || (limit > 0 && hasPendingContinuous) }
    public var canRedo: Bool { !redoStack.isEmpty && !hasPendingContinuous }

    /// 슬라이더 드래그처럼 이어지는 같은 사진의 변경을 한 실행 취소 단계로 묶는다.
    public mutating func recordContinuous(_ change: PhotoEditChange) {
        if let pending = pendingContinuous, pending.id == change.id {
            pendingContinuous = PhotoEditChange(id: change.id, before: pending.before, after: change.after)
        } else {
            commitContinuous()
            pendingContinuous = change
        }
    }

    public mutating func commitContinuous() {
        guard let pending = pendingContinuous else { return }
        pendingContinuous = nil
        append(.edits([pending].filter { $0.before != $0.after }))
    }

    public mutating func record(_ changes: [PhotoEditChange]) {
        commitContinuous()
        append(.edits(changes.filter { $0.before != $0.after }))
    }

    public mutating func recordMarks(_ changes: [PhotoMarkChange]) {
        commitContinuous()
        append(.marks(changes.filter { $0.before != $0.after }))
    }

    /// 카탈로그에서 뺀 사진. 그 사진의 앞선 보정·표시 단계는 남겨 두어, 빼기를 되돌린 뒤 이어서 되돌릴 수 있다.
    public mutating func recordRemoval(_ photos: [RemovedPhoto]) {
        commitContinuous()
        append(.removal(photos))
    }

    private mutating func append(_ step: HistoryStep) {
        switch step {
        case .edits(let changes): guard !changes.isEmpty else { return }
        case .marks(let changes): guard !changes.isEmpty else { return }
        case .removal(let photos): guard !photos.isEmpty else { return }
        }
        redoStack.removeAll()
        guard limit > 0 else { return }
        undoStack.append(step)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
    }

    /// 실행 취소로 되돌릴 수 있는 이 사진의 보정 변경(오래된 것부터). 여러 장을 한 번에 바꾼 단계는 이 사진 몫만 담는다.
    public func editChanges(for id: UUID) -> [PhotoEditChange] {
        let recorded = undoStack.flatMap { step -> [PhotoEditChange] in
            guard case .edits(let changes) = step else { return [] }
            return changes.filter { $0.id == id }
        }
        guard let pending = pendingContinuous, pending.id == id, pending.before != pending.after else { return recorded }
        return recorded + [pending]
    }

    public mutating func undo() -> HistoryStep? {
        commitContinuous()
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(step)
        return step
    }

    public mutating func redo() -> HistoryStep? {
        commitContinuous()
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(step)
        return step
    }
}
