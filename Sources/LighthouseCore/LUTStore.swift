import CryptoKit
import Foundation

public enum LUTStoreError: LocalizedError {
    case unsupportedExtension
    case invalidID
    case missing(String)
    case damaged(String)
    case cannotSave(URL)
    case cannotRead(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedExtension: "3D .cube LUT 파일만 불러올 수 있습니다."
        case .invalidID: "LUT 식별자가 올바르지 않습니다."
        case .missing(let id): "LUT 파일을 찾을 수 없습니다: \(id)"
        case .damaged(let id): "LUT 파일의 내용이 변경되었거나 손상되었습니다: \(id)"
        case .cannotSave(let url): "LUT 파일을 저장할 수 없습니다: \(url.path)"
        case .cannotRead(let url): "LUT 파일을 읽을 수 없습니다: \(url.path)"
        }
    }
}

public struct LUTLibraryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let error: String?

    public init(id: String, name: String, error: String? = nil) {
        self.id = id
        self.name = name
        self.error = error
    }
}

public struct LUTStore: Sendable {
    public let directory: URL
    private static let cubeCache: NSCache<NSString, CachedCube> = {
        let cache = NSCache<NSString, CachedCube>()
        cache.countLimit = 8
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    public init(directory: URL = LUTStore.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        CatalogStore.defaultURL.deletingLastPathComponent().appendingPathComponent("LUTs", isDirectory: true)
    }

    public func importCube(from url: URL) throws -> LUTAdjustment {
        guard url.pathExtension.lowercased() == "cube" else { throw LUTStoreError.unsupportedExtension }
        let data: Data
        do { data = try Self.readBounded(url) }
        catch let error as CubeLUTError { throw error }
        catch { throw LUTStoreError.cannotRead(url) }
        let cube = try CubeLUT.parse(data)
        let id = Self.sha256(data)
        let destination = directory.appendingPathComponent(id + ".cube")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                let current = try? Self.readBounded(destination)
                if current.map(Self.sha256) != id {
                    try data.write(to: destination, options: .atomic)
                }
            } else {
                try data.write(to: destination, options: .atomic)
            }
        } catch let error as LUTStoreError {
            throw error
        } catch {
            throw LUTStoreError.cannotSave(destination)
        }
        Self.cubeCache.setObject(CachedCube(cube), forKey: id as NSString, cost: cube.cubeData.count)
        let sidecarURL = directory.appendingPathComponent(id + ".json")
        let name: String
        if let saved = Self.readSidecar(at: sidecarURL, id: id) {
            name = saved
        } else {
            let title = cube.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            name = title.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
            let sidecar = NameSidecar(version: 1, id: id, name: name)
            do { try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: .atomic) }
            catch { throw LUTStoreError.cannotSave(sidecarURL) }
        }
        return LUTAdjustment(id: id, name: name)
    }

    public func library(knownNames: [String: String] = [:]) throws -> [LUTLibraryItem] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw LUTStoreError.cannotRead(directory) }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles])
        } catch { throw LUTStoreError.cannotRead(directory) }
        var items: [LUTLibraryItem] = []
        for file in files {
            guard file.pathExtension.lowercased() == "cube", !file.lastPathComponent.hasPrefix(".") else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            guard Self.validID(id),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let sidecarName = Self.readSidecar(at: directory.appendingPathComponent(id + ".json"), id: id)
            var cubeTitle: String?
            var itemError: String?
            do {
                let cube = try load(id: id)
                cubeTitle = cube.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                itemError = error.localizedDescription
            }
            let title = cubeTitle.flatMap { $0.isEmpty ? nil : $0 }
            let known = knownNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = known.flatMap { $0.isEmpty ? nil : $0 }
            let name = sidecarName ?? title ?? fallback ?? "이름 없는 LUT · \(id.prefix(8))"
            items.append(LUTLibraryItem(id: id, name: name, error: itemError))
        }
        return items.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    public func load(id: String) throws -> CubeLUT {
        guard Self.validID(id) else {
            throw LUTStoreError.invalidID
        }
        let url = directory.appendingPathComponent(id + ".cube")
        guard FileManager.default.fileExists(atPath: url.path) else { throw LUTStoreError.missing(id) }
        let data: Data
        do { data = try Self.readBounded(url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            throw LUTStoreError.missing(id)
        }
        catch let error as CubeLUTError { throw error }
        catch { throw LUTStoreError.cannotRead(url) }
        guard Self.sha256(data) == id else { throw LUTStoreError.damaged(id) }
        if let cached = Self.cubeCache.object(forKey: id as NSString) { return cached.cube }
        let cube = try CubeLUT.parse(data)
        Self.cubeCache.setObject(CachedCube(cube), forKey: id as NSString, cost: cube.cubeData.count)
        return cube
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func readSidecar(at url: URL, id: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(NameSidecar.self, from: data),
              sidecar.version == 1, sidecar.id == id,
              !sidecar.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return sidecar.name
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 64 * 1024 * 1024
        var result = Data()
        while result.count <= limit {
            let chunk = try handle.read(upToCount: min(1024 * 1024, limit + 1 - result.count)) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        guard result.count <= limit else { throw CubeLUTError.tooLarge }
        return result
    }
}

private struct NameSidecar: Codable {
    let version: Int
    let id: String
    let name: String
}

private final class CachedCube: NSObject {
    let cube: CubeLUT
    init(_ cube: CubeLUT) { self.cube = cube }
}
