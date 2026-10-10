import Foundation

/// 표시·촬영 정보로 사진을 거르는 조건. 비어 있는 항목은 거르지 않는다.
/// 범위 조건이 있으면 그 정보가 없는 사진(초점거리가 없는 PNG 등)은 빠진다.
public struct PhotoCriteria: Codable, Equatable, Sendable {
    /// 파일 이름·키워드·설명에 들어 있는 글자.
    public var text = ""
    public var minimumRating = 0
    /// nil이면 표시와 관계없다. `.none`은 표시가 없는 사진만이다.
    public var flag: PhotoFlag?
    public var colorLabel: PhotoColorLabel?
    public var camera: String?
    public var lens: String?
    public var minimumFocalLength: Double?
    public var maximumFocalLength: Double?
    public var minimumISO: Int?
    public var maximumISO: Int?
    /// 촬영일 범위(그날 0시부터 마지막 날 끝까지). 시각은 보지 않는다.
    public var firstDay: Date?
    public var lastDay: Date?

    public init() {}

    public var isEmpty: Bool { self == PhotoCriteria() }

    public func matches(_ photo: PhotoAsset, calendar: Calendar = .current) -> Bool {
        let metadata = photo.metadata
        if photo.rating < minimumRating { return false }
        if let flag, photo.flag != flag { return false }
        if let colorLabel, photo.colorLabel != colorLabel { return false }
        if let camera, metadata.camera != camera { return false }
        if let lens, metadata.lens != lens { return false }
        if !Self.contains(metadata.focalLength, minimumFocalLength, maximumFocalLength) { return false }
        if !Self.contains(metadata.iso, minimumISO, maximumISO) { return false }
        if firstDay != nil || lastDay != nil {
            guard let captured = metadata.capturedAt else { return false }
            if let firstDay, captured < calendar.startOfDay(for: firstDay) { return false }
            if let lastDay, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)),
               captured >= end { return false }
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !(photo.displayName.localizedCaseInsensitiveContains(text) ||
                            photo.keywords.contains { $0.localizedCaseInsensitiveContains(text) } ||
                            photo.caption.localizedCaseInsensitiveContains(text)) {
            return false
        }
        return true
    }

    private static func contains<T: Comparable>(_ value: T?, _ lower: T?, _ upper: T?) -> Bool {
        guard lower != nil || upper != nil else { return true }
        guard let value else { return false }
        return (lower.map { value >= $0 } ?? true) && (upper.map { value <= $0 } ?? true)
    }

    /// 화면에 보이는 조건 요약("S9 · 20–35mm · ISO ~800"). 조건이 없으면 빈 배열.
    public func summary(calendar: Calendar = .current) -> [String] {
        var parts: [String] = []
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append("‘\(text)’") }
        if minimumRating > 0 { parts.append("\(minimumRating)★ 이상") }
        switch flag {
        case .pick?: parts.append("채택됨")
        case .reject?: parts.append("제외됨")
        case PhotoFlag.none?: parts.append("표시 없음")
        case nil: break
        }
        if let colorLabel { parts.append("\(colorLabel.title) 라벨") }
        if let camera { parts.append(camera) }
        if let lens { parts.append(lens) }
        if let range = Self.rangeText(minimumFocalLength.map(Self.number), maximumFocalLength.map(Self.number)) {
            parts.append(range + "mm")
        }
        if let range = Self.rangeText(minimumISO.map(String.init), maximumISO.map(String.init)) { parts.append("ISO " + range) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let range = Self.rangeText(firstDay.map(formatter.string), lastDay.map(formatter.string)) { parts.append(range) }
        return parts
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0" }
        if abs(value) >= 1e15 { return String(format: "%.1e", value) }
        return value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func rangeText(_ lower: String?, _ upper: String?) -> String? {
        switch (lower, upper) {
        case let (lower?, upper?): lower == upper ? lower : "\(lower)–\(upper)"
        case let (lower?, nil): "\(lower)~"
        case let (nil, upper?): "~\(upper)"
        case (nil, nil): nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text, minimumRating, flag, colorLabel, camera, lens, minimumFocalLength, maximumFocalLength
        case minimumISO, maximumISO, firstDay, lastDay
    }

    /// 없는 항목은 거르지 않는 값으로 읽어, 나중에 항목이 늘어도 예전 파일을 그대로 연다.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        minimumRating = try container.decodeIfPresent(Int.self, forKey: .minimumRating) ?? 0
        flag = try container.decodeIfPresent(PhotoFlag.self, forKey: .flag)
        colorLabel = try container.decodeIfPresent(PhotoColorLabel.self, forKey: .colorLabel)
        camera = try container.decodeIfPresent(String.self, forKey: .camera)
        lens = try container.decodeIfPresent(String.self, forKey: .lens)
        minimumFocalLength = try container.decodeIfPresent(Double.self, forKey: .minimumFocalLength)
        maximumFocalLength = try container.decodeIfPresent(Double.self, forKey: .maximumFocalLength)
        minimumISO = try container.decodeIfPresent(Int.self, forKey: .minimumISO)
        maximumISO = try container.decodeIfPresent(Int.self, forKey: .maximumISO)
        firstDay = try container.decodeIfPresent(Date.self, forKey: .firstDay)
        lastDay = try container.decodeIfPresent(Date.self, forKey: .lastDay)
    }
}

/// 조건으로 정의한 폴더. 사진을 담지 않고 열 때마다 조건에 맞는 사진을 보인다.
public struct SmartFolder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var criteria: PhotoCriteria

    public init(id: UUID = UUID(), name: String, criteria: PhotoCriteria) {
        self.id = id
        self.name = name
        self.criteria = criteria
    }
}

public enum SmartFolderStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case duplicateID(UUID)
    case invalidName(String)
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "지원하지 않는 스마트 폴더 버전 \(version)입니다."
        case .duplicateID(let id): "중복된 스마트 폴더 ID입니다: \(id.uuidString)"
        case .invalidName(let name): "스마트 폴더 이름은 공백을 제외하고 1…80자여야 합니다: \(name)"
        case .duplicateName(let name): "같은 이름의 스마트 폴더가 이미 있습니다: \(name)"
        }
    }
}

/// 카탈로그 옆 `smart-folders.json`. 없으면 빈 목록이다.
public struct SmartFolderStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        CatalogStore.defaultURL.deletingLastPathComponent().appendingPathComponent("smart-folders.json")
    }

    public func load() throws -> [SmartFolder] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw SmartFolderStoreError.unsupportedVersion(envelope.version) }
        return try Self.validated(envelope.folders)
    }

    public func save(_ folders: [SmartFolder]) throws {
        let normalized = try Self.validated(folders)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(version: 1, folders: normalized)).write(to: url, options: .atomic)
    }

    /// 이름 앞뒤 공백을 지우고, 비었거나 80자를 넘거나 대소문자만 다른 같은 이름이면 거부한다.
    public static func validated(_ folders: [SmartFolder]) throws -> [SmartFolder] {
        var ids = Set<UUID>()
        var names = Set<String>()
        return try folders.map { folder in
            guard ids.insert(folder.id).inserted else { throw SmartFolderStoreError.duplicateID(folder.id) }
            var normalized = folder
            normalized.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(normalized.name.count) else { throw SmartFolderStoreError.invalidName(folder.name) }
            let key = normalized.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw SmartFolderStoreError.duplicateName(normalized.name) }
            return normalized
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let folders: [SmartFolder]
    }
}
