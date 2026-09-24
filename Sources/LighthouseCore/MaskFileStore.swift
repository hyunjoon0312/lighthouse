import CryptoKit
import Foundation

public extension CodingUserInfoKey {
    /// 이 값이 있으면 `RasterMask`는 PNG 대신 내용 해시만 JSON에 쓰고, 해시로 이 폴더의 파일을 읽는다.
    static let rasterMaskDirectory = CodingUserInfoKey(rawValue: "com.rian.lighthouse.rasterMaskDirectory")!
}

/// 자동 마스크 PNG를 카탈로그 옆 `Masks` 폴더에 내용 해시 이름으로 보관한다.
struct MaskFileStore {
    let directory: URL

    static func contentID(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load(id: String) throws -> Data {
        guard Self.validID(id) else { throw CatalogError.damagedMask(id) }
        let url = file(for: id)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            throw CatalogError.missingMask(id)
        }
        guard size.intValue <= ImagePipeline.maximumMaskBytes,
              let data = try? Data(contentsOf: url), Self.contentID(data) == id else {
            throw CatalogError.damagedMask(id)
        }
        return data
    }

    /// 없는 파일만 쓰고, 카탈로그가 참조하는 모든 해시를 돌려준다.
    func write(_ masks: [RasterMask]) throws -> Set<String> {
        var referenced = Set<String>()
        for mask in masks {
            let id = Self.contentID(mask.pngData)
            guard referenced.insert(id).inserted else { continue }
            let url = file(for: id)
            let existing = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            if existing?.intValue == mask.pngData.count { continue }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try mask.pngData.write(to: url, options: .atomic)
        }
        return referenced
    }

    func removeFiles(notIn referenced: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".png") {
            let id = String(name.dropLast(4))
            guard Self.validID(id), !referenced.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file(for: id))
        }
    }

    private func file(for id: String) -> URL {
        directory.appendingPathComponent(id + ".png")
    }

    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
