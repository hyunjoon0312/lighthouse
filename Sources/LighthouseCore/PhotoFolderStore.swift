import Foundation

public struct PhotoFolder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var photoIDs: Set<UUID>

    public init(id: UUID = UUID(), name: String, photoIDs: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.photoIDs = photoIDs
    }

    public mutating func add(_ ids: Set<UUID>) { photoIDs.formUnion(ids) }
    public mutating func remove(_ ids: Set<UUID>) { photoIDs.subtract(ids) }

    private enum CodingKeys: String, CodingKey { case id, name, photoIDs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        photoIDs = Set(try container.decode([UUID].self, forKey: .photoIDs))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(photoIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .photoIDs)
    }
}

public enum PhotoFolderStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case duplicateID(UUID)
    case invalidName(String)
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "지원하지 않는 사진 폴더 버전 \(version)입니다."
        case .duplicateID(let id): "중복된 사진 폴더 ID입니다: \(id.uuidString)"
        case .invalidName(let name): "사진 폴더 이름은 공백을 제외하고 1…80자여야 합니다: \(name)"
        case .duplicateName(let name): "같은 이름의 사진 폴더가 이미 있습니다: \(name)"
        }
    }
}

public struct PhotoFolderStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        CatalogStore.defaultURL.deletingLastPathComponent().appendingPathComponent("folders.json")
    }

    public func load() throws -> [PhotoFolder] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw PhotoFolderStoreError.unsupportedVersion(envelope.version) }
        return try Self.validated(envelope.folders)
    }

    public func save(_ folders: [PhotoFolder]) throws {
        let normalized = try Self.validated(folders)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(version: 1, folders: normalized)).write(to: url, options: .atomic)
    }

    private static func validated(_ folders: [PhotoFolder]) throws -> [PhotoFolder] {
        var ids = Set<UUID>()
        var names = Set<String>()
        return try folders.map { folder in
            guard ids.insert(folder.id).inserted else { throw PhotoFolderStoreError.duplicateID(folder.id) }
            var normalized = folder
            normalized.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(normalized.name.count) else {
                throw PhotoFolderStoreError.invalidName(folder.name)
            }
            let key = normalized.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw PhotoFolderStoreError.duplicateName(normalized.name) }
            return normalized
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let folders: [PhotoFolder]
    }
}
