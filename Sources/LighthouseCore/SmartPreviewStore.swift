import CryptoKit
import Foundation
import ImageIO

public struct SmartPreviewRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let photoID: UUID
    public let sourcePath: String
    public let sourceSize: Int64
    public let sourceModifiedAt: Date
    public let width: Int
    public let height: Int
    public let previewSHA256: String
    public let generation: UUID

    public init(version: Int = 1, photoID: UUID, sourcePath: String, sourceSize: Int64,
                sourceModifiedAt: Date, width: Int, height: Int, previewSHA256: String,
                generation: UUID) {
        self.version = version
        self.photoID = photoID
        self.sourcePath = sourcePath
        self.sourceSize = sourceSize
        self.sourceModifiedAt = sourceModifiedAt
        self.width = width
        self.height = height
        self.previewSHA256 = previewSHA256
        self.generation = generation
    }
}

public enum SmartPreviewStoreError: LocalizedError, Equatable {
    case sourceMissing(String)
    case sourceChanged(String)
    case unreadableSource(String)
    case damagedRecord(UUID)
    case unsupportedVersion(Int)
    case invalidGeneration(UUID)
    case missingPreview(UUID)
    case damagedPreview(UUID)
    case cannotSave

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): "스마트 미리보기를 만들 원본이 없습니다: \(path)"
        case .sourceChanged(let path): "스마트 미리보기를 만드는 동안 원본이 변경되었습니다: \(path)"
        case .unreadableSource(let path): "원본 파일 정보를 읽을 수 없습니다: \(path)"
        case .damagedRecord(let id): "스마트 미리보기 기록이 손상되었습니다: \(id.uuidString)"
        case .unsupportedVersion(let version): "지원하지 않는 스마트 미리보기 버전 \(version)입니다."
        case .invalidGeneration(let id): "스마트 미리보기 세대가 올바르지 않습니다: \(id.uuidString)"
        case .missingPreview(let id): "스마트 미리보기 파일이 없습니다: \(id.uuidString)"
        case .damagedPreview(let id): "스마트 미리보기 파일이 손상되었습니다: \(id.uuidString)"
        case .cannotSave: "스마트 미리보기를 저장할 수 없습니다."
        }
    }
}

public struct SmartPreviewStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL {
        CatalogStore.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("SmartPreviews", isDirectory: true)
    }

    public func create(for photo: PhotoAsset, pipeline: ImagePipeline) throws -> SmartPreviewRecord {
        let source = photo.url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SmartPreviewStoreError.sourceMissing(source.path)
        }
        let before = try Self.sourceIdentity(source)
        let data = try pipeline.makeSmartPreview(url: source, maxPixel: 2560)
        let after = try Self.sourceIdentity(source)
        guard before == after else { throw SmartPreviewStoreError.sourceChanged(source.path) }
        let dimensions = try Self.tiffDimensions(data, photoID: photo.id)
        let generation = UUID()
        let record = SmartPreviewRecord(photoID: photo.id, sourcePath: photo.path,
                                        sourceSize: before.size, sourceModifiedAt: before.modified,
                                        width: dimensions.width, height: dimensions.height,
                                        previewSHA256: Self.sha256(data), generation: generation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = previewURL(photoID: photo.id, generation: generation)
        let recordURL = self.recordURL(photoID: photo.id)
        let oldRecord = try? decodedRecord(at: recordURL, expectedPhotoID: photo.id)
        do {
            try data.write(to: preview, options: .atomic)
            _ = try Self.validatedPreview(at: preview, record: record)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: recordURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: preview)
            if let error = error as? SmartPreviewStoreError { throw error }
            throw SmartPreviewStoreError.cannotSave
        }
        if let oldRecord, oldRecord.generation != generation {
            try? FileManager.default.removeItem(at: previewURL(photoID: photo.id, generation: oldRecord.generation))
        }
        return record
    }

    public func record(for photo: PhotoAsset) throws -> SmartPreviewRecord? {
        let url = recordURL(photoID: photo.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try decodedRecord(at: url, expectedPhotoID: photo.id)
        guard record.sourcePath == photo.path else { return nil }
        if FileManager.default.fileExists(atPath: photo.path) {
            let current = try Self.sourceIdentity(photo.url)
            guard current.size == record.sourceSize, current.modified == record.sourceModifiedAt else { return nil }
        }
        _ = try Self.validatedPreview(at: previewURL(photoID: photo.id, generation: record.generation), record: record)
        return record
    }

    public func previewURL(for photo: PhotoAsset) throws -> URL? {
        guard let record = try record(for: photo) else { return nil }
        return previewURL(photoID: photo.id, generation: record.generation)
    }

    public func remove(for photo: PhotoAsset) throws {
        let url = recordURL(photoID: photo.id)
        let record = try? decodedRecord(at: url, expectedPhotoID: photo.id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if let record {
            let preview = previewURL(photoID: photo.id, generation: record.generation)
            if FileManager.default.fileExists(atPath: preview.path) { try FileManager.default.removeItem(at: preview) }
        }
    }

    public static func previewEdits(_ edits: EditSettings) -> EditSettings {
        var result = edits
        result.noiseReduction = NoiseReductionSettings()
        result.flicker = FlickerSettings()
        result.rawDevelop = RAWDevelopSettings()
        result.hdrAmount = 0
        result.sharpness = 0
        result.grain = GrainSettings()
        result.retouchStrokes = []
        for index in result.localAdjustments.indices {
            result.localAdjustments[index].noiseReduction = NoiseReductionSettings()
        }
        return result
    }

    func validatedRecords() throws -> [SmartPreviewRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let json = urls.filter { $0.pathExtension.lowercased() == "json" }
        var records: [SmartPreviewRecord] = []
        var expectedFiles = Set(json.map(\.lastPathComponent))
        for url in json {
            guard let photoID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                throw SmartPreviewStoreError.damagedRecord(UUID())
            }
            let record = try decodedRecord(at: url, expectedPhotoID: photoID)
            let preview = previewURL(photoID: photoID, generation: record.generation)
            _ = try Self.validatedPreview(at: preview, record: record)
            expectedFiles.insert(preview.lastPathComponent)
            records.append(record)
        }
        let actual = Set(urls.map(\.lastPathComponent))
        guard actual == expectedFiles else { throw SmartPreviewStoreError.cannotSave }
        return records
    }

    func remapSources(_ mapping: [String: (finalURL: URL, signatureURL: URL)]) throws {
        let records = try validatedRecords()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for record in records {
            guard let remap = mapping[record.sourcePath] else { continue }
            let identity = try Self.sourceIdentity(remap.signatureURL)
            let updated = SmartPreviewRecord(photoID: record.photoID, sourcePath: remap.finalURL.path,
                                             sourceSize: identity.size, sourceModifiedAt: identity.modified,
                                             width: record.width, height: record.height,
                                             previewSHA256: record.previewSHA256, generation: record.generation)
            try encoder.encode(updated).write(to: recordURL(photoID: record.photoID), options: .atomic)
        }
    }

    private func recordURL(photoID: UUID) -> URL {
        directory.appendingPathComponent(photoID.uuidString.lowercased() + ".json")
    }

    private func previewURL(photoID: UUID, generation: UUID) -> URL {
        directory.appendingPathComponent(photoID.uuidString.lowercased() + "-" + generation.uuidString.lowercased() + ".tiff")
    }

    private func decodedRecord(at url: URL, expectedPhotoID: UUID) throws -> SmartPreviewRecord {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
              let size = values?.fileSize, size <= 64 * 1024 else {
            throw SmartPreviewStoreError.damagedRecord(expectedPhotoID)
        }
        let record: SmartPreviewRecord
        do { record = try JSONDecoder().decode(SmartPreviewRecord.self, from: Data(contentsOf: url)) }
        catch { throw SmartPreviewStoreError.damagedRecord(expectedPhotoID) }
        guard record.version == 1 else { throw SmartPreviewStoreError.unsupportedVersion(record.version) }
        guard record.photoID == expectedPhotoID, !record.sourcePath.isEmpty,
              record.sourceSize >= 0, record.sourceModifiedAt.timeIntervalSinceReferenceDate.isFinite,
              record.width > 0, record.height > 0, Self.validDigest(record.previewSHA256) else {
            throw SmartPreviewStoreError.damagedRecord(expectedPhotoID)
        }
        return record
    }

    private static func validatedPreview(at url: URL, record: SmartPreviewRecord) throws -> (width: Int, height: Int) {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw SmartPreviewStoreError.missingPreview(record.photoID)
        }
        guard let size = values?.fileSize, size <= 64 * 1024 * 1024 else {
            throw SmartPreviewStoreError.damagedPreview(record.photoID)
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw SmartPreviewStoreError.missingPreview(record.photoID) }
        guard sha256(data) == record.previewSHA256 else {
            throw SmartPreviewStoreError.damagedPreview(record.photoID)
        }
        let dimensions = try tiffDimensions(data, photoID: record.photoID)
        guard dimensions.width == record.width, dimensions.height == record.height else {
            throw SmartPreviewStoreError.damagedPreview(record.photoID)
        }
        return dimensions
    }

    private static func tiffDimensions(_ data: Data, photoID: UUID) throws -> (width: Int, height: Int) {
        guard data.count <= 64 * 1024 * 1024 else { throw SmartPreviewStoreError.damagedPreview(photoID) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == "public.tiff" as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, max(width, height) <= 2560,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.bitsPerComponent == 16 else {
            throw SmartPreviewStoreError.damagedPreview(photoID)
        }
        return (width, height)
    }

    private static func sourceIdentity(_ url: URL) throws -> (size: Int64, modified: Date) {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else {
                throw SmartPreviewStoreError.unreadableSource(url.path)
            }
            return (Int64(size), modified)
        } catch let error as SmartPreviewStoreError { throw error }
        catch { throw SmartPreviewStoreError.unreadableSource(url.path) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
