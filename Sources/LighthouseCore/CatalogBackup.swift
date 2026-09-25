import Foundation

/// 하루 한 번 카탈로그·폴더·프리셋을 `Backups/YYYY-MM-DD`에 남긴다. 자동 마스크 PNG는 카탈로그 안에 넣어
/// 그 폴더의 파일만으로 복원할 수 있게 한다. 최근 7일치만 남긴다.
public struct CatalogBackup: Sendable {
    public static let keptDays = 7
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL {
        CatalogStore.defaultURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    /// 오늘 보관본이 없으면 만들고 7일보다 오래된 보관본을 지운다. 만들었으면 true.
    /// 임시 폴더에 다 쓴 뒤 날짜 이름으로 옮기므로 중간에 멈춰도 반쯤 쓴 보관본이 남지 않는다.
    @discardableResult
    public func backUpIfNeeded(photos: [PhotoAsset], copying files: [URL], now: Date = Date()) throws -> Bool {
        let manager = FileManager.default
        let name = Self.folderName(for: now)
        let target = directory.appendingPathComponent(name, isDirectory: true)
        guard !manager.fileExists(atPath: target.path) else { return false }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(name)-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try CatalogStore.selfContainedData(photos).write(to: staging.appendingPathComponent("catalog.json"))
            for file in files where manager.fileExists(atPath: file.path) {
                try manager.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
            }
            try manager.moveItem(at: staging, to: target)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        prune()
        return true
    }

    /// 날짜 이름의 보관본 폴더. 최근 것부터.
    public func backups() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(Self.isDateName).sorted(by: >)
            .map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    /// 오래된 보관본과, 앱이 쓰는 도중 멈춰 남은 임시 폴더를 지운다. 날짜 이름이 아닌 폴더는 건드리지 않는다.
    private func prune() {
        let manager = FileManager.default
        for old in backups().dropFirst(Self.keptDays) { try? manager.removeItem(at: old) }
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".") && Self.isDateName(String(name.dropFirst().prefix(10))) {
            try? manager.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))
        }
    }

    public static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isDateName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.map(\.count) == [4, 2, 2] && parts.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) } }
    }
}
