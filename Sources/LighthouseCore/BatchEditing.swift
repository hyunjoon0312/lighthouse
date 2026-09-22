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
    public static let all: EditComponents = [.global, .lut, .geometry, .local]
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
        }
        if components.contains(.lut) {
            result.lut = source.lut
        }
        if components.contains(.geometry) {
            result.rotationQuarterTurns = source.rotationQuarterTurns
            result.cropAspect = source.cropAspect
        }
        if components.contains(.local) {
            result.localAdjustments = source.localAdjustments
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

public struct EditHistory: Sendable {
    private let limit: Int
    private var undoStack: [[PhotoEditChange]] = []
    private var redoStack: [[PhotoEditChange]] = []

    public init(limit: Int = 100) {
        self.limit = max(0, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ changes: [PhotoEditChange]) {
        let effective = changes.filter { $0.before != $0.after }
        guard !effective.isEmpty else { return }
        redoStack.removeAll()
        guard limit > 0 else { return }
        undoStack.append(effective)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
    }

    public mutating func undo() -> [PhotoEditChange]? {
        guard let changes = undoStack.popLast() else { return nil }
        redoStack.append(changes)
        return changes
    }

    public mutating func redo() -> [PhotoEditChange]? {
        guard let changes = redoStack.popLast() else { return nil }
        undoStack.append(changes)
        return changes
    }
}
