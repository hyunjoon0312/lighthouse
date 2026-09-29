import CryptoKit
import Darwin
import Foundation

public struct LibraryArchiveFileRecord: Codable, Equatable, Sendable {
    public let relativePath: String
    public let size: Int64
    public let sha256: String

    public init(relativePath: String, size: Int64, sha256: String) {
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
    }
}

public struct LibraryArchiveOriginalRecord: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let relativePath: String

    public init(sourcePath: String, relativePath: String) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
    }
}

public struct LibraryArchiveSummary: Codable, Equatable, Sendable {
    public let version: Int
    public let createdAt: Date
    public let includesOriginals: Bool
    public let photoCount: Int
    public let files: [LibraryArchiveFileRecord]
    public let originals: [LibraryArchiveOriginalRecord]

    public init(version: Int = 1, createdAt: Date, includesOriginals: Bool, photoCount: Int,
                files: [LibraryArchiveFileRecord], originals: [LibraryArchiveOriginalRecord]) {
        self.version = version
        self.createdAt = createdAt
        self.includesOriginals = includesOriginals
        self.photoCount = photoCount
        self.files = files
        self.originals = originals
    }

    public var fileCount: Int { files.count }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum LibraryArchiveError: LocalizedError, Equatable {
    case sourceNotDirectory(String)
    case destinationExists(String)
    case overlappingPath(String)
    case missingCatalog
    case missingOriginal(String)
    case sourceChanged(String)
    case unsupportedVersion(Int)
    case damagedManifest
    case invalidRelativePath(String)
    case duplicatePath(String)
    case unexpectedFile(String)
    case symbolicLink(String)
    case specialFile(String)
    case damagedFile(String)
    case invalidOriginalMapping(String)
    case cancelled
    case cannotCreate(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotDirectory(let path): "라이브러리 폴더를 읽을 수 없습니다: \(path)"
        case .destinationExists(let path): "대상 폴더가 이미 있습니다: \(path)"
        case .overlappingPath(let path): "라이브러리·백업·원본과 겹치는 경로는 사용할 수 없습니다: \(path)"
        case .missingCatalog: "백업에 catalog.json이 없습니다."
        case .missingOriginal(let path): "원본 파일이 없어 전체 백업을 만들 수 없습니다: \(path)"
        case .sourceChanged(let path): "백업하는 동안 파일이 변경되었습니다: \(path)"
        case .unsupportedVersion(let version): "지원하지 않는 라이브러리 백업 버전 \(version)입니다."
        case .damagedManifest: "백업 manifest가 손상되었거나 형식이 올바르지 않습니다."
        case .invalidRelativePath(let path): "백업 내부 경로가 올바르지 않습니다: \(path)"
        case .duplicatePath(let path): "백업 내부 경로가 중복되거나 충돌합니다: \(path)"
        case .unexpectedFile(let path): "백업에 허용되지 않은 파일이 있습니다: \(path)"
        case .symbolicLink(let path): "백업에는 심볼릭 링크를 넣을 수 없습니다: \(path)"
        case .specialFile(let path): "백업에는 일반 파일과 폴더만 넣을 수 있습니다: \(path)"
        case .damagedFile(let path): "백업 파일이 변경되었거나 손상되었습니다: \(path)"
        case .invalidOriginalMapping(let path): "원본 경로 연결 정보가 올바르지 않습니다: \(path)"
        case .cancelled: "라이브러리 백업 또는 복원을 취소했습니다."
        case .cannotCreate(let path): "라이브러리 백업 또는 복원 폴더를 만들 수 없습니다: \(path)"
        }
    }
}

public enum LibraryArchive {
    private static let manifestName = "manifest.json"
    private static let fileNames: Set<String> = [
        "catalog.json", "folders.json", "smart-folders.json", "presets.json", "people.json"
    ]
    private static let directoryNames: Set<String> = ["LUTs", "Masks", "SmartPreviews"]

    public static func create(
        dataDirectory: URL,
        destination: URL,
        includeOriginals: Bool,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> LibraryArchiveSummary {
        let sourceRoot = try existingDirectory(dataDirectory)
        let target = try newDestination(destination)
        guard !pathsOverlap(sourceRoot, target) else { throw LibraryArchiveError.overlappingPath(target.path) }
        let photos = try CatalogStore(url: sourceRoot.appendingPathComponent("catalog.json")).load()
        guard FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("catalog.json").path) else {
            throw LibraryArchiveError.missingCatalog
        }
        let dataFiles = try libraryFiles(at: sourceRoot)
        var sourceOriginals: [(oldPath: String, canonical: URL, relativePath: String)] = []
        var originalByCanonical: [String: String] = [:]
        if includeOriginals {
            for photo in photos {
                let source = photo.url.standardizedFileURL.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw LibraryArchiveError.missingOriginal(photo.path)
                }
                guard !pathsOverlap(target, source) else { throw LibraryArchiveError.overlappingPath(target.path) }
                let relative: String
                if let existing = originalByCanonical[source.path] {
                    relative = existing
                } else {
                    let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension.lowercased()
                    relative = "OriginalFiles/\(UUID().uuidString.lowercased())\(suffix)"
                    originalByCanonical[source.path] = relative
                }
                if !sourceOriginals.contains(where: { $0.oldPath == photo.path }) {
                    sourceOriginals.append((photo.path, source, relative))
                }
            }
        }
        let uniqueOriginals = Dictionary(sourceOriginals.map { ($0.relativePath, $0.canonical) }, uniquingKeysWith: { first, _ in first })
        let total = dataFiles.count + uniqueOriginals.count
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            var records: [LibraryArchiveFileRecord] = []
            var completed = 0
            for source in dataFiles {
                try checkCancellation(isCancelled)
                let relative = relativePath(of: source, under: sourceRoot)
                let copied = try copyVerified(source, to: staging.appendingPathComponent(relative),
                                              relativePath: relative, isCancelled: isCancelled)
                records.append(copied)
                completed += 1
                progress(completed, total)
            }
            for (relative, source) in uniqueOriginals.sorted(by: { $0.key < $1.key }) {
                try checkCancellation(isCancelled)
                let copied = try copyVerified(source, to: staging.appendingPathComponent(relative),
                                              relativePath: relative, isCancelled: isCancelled)
                records.append(copied)
                completed += 1
                progress(completed, total)
            }
            let summary = LibraryArchiveSummary(
                createdAt: Date(), includesOriginals: includeOriginals, photoCount: photos.count,
                files: records.sorted { $0.relativePath < $1.relativePath },
                originals: sourceOriginals.map {
                    LibraryArchiveOriginalRecord(sourcePath: $0.oldPath, relativePath: $0.relativePath)
                }.sorted { $0.sourcePath < $1.sourcePath }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: staging.appendingPathComponent(manifestName), options: .atomic)
            _ = try inspect(at: staging, isCancelled: isCancelled)
            try checkCancellation(isCancelled)
            try publishExclusive(staging, to: target)
            return summary
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    public static func inspect(at archive: URL) throws -> LibraryArchiveSummary {
        try inspect(at: archive, isCancelled: { false })
    }

    private static func inspect(at archive: URL,
                                isCancelled: @Sendable () -> Bool) throws -> LibraryArchiveSummary {
        let root = try existingDirectory(archive)
        let manifestURL = root.appendingPathComponent(manifestName)
        let summary: LibraryArchiveSummary
        do {
            let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 16 * 1024 * 1024 else {
                throw LibraryArchiveError.damagedManifest
            }
            summary = try JSONDecoder().decode(LibraryArchiveSummary.self, from: Data(contentsOf: manifestURL))
        }
        catch { throw LibraryArchiveError.damagedManifest }
        guard summary.version == 1 else { throw LibraryArchiveError.unsupportedVersion(summary.version) }
        guard summary.createdAt.timeIntervalSinceReferenceDate.isFinite, summary.photoCount >= 0 else {
            throw LibraryArchiveError.damagedManifest
        }
        let records = try validatedRecords(summary.files, includesOriginals: summary.includesOriginals)
        let mappings = try validatedMappings(summary.originals, includesOriginals: summary.includesOriginals,
                                             filePaths: Set(records.keys))
        _ = mappings
        let actual = try archiveFiles(at: root)
        let listed = Set(records.keys)
        guard actual == listed else {
            let path = actual.subtracting(listed).first ?? listed.subtracting(actual).first ?? ""
            throw LibraryArchiveError.unexpectedFile(path)
        }
        guard listed.contains("catalog.json") else { throw LibraryArchiveError.missingCatalog }
        for (path, record) in records {
            try checkCancellation(isCancelled)
            let url = root.appendingPathComponent(path)
            let identity = try regularFileIdentity(url, relativePath: path, allowResolvedSymlink: false)
            guard identity.size == record.size,
                  try streamingSHA256(url, isCancelled: isCancelled) == record.sha256 else {
                throw LibraryArchiveError.damagedFile(path)
            }
        }
        let photos = try validateLibrary(at: root)
        guard photos.count == summary.photoCount else { throw LibraryArchiveError.damagedManifest }
        if summary.includesOriginals {
            let mapped = Set(summary.originals.map(\.sourcePath))
            guard photos.allSatisfy({ mapped.contains($0.path) }) else {
                throw LibraryArchiveError.invalidOriginalMapping("catalog.json")
            }
        } else if !summary.originals.isEmpty {
            throw LibraryArchiveError.invalidOriginalMapping("OriginalFiles")
        }
        return summary
    }

    public static func restore(
        from archive: URL,
        to destination: URL,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> URL {
        let archiveRoot = try existingDirectory(archive)
        let target = try newDestination(destination)
        guard !pathsOverlap(archiveRoot, target) else { throw LibraryArchiveError.overlappingPath(target.path) }
        let summary = try inspect(at: archiveRoot, isCancelled: isCancelled)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).restore-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            for (index, record) in summary.files.enumerated() {
                try checkCancellation(isCancelled)
                let source = archiveRoot.appendingPathComponent(record.relativePath)
                let copied = try copyVerified(source, to: staging.appendingPathComponent(record.relativePath),
                                              relativePath: record.relativePath, isCancelled: isCancelled)
                guard copied.size == record.size, copied.sha256 == record.sha256 else {
                    throw LibraryArchiveError.damagedFile(record.relativePath)
                }
                progress(index + 1, summary.files.count)
            }
            let remapping = try relocateRestoredOriginals(summary.originals, staging: staging,
                                                          finalRoot: target, isCancelled: isCancelled)
            try remapRestoredLibrary(staging: staging, finalRoot: target, mapping: remapping)
            try checkCancellation(isCancelled)
            _ = try validateLibrary(at: staging)
            try publishExclusive(staging, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func remapRestoredLibrary(
        staging: URL,
        finalRoot: URL,
        mapping: [String: (finalURL: URL, signatureURL: URL)]
    ) throws {
        let catalogStore = CatalogStore(url: staging.appendingPathComponent("catalog.json"))
        var photos = try catalogStore.load()
        for index in photos.indices {
            if let remap = mapping[photos[index].path] { photos[index].path = remap.finalURL.path }
            photos[index].lastExport = nil
        }
        try catalogStore.save(photos)

        let peopleURL = staging.appendingPathComponent("people.json")
        if FileManager.default.fileExists(atPath: peopleURL.path) {
            let store = PeopleStore(url: peopleURL)
            var catalog = try store.load()
            for index in catalog.analyses.indices {
                guard let remap = mapping[catalog.analyses[index].sourcePath] else { continue }
                let identity = try regularFileIdentity(remap.signatureURL,
                                                       relativePath: remap.signatureURL.lastPathComponent,
                                                       allowResolvedSymlink: false)
                catalog.analyses[index].sourcePath = remap.finalURL.path
                catalog.analyses[index].sourceSize = identity.size
                catalog.analyses[index].sourceModifiedAt = identity.modified
            }
            try store.save(catalog)
        }
        let previews = staging.appendingPathComponent("SmartPreviews", isDirectory: true)
        if FileManager.default.fileExists(atPath: previews.path) {
            try SmartPreviewStore(directory: previews).remapSources(mapping)
        }
        _ = finalRoot
    }

    private static func relocateRestoredOriginals(
        _ originals: [LibraryArchiveOriginalRecord],
        staging: URL,
        finalRoot: URL,
        isCancelled: @Sendable () -> Bool
    ) throws -> [String: (finalURL: URL, signatureURL: URL)] {
        var result: [String: (finalURL: URL, signatureURL: URL)] = [:]
        let groups = Dictionary(grouping: originals, by: \.relativePath)
        for relativePath in groups.keys.sorted() {
            try checkCancellation(isCancelled)
            guard let aliases = groups[relativePath]?.sorted(by: { $0.sourcePath < $1.sourcePath }),
                  let selected = aliases.first else { continue }
            let basename = URL(fileURLWithPath: selected.sourcePath).lastPathComponent
            let basenameParts = basename.split(separator: "/", omittingEmptySubsequences: false)
            guard basenameParts.count == 1, validRelativePath(basename) else {
                throw LibraryArchiveError.invalidOriginalMapping(selected.sourcePath)
            }
            let archiveName = URL(fileURLWithPath: relativePath).lastPathComponent
            let archiveStem = URL(fileURLWithPath: archiveName).deletingPathExtension().lastPathComponent
            guard UUID(uuidString: archiveStem) != nil else {
                throw LibraryArchiveError.invalidOriginalMapping(relativePath)
            }
            let relocatedRelative = "OriginalFiles/\(archiveStem.lowercased())/\(basename)"
            let source = staging.appendingPathComponent(relativePath)
            let signatureURL = staging.appendingPathComponent(relocatedRelative)
            let finalURL = finalRoot.appendingPathComponent(relocatedRelative)
            guard !FileManager.default.fileExists(atPath: signatureURL.path) else {
                throw LibraryArchiveError.invalidOriginalMapping(relocatedRelative)
            }
            do {
                try FileManager.default.createDirectory(at: signatureURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: false)
                try FileManager.default.moveItem(at: source, to: signatureURL)
            } catch {
                throw LibraryArchiveError.cannotCreate(signatureURL.path)
            }
            for alias in aliases {
                guard result.updateValue((finalURL, signatureURL), forKey: alias.sourcePath) == nil else {
                    throw LibraryArchiveError.invalidOriginalMapping(alias.sourcePath)
                }
            }
        }
        return result
    }

    @discardableResult
    private static func validateLibrary(at root: URL) throws -> [PhotoAsset] {
        let catalog = CatalogStore(url: root.appendingPathComponent("catalog.json"))
        let photos = try catalog.load()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("folders.json").path) {
            _ = try PhotoFolderStore(url: root.appendingPathComponent("folders.json")).load()
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("smart-folders.json").path) {
            _ = try SmartFolderStore(url: root.appendingPathComponent("smart-folders.json")).load()
        }
        var presets: [EditPreset] = []
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("presets.json").path) {
            presets = try EditPresetStore(url: root.appendingPathComponent("presets.json")).load()
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("people.json").path) {
            _ = try PeopleStore(url: root.appendingPathComponent("people.json")).load()
        }
        let previewDirectory = root.appendingPathComponent("SmartPreviews", isDirectory: true)
        if FileManager.default.fileExists(atPath: previewDirectory.path) {
            _ = try SmartPreviewStore(directory: previewDirectory).validatedRecords()
        }
        let lutDirectory = root.appendingPathComponent("LUTs", isDirectory: true)
        try validateLUTSidecars(at: lutDirectory)
        let store = LUTStore(directory: lutDirectory)
        if FileManager.default.fileExists(atPath: lutDirectory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: lutDirectory, includingPropertiesForKeys: nil)
                where url.pathExtension.lowercased() == "cube" {
                let id = url.deletingPathExtension().lastPathComponent
                guard validDigest(id) else { throw LibraryArchiveError.damagedFile(relativePathForLUT(url)) }
                _ = try store.load(id: id)
            }
        }
        let edits = photos.flatMap { [$0.edits] + $0.snapshots.map(\.edits) } + presets.map(\.settings)
        for id in Set(edits.compactMap { $0.lut?.id }) { _ = try store.load(id: id) }
        return photos
    }

    private static func validateLUTSidecars(at directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        struct Sidecar: Decodable { let version: Int; let id: String; let name: String }
        for url in files {
            let ext = url.pathExtension.lowercased()
            guard ext == "json" || ext == "cube" else {
                throw LibraryArchiveError.unexpectedFile(relativePathForLUT(url))
            }
            guard ext == "json" else { continue }
            let expectedID = url.deletingPathExtension().lastPathComponent
            let sidecar: Sidecar
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= 64 * 1024 else {
                    throw LibraryArchiveError.damagedFile(relativePathForLUT(url))
                }
                sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
            }
            catch { throw LibraryArchiveError.damagedFile(relativePathForLUT(url)) }
            let name = sidecar.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sidecar.version == 1, sidecar.id == expectedID, validDigest(sidecar.id),
                  !name.isEmpty,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(expectedID + ".cube").path) else {
                throw LibraryArchiveError.damagedFile(relativePathForLUT(url))
            }
        }
    }

    private static func relativePathForLUT(_ url: URL) -> String { "LUTs/" + url.lastPathComponent }

    private static func libraryFiles(at root: URL) throws -> [URL] {
        var result: [URL] = []
        for name in fileNames {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try regularFileIdentity(url, relativePath: name, allowResolvedSymlink: false)
                result.append(url)
            }
        }
        guard result.contains(where: { $0.lastPathComponent == "catalog.json" }) else {
            throw LibraryArchiveError.missingCatalog
        }
        for name in directoryNames {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            result.append(contentsOf: try regularFilesRecursively(at: directory, root: root)
                .filter { $0.lastPathComponent != ".DS_Store" })
        }
        return result.sorted { relativePath(of: $0, under: root) < relativePath(of: $1, under: root) }
    }

    private static func archiveFiles(at root: URL) throws -> Set<String> {
        var result = Set<String>()
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        for child in children {
            let name = child.lastPathComponent
            if name == manifestName || name == ".DS_Store" { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw LibraryArchiveError.symbolicLink(name) }
            if values.isDirectory == true {
                guard directoryNames.contains(name) || name == "OriginalFiles" else {
                    throw LibraryArchiveError.unexpectedFile(name)
                }
                for url in try regularFilesRecursively(at: child, root: root)
                    where url.lastPathComponent != ".DS_Store" {
                    result.insert(relativePath(of: url, under: root))
                }
            } else if values.isRegularFile == true, fileNames.contains(name) {
                result.insert(name)
            } else {
                throw LibraryArchiveError.unexpectedFile(name)
            }
        }
        return result
    }

    private static func regularFilesRecursively(at directory: URL, root: URL) throws -> [URL] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw LibraryArchiveError.symbolicLink(relativePath(of: directory, under: root)) }
        guard values.isDirectory == true else { throw LibraryArchiveError.specialFile(relativePath(of: directory, under: root)) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
            throw LibraryArchiveError.sourceNotDirectory(directory.path)
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let relative = relativePath(of: url, under: root)
            let value = try url.resourceValues(forKeys: Set(keys))
            if value.isSymbolicLink == true { throw LibraryArchiveError.symbolicLink(relative) }
            if value.isDirectory == true { throw LibraryArchiveError.unexpectedFile(relative) }
            guard value.isRegularFile == true else { throw LibraryArchiveError.specialFile(relative) }
            files.append(url)
        }
        if enumerationError != nil { throw LibraryArchiveError.sourceNotDirectory(directory.path) }
        return files
    }

    private static func validatedRecords(
        _ files: [LibraryArchiveFileRecord], includesOriginals: Bool
    ) throws -> [String: LibraryArchiveFileRecord] {
        var records: [String: LibraryArchiveFileRecord] = [:]
        var normalizedPaths: [String: String] = [:]
        for record in files {
            guard validRelativePath(record.relativePath), allowedArchivePath(record.relativePath),
                  record.relativePath != manifestName, record.size >= 0, validDigest(record.sha256),
                  includesOriginals || !record.relativePath.hasPrefix("OriginalFiles/"),
                  !record.relativePath.hasPrefix("OriginalFiles/") || validArchivedOriginalPath(record.relativePath) else {
                throw LibraryArchiveError.invalidRelativePath(record.relativePath)
            }
            guard records.updateValue(record, forKey: record.relativePath) == nil else {
                throw LibraryArchiveError.duplicatePath(record.relativePath)
            }
            let normalized = normalizedPathKey(record.relativePath)
            guard normalizedPaths.updateValue(record.relativePath, forKey: normalized) == nil else {
                throw LibraryArchiveError.duplicatePath(record.relativePath)
            }
        }
        let keys = Set(normalizedPaths.keys)
        for path in keys {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 1 else { continue }
            for length in 1..<components.count {
                let prefix = components.prefix(length).joined(separator: "/")
                if keys.contains(prefix) {
                    throw LibraryArchiveError.duplicatePath(normalizedPaths[prefix] ?? prefix)
                }
            }
        }
        return records
    }

    private static func validatedMappings(
        _ mappings: [LibraryArchiveOriginalRecord], includesOriginals: Bool, filePaths: Set<String>
    ) throws -> [String: String] {
        guard includesOriginals || mappings.isEmpty else {
            throw LibraryArchiveError.invalidOriginalMapping("OriginalFiles")
        }
        var result: [String: String] = [:]
        for mapping in mappings {
            guard !mapping.sourcePath.isEmpty, !mapping.sourcePath.contains("\0"),
                  NSString(string: mapping.sourcePath).isAbsolutePath,
                  validArchivedOriginalPath(mapping.relativePath),
                  filePaths.contains(mapping.relativePath),
                  result.updateValue(mapping.relativePath, forKey: mapping.sourcePath) == nil else {
                throw LibraryArchiveError.invalidOriginalMapping(mapping.sourcePath)
            }
        }
        return result
    }

    private static func allowedArchivePath(_ path: String) -> Bool {
        if fileNames.contains(path) { return true }
        guard let first = path.split(separator: "/", omittingEmptySubsequences: false).first else { return false }
        return directoryNames.contains(String(first)) || (first == "OriginalFiles" && path.hasPrefix("OriginalFiles/"))
    }

    private static func validArchivedOriginalPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "OriginalFiles" else { return false }
        let filename = String(parts[1])
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return validRelativePath(path) && UUID(uuidString: stem) != nil
    }

    private static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("\0"), !NSString(string: path).isAbsolutePath,
              !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func copyVerified(_ source: URL, to destination: URL,
                                     relativePath: String,
                                     isCancelled: @Sendable () -> Bool) throws -> LibraryArchiveFileRecord {
        let before = try regularFileIdentity(source, relativePath: relativePath, allowResolvedSymlink: false)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { throw LibraryArchiveError.cannotCreate(destination.path) }
        let after = try regularFileIdentity(source, relativePath: relativePath, allowResolvedSymlink: false)
        guard before == after else { throw LibraryArchiveError.sourceChanged(source.path) }
        let copied = try regularFileIdentity(destination, relativePath: relativePath, allowResolvedSymlink: false)
        guard copied.size == before.size else { throw LibraryArchiveError.damagedFile(relativePath) }
        return LibraryArchiveFileRecord(relativePath: relativePath, size: copied.size,
                                        sha256: try streamingSHA256(destination, isCancelled: isCancelled))
    }

    private static func regularFileIdentity(_ url: URL, relativePath: String,
                                            allowResolvedSymlink: Bool) throws -> FileIdentity {
        let input = allowResolvedSymlink ? url.resolvingSymlinksInPath() : url
        do {
            let value = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                           .fileSizeKey, .contentModificationDateKey])
            if !allowResolvedSymlink && value.isSymbolicLink == true { throw LibraryArchiveError.symbolicLink(relativePath) }
            guard value.isRegularFile == true, let size = value.fileSize, let modified = value.contentModificationDate else {
                throw LibraryArchiveError.specialFile(relativePath)
            }
            return FileIdentity(size: Int64(size), modified: modified)
        } catch let error as LibraryArchiveError { throw error }
        catch { throw LibraryArchiveError.damagedFile(relativePath) }
    }

    private static func streamingSHA256(_ url: URL,
                                        isCancelled: @Sendable () -> Bool) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw LibraryArchiveError.damagedFile(url.lastPathComponent) }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try checkCancellation(isCancelled)
                hasher.update(data: data)
            }
        } catch let error as LibraryArchiveError { throw error }
        catch { throw LibraryArchiveError.damagedFile(url.lastPathComponent) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func existingDirectory(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        do {
            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LibraryArchiveError.sourceNotDirectory(standardized.path)
            }
            return standardized.resolvingSymlinksInPath()
        } catch let error as LibraryArchiveError { throw error }
        catch { throw LibraryArchiveError.sourceNotDirectory(standardized.path) }
    }

    private static func newDestination(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: standardized.path) else {
            throw LibraryArchiveError.destinationExists(standardized.path)
        }
        let parent = try existingDirectory(standardized.deletingLastPathComponent())
        return parent.appendingPathComponent(standardized.lastPathComponent)
    }

    private static func pathsOverlap(_ left: URL, _ right: URL) -> Bool {
        let leftPath = left.standardizedFileURL.path
        let rightPath = right.standardizedFileURL.path
        return leftPath == rightPath || leftPath.hasPrefix(rightPath + "/") || rightPath.hasPrefix(leftPath + "/")
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw LibraryArchiveError.cancelled }
    }

    private static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func normalizedPathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func publishExclusive(_ staging: URL, to destination: URL) throws {
        let result = staging.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(EINVAL) }
                return renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        guard result == 0 else {
            if result == EEXIST { throw LibraryArchiveError.destinationExists(destination.path) }
            throw LibraryArchiveError.cannotCreate(destination.path)
        }
    }

    private struct FileIdentity: Equatable {
        let size: Int64
        let modified: Date
    }
}
