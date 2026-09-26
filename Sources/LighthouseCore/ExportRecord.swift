import CryptoKit
import Foundation

/// 사진을 마지막으로 내보낸 기록. 그 뒤로 보정·키워드·설명이 바뀐 사진만 같은 설정·폴더로 다시 내보낼 때 쓴다.
public struct ExportRecord: Codable, Equatable, Sendable {
    public var exportedAt: Date
    /// 쓴 파일 경로.
    public var path: String
    /// 번호 접미사(-2 등)를 붙이기 전 이름. 다시 내보낼 때 같은 이름으로 쓴다.
    public var baseName: String
    public var options: ExportOptions
    /// 내보낼 때의 보정·키워드·설명 요약. 지금 값과 다르면 다시 내보낼 대상이다.
    public var digest: String
    /// 쓴 파일의 크기와 수정 시각. 앱이 쓴 그대로일 때만 휴지통으로 옮기기 위해 둔다.
    public var fileSize: Int
    public var fileModified: Date

    public init(exportedAt: Date, path: String, baseName: String, options: ExportOptions, digest: String,
                fileSize: Int, fileModified: Date) {
        self.exportedAt = exportedAt
        self.path = path
        self.baseName = baseName
        self.options = options
        self.digest = digest
        self.fileSize = fileSize
        self.fileModified = fileModified
    }

    /// 방금 쓴 `file`의 기록. 파일 속성을 읽지 못하면 nil이다.
    public static func make(photo: PhotoAsset, file: URL, baseName: String, options: ExportOptions,
                            exportedAt: Date = Date()) -> ExportRecord? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return ExportRecord(exportedAt: exportedAt, path: file.path, baseName: baseName, options: options,
                            digest: digest(of: photo), fileSize: size, fileModified: modified)
    }

    /// 파일 내용에 들어가는 값(보정·키워드·설명)의 요약. 별점·라벨은 파일에 들어가지 않아 빼고,
    /// 자동 마스크는 PNG 대신 내용 해시로 센다.
    public static func digest(of photo: PhotoAsset) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.userInfo[.rasterMaskDirectory] = URL(fileURLWithPath: "/", isDirectory: true)
        let data = (try? encoder.encode(Content(edits: photo.edits, keywords: photo.keywords, caption: photo.caption))) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func isChanged(_ photo: PhotoAsset) -> Bool { Self.digest(of: photo) != digest }

    /// 쓴 파일이 그 자리에 앱이 쓴 그대로(크기·수정 시각) 남아 있는지.
    public var fileIsUntouched: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return false }
        return size == fileSize && abs(modified.timeIntervalSince(fileModified)) < 0.001
    }

    private struct Content: Encodable {
        let edits: EditSettings
        let keywords: [String]
        let caption: String
    }
}
