import Foundation

/// 이름 붙인 보정 조합. 부분 보정·복구는 사진마다 위치가 달라 담지 않는다.
public struct EditPreset: Identifiable, Codable, Equatable, Sendable {
    public static let allowedComponents: EditComponents = [.global, .lut, .geometry]

    public var id: UUID
    public var name: String
    public var settings: EditSettings
    public var components: EditComponents
    public var lightroom: LightroomPresetPayload?

    /// `source`에서 `components`에 해당하는 값만 가져온다.
    public init(id: UUID = UUID(), name: String, source: EditSettings, components: EditComponents) {
        let kept = components.intersection(Self.allowedComponents)
        self.id = id
        self.name = name
        self.settings = EditSettings.neutral.merging(from: source, components: kept)
        self.components = kept
        self.lightroom = nil
    }

    public init(id: UUID = UUID(), name: String, lightroom: LightroomPresetPayload) {
        self.id = id
        self.name = name
        self.settings = .neutral
        self.components = .global
        self.lightroom = lightroom
    }

    /// Lightroom 화이트밸런스는 RAW 여부에 따라 다르게 적용하므로 사진마다 `isRAW`를 받는다.
    public func applied(to edits: EditSettings, isRAW: Bool) -> EditSettings {
        if let lightroom {
            return lightroom.applying(to: edits, isRAW: isRAW)
        }
        return edits.merging(from: settings, components: components)
    }

    private enum CodingKeys: String, CodingKey { case id, name, settings, components, lightroom }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        settings = try container.decode(EditSettings.self, forKey: .settings)
        let raw = try container.decode(Int.self, forKey: .components)
        components = EditComponents(rawValue: raw)
        lightroom = container.contains(.lightroom)
            ? try container.decode(LightroomPresetPayload.self, forKey: .lightroom) : nil
        guard !components.isEmpty, Self.allowedComponents.isSuperset(of: components) else {
            throw DecodingError.dataCorruptedError(forKey: .components, in: container,
                                                   debugDescription: "Unsupported preset components \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(settings, forKey: .settings)
        try container.encode(components.rawValue, forKey: .components)
        try container.encodeIfPresent(lightroom, forKey: .lightroom)
    }
}

public enum EditPresetStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case duplicateID(UUID)
    case invalidName(String)
    case duplicateName(String)
    case emptyComponents

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "지원하지 않는 프리셋 파일 버전 \(version)입니다."
        case .duplicateID(let id): "중복된 프리셋 ID입니다: \(id.uuidString)"
        case .invalidName(let name): "프리셋 이름은 공백을 제외하고 1…80자여야 합니다: \(name)"
        case .duplicateName(let name): "같은 이름의 프리셋이 이미 있습니다: \(name)"
        case .emptyComponents: "프리셋에 담을 항목을 하나 이상 선택하세요."
        }
    }
}

/// `presets.json`에 프리셋을 원자적으로 저장한다. 손상된 파일은 읽기 오류로 알리고 덮어쓰지 않는다.
public struct EditPresetStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        CatalogStore.defaultURL.deletingLastPathComponent().appendingPathComponent("presets.json")
    }

    public func load() throws -> [EditPreset] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw EditPresetStoreError.unsupportedVersion(envelope.version) }
        return try Self.validated(envelope.presets)
    }

    public func save(_ presets: [EditPreset]) throws {
        let normalized = try Self.validated(presets)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(version: 1, presets: normalized)).write(to: url, options: .atomic)
    }

    public static func validated(_ presets: [EditPreset]) throws -> [EditPreset] {
        var ids = Set<UUID>()
        var names = Set<String>()
        return try presets.map { preset in
            guard ids.insert(preset.id).inserted else { throw EditPresetStoreError.duplicateID(preset.id) }
            guard !preset.components.isEmpty else { throw EditPresetStoreError.emptyComponents }
            var normalized = preset
            try normalized.lightroom?.validate()
            normalized.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(normalized.name.count) else { throw EditPresetStoreError.invalidName(preset.name) }
            let key = normalized.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw EditPresetStoreError.duplicateName(normalized.name) }
            return normalized
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let presets: [EditPreset]
    }
}
