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
            result.highlights = source.highlights
            result.shadows = source.shadows
            result.sharpness = source.sharpness
            result.curves = source.curves
            result.colorRanges = source.colorRanges
            result.grain = source.grain
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

    public init(rating: Int, flag: PhotoFlag) {
        self.rating = rating
        self.flag = flag
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

/// 실행 취소 한 단계. 보정값 변경과 별점·플래그 변경을 같은 순서로 되돌린다.
public enum HistoryStep: Equatable, Sendable {
    case edits([PhotoEditChange])
    case marks([PhotoMarkChange])
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

    private mutating func append(_ step: HistoryStep) {
        switch step {
        case .edits(let changes): guard !changes.isEmpty else { return }
        case .marks(let changes): guard !changes.isEmpty else { return }
        }
        redoStack.removeAll()
        guard limit > 0 else { return }
        undoStack.append(step)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
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
