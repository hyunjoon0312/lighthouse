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

    public var maskDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent("Masks", isDirectory: true)
    }

    public func load() throws -> [PhotoAsset] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.rasterMaskDirectory] = maskDirectory
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw CatalogError.unsupportedVersion(envelope.version) }
        return envelope.photos
    }

    /// 마스크 파일을 먼저 쓰고 카탈로그를 교체한다. 카탈로그가 없는 파일을 가리키는 순간이 생기지 않는다.
    public func save(_ photos: [PhotoAsset]) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let masks = MaskFileStore(directory: maskDirectory)
        let referenced = try masks.write(photos.flatMap { $0.edits.localAdjustments.compactMap(\.baseMask) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.userInfo[.rasterMaskDirectory] = maskDirectory
        try encoder.encode(Envelope(version: 1, photos: photos)).write(to: url, options: .atomic)
        masks.removeFiles(notIn: referenced)
    }

    private struct Envelope: Codable {
        let version: Int
        let photos: [PhotoAsset]
    }
}

public enum CatalogError: LocalizedError {
    case unsupportedVersion(Int)
    case missingMask(String)
    case damagedMask(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "지원하지 않는 카탈로그 버전 \(version)입니다."
        case .missingMask(let id): "자동 마스크 파일을 찾을 수 없습니다: Masks/\(id).png"
        case .damagedMask(let id): "자동 마스크 파일이 변경되었거나 손상되었습니다: Masks/\(id).png"
        }
    }
}
