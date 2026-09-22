import Foundation

public struct CatalogStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        if let directory = ProcessInfo.processInfo.environment["LIGHTHOUSE_DATA_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("catalog.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lighthouse", isDirectory: true).appendingPathComponent("catalog.json")
    }

    public func load() throws -> [PhotoAsset] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw CatalogError.unsupportedVersion(envelope.version) }
        return envelope.photos
    }

    public func save(_ photos: [PhotoAsset]) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(version: 1, photos: photos)).write(to: url, options: .atomic)
    }

    private struct Envelope: Codable {
        let version: Int
        let photos: [PhotoAsset]
    }
}

public enum CatalogError: LocalizedError {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "지원하지 않는 카탈로그 버전 \(version)입니다."
        }
    }
}
