import CryptoKit
import Foundation

public enum PhotoCopyError: LocalizedError {
    case cannotCopy(URL, String)
    case verificationFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotCopy(let url, let reason): "\(url.lastPathComponent)을 복사할 수 없습니다: \(reason)"
        case .verificationFailed(let url): "\(url.lastPathComponent)의 복사본 크기가 원본과 다릅니다."
        }
    }
}

public enum PhotoCopyResult: Equatable, Sendable {
    case copied(URL)
    case alreadyPresent(URL)

    public var url: URL {
        switch self {
        case .copied(let url), .alreadyPresent(let url): url
        }
    }
}

/// 카드의 사진을 사진 보관 폴더로 복사한다. 원본은 읽기만 하고 이동·삭제하지 않는다.
public enum PhotoCopier {
    /// `root/연도/연-월-일`. 날짜가 없으면 `root` 바로 아래에 둔다.
    public static func folder(for captureDate: Date?, in root: URL, organizeByDate: Bool,
                              calendar: Calendar = .current) -> URL {
        guard organizeByDate, let captureDate else { return root }
        let parts = calendar.dateComponents([.year, .month, .day], from: captureDate)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return root }
        return root.appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%04d-%02d-%02d", year, month, day), isDirectory: true)
    }

    /// 같은 이름이 있으면 내용이 같을 때 기존 파일을 쓰고, 다르면 `-2`, `-3`을 붙인다.
    /// 임시 이름으로 복사한 뒤 이름을 바꾸므로 중간에 실패해도 반쯤 복사된 사진 파일이 남지 않는다.
    public static func copy(_ source: URL, into folder: URL) throws -> PhotoCopyResult {
        let manager = FileManager.default
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw PhotoCopyError.cannotCopy(source, error.localizedDescription) }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for number in 1...10_000 {
            let name = number == 1 ? source.lastPathComponent : "\(stem)-\(number)" + (ext.isEmpty ? "" : ".\(ext)")
            let destination = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) {
                if try sameContents(source, destination) { return .alreadyPresent(destination) }
                continue
            }
            let partial = folder.appendingPathComponent(".\(UUID().uuidString).lighthouse-part")
            do {
                try manager.copyItem(at: source, to: partial)
                guard size(of: partial) == size(of: source) else { throw PhotoCopyError.verificationFailed(source) }
                try manager.moveItem(at: partial, to: destination)
                return .copied(destination)
            } catch let error as PhotoCopyError {
                try? manager.removeItem(at: partial)
                throw error
            } catch {
                try? manager.removeItem(at: partial)
                if manager.fileExists(atPath: destination.path) { continue }
                throw PhotoCopyError.cannotCopy(source, error.localizedDescription)
            }
        }
        throw PhotoCopyError.cannotCopy(source, "같은 이름의 파일이 너무 많습니다")
    }

    private static func size(of url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
    }

    private static func sameContents(_ first: URL, _ second: URL) throws -> Bool {
        guard let firstSize = size(of: first), firstSize == size(of: second) else { return false }
        return try digest(first) == digest(second)
    }

    private static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}
