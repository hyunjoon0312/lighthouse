import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 사진 썸네일을 `Thumbnails/<사진 ID>/<키>.jpg`로 보관한다(보정 여부와 관계없이 사진마다 최신 한 장).
/// 원본을 읽을 수 없을 때는 마지막으로 보관한 것을 보여 준다. 지워도 다시 만들 수 있는 캐시다.
public struct ThumbnailStore: Sendable {
    public let directory: URL

    public init(directory: URL = ThumbnailStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        CatalogStore.defaultURL.deletingLastPathComponent().appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// 원본 파일(경로·수정 시각·크기)과 보정값이 같을 때만 같은 키가 된다.
    public static func key(for photo: PhotoAsset) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: photo.path)
        guard let modified = attributes?[.modificationDate] as? Date,
              let size = attributes?[.size] as? NSNumber else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let edits = try? encoder.encode(photo.edits) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("v1|\(photo.path)|\(modified.timeIntervalSinceReferenceDate)|\(size)|".utf8))
        hasher.update(data: edits)
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func load(photoID: UUID, key: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file(photoID: photoID, key: key) as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 원본을 읽을 수 없어 키를 만들 수 없을 때 보여 줄, 그 사진의 마지막 썸네일.
    public func latest(photoID: UUID) -> CGImage? {
        let folder = directory.appendingPathComponent(photoID.uuidString, isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []).filter { $0.pathExtension == "jpg" }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard let newest = files.max(by: { modified($0) < modified($1) }),
              let source = CGImageSourceCreateWithURL(newest as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 새 썸네일을 저장하고 같은 사진의 이전 썸네일은 지운다.
    public func store(_ image: CGImage, photoID: UUID, key: String) {
        let folder = directory.appendingPathComponent(photoID.uuidString, isDirectory: true)
        let data = NSMutableData()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              (try? (data as Data).write(to: file(photoID: photoID, key: key), options: .atomic)) != nil else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name != key + ".jpg" {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// 카탈로그에서 뺀 항목의 썸네일을 지운다.
    public func remove(photoID: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(photoID.uuidString, isDirectory: true))
    }

    private func file(photoID: UUID, key: String) -> URL {
        directory.appendingPathComponent(photoID.uuidString, isDirectory: true)
            .appendingPathComponent(key + ".jpg")
    }
}
