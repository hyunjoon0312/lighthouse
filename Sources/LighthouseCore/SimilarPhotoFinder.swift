import CoreGraphics
import CryptoKit
import Foundation

public enum SimilarPhotoKind: String, Codable, Equatable, Sendable {
    case exact
    case similar
}

public struct SimilarPhotoFailure: Codable, Equatable, Sendable {
    public let photoID: UUID
    public let path: String
    public let message: String

    public init(photoID: UUID, path: String, message: String) {
        self.photoID = photoID
        self.path = path
        self.message = message
    }
}

public struct SimilarPhotoGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: SimilarPhotoKind
    public let photoIDs: [UUID]

    public init(id: UUID, kind: SimilarPhotoKind, photoIDs: [UUID]) {
        self.id = id
        self.kind = kind
        self.photoIDs = photoIDs
    }
}

public struct SimilarPhotoResult: Codable, Equatable, Sendable {
    public let groups: [SimilarPhotoGroup]
    public let failures: [SimilarPhotoFailure]
    public let isCancelled: Bool

    public init(groups: [SimilarPhotoGroup], failures: [SimilarPhotoFailure], isCancelled: Bool) {
        self.groups = groups
        self.failures = failures
        self.isCancelled = isCancelled
    }
}

public enum SimilarPhotoFinderError: LocalizedError {
    case unreadableFile(String)
    case fileChanged(String)
    case cannotReadImage(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path): "파일을 읽을 수 없습니다: \(path)"
        case .fileChanged(let path): "분석하는 동안 파일이 변경되었습니다: \(path)"
        case .cannotReadImage(let path): "유사도 미리보기를 읽을 수 없습니다: \(path)"
        }
    }
}

public enum SimilarPhotoFinder {
    public static func analyze(
        photos: [PhotoAsset],
        pipeline: ImagePipeline,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> SimilarPhotoResult {
        let items = uniqueSources(photos)
        let total = items.count
        var failures: [SimilarPhotoFailure] = []
        var identities: [UUID: FileIdentity] = [:]

        for item in items {
            if isCancelled() {
                return SimilarPhotoResult(groups: [], failures: failures, isCancelled: true)
            }
            do { identities[item.id] = try fileIdentity(item.url) }
            catch {
                failures.append(failure(for: item, error: error))
            }
        }
        let sizeCounts = Dictionary(grouping: identities, by: { $0.value.size }).mapValues(\.count)
        var fingerprints: [Fingerprint] = []
        fingerprints.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if isCancelled() {
                return partialResult(fingerprints: fingerprints, failures: failures, cancelled: true)
            }
            defer { progress(index + 1, total) }
            guard let before = identities[item.id] else { continue }
            var digest: String?
            do {
                digest = sizeCounts[before.size, default: 0] > 1
                    ? try streamingSHA256(item.url, isCancelled: isCancelled) : nil
                let after = try fileIdentity(item.url)
                guard before == after else { throw SimilarPhotoFinderError.fileChanged(item.path) }
            } catch {
                if error is CancellationError {
                    return partialResult(fingerprints: fingerprints, failures: failures, cancelled: true)
                }
                failures.append(failure(for: item, error: error))
                continue
            }
            var feature: ImageFeature?
            do {
                feature = try imageFeature(item.url, pipeline: pipeline)
                let after = try fileIdentity(item.url)
                guard before == after else { throw SimilarPhotoFinderError.fileChanged(item.path) }
            } catch {
                failures.append(failure(for: item, error: error))
                if case SimilarPhotoFinderError.fileChanged = error { continue }
            }
            fingerprints.append(Fingerprint(photo: item, identity: before, digest: digest, feature: feature))
        }
        return partialResult(fingerprints: fingerprints, failures: failures, cancelled: false,
                             isCancelled: isCancelled)
    }

    private static func partialResult(fingerprints: [Fingerprint], failures: [SimilarPhotoFailure],
                                      cancelled: Bool,
                                      isCancelled: @Sendable () -> Bool = { false }) -> SimilarPhotoResult {
        let exact = exactGroups(fingerprints, isCancelled: isCancelled)
        let exactIDs = Set(exact.groups.flatMap(\.photoIDs))
        let similar = similarGroups(fingerprints.filter { !exactIDs.contains($0.photo.id) },
                                    isCancelled: { cancelled || exact.cancelled || isCancelled() })
        return result(exact: exact.groups, similar: similar.groups, failures: failures,
                      cancelled: cancelled || exact.cancelled || similar.cancelled)
    }

    private static func result(exact: [SimilarPhotoGroup], similar: [SimilarPhotoGroup],
                               failures: [SimilarPhotoFailure], cancelled: Bool) -> SimilarPhotoResult {
        SimilarPhotoResult(groups: exact + similar,
                           failures: failures.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                           isCancelled: cancelled)
    }

    private static func uniqueSources(_ photos: [PhotoAsset]) -> [PhotoAsset] {
        var byPath: [String: PhotoAsset] = [:]
        for photo in photos {
            let path = photo.url.standardizedFileURL.resolvingSymlinksInPath().path
            if let current = byPath[path] {
                if current.isVirtualCopy && !photo.isVirtualCopy { byPath[path] = photo }
            } else {
                byPath[path] = photo
            }
        }
        return byPath.values.sorted {
            let comparison = $0.path.localizedStandardCompare($1.path)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    private static func exactGroups(
        _ fingerprints: [Fingerprint], isCancelled: @Sendable () -> Bool = { false }
    ) -> (groups: [SimilarPhotoGroup], cancelled: Bool) {
        var grouped: [ExactKey: [UUID]] = [:]
        var cancelled = false
        for fingerprint in fingerprints where fingerprint.digest != nil {
            if isCancelled() { cancelled = true; break }
            let key = ExactKey(size: fingerprint.identity.size, digest: fingerprint.digest!,
                               isRAW: fingerprint.photo.isRAW)
            grouped[key, default: []].append(fingerprint.photo.id)
        }
        let groups = grouped.values.filter { $0.count > 1 }.map { values in
            let ids = values.sorted { $0.uuidString < $1.uuidString }
            return SimilarPhotoGroup(id: stableID(kind: .exact, photoIDs: ids), kind: .exact, photoIDs: ids)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return (groups, cancelled)
    }

    private static func similarGroups(
        _ fingerprints: [Fingerprint], isCancelled: @Sendable () -> Bool = { false }
    ) -> (groups: [SimilarPhotoGroup], cancelled: Bool) {
        let eligible = fingerprints.filter { $0.feature?.isLowInformation == false }
            .sorted { $0.photo.id.uuidString < $1.photo.id.uuidString }
        var representatives: [(index: Int, members: [Int])] = []
        var buckets: [ChunkKey: Set<Int>] = [:]
        var cancelled = false
        for index in eligible.indices {
            if isCancelled() { cancelled = true; break }
            let feature = eligible[index].feature!
            let keys = chunkKeys(feature.dHash)
            let candidates = Set(keys.flatMap { buckets[$0] ?? [] }).sorted()
            if let group = candidates.first(where: {
                isSimilar(eligible[representatives[$0].index].feature!, feature)
            }) {
                representatives[group].members.append(index)
            } else {
                let group = representatives.count
                representatives.append((index, [index]))
                for key in keys { buckets[key, default: []].insert(group) }
            }
        }
        var groups: [SimilarPhotoGroup] = []
        for representative in representatives {
            let members = representative.members
            guard members.count > 1 else { continue }
            let ids = members.map { eligible[$0].photo.id }.sorted { $0.uuidString < $1.uuidString }
            groups.append(SimilarPhotoGroup(id: stableID(kind: .similar, photoIDs: ids), kind: .similar, photoIDs: ids))
        }
        return (groups.sorted { $0.id.uuidString < $1.id.uuidString }, cancelled)
    }

    private static func isSimilar(_ left: ImageFeature, _ right: ImageFeature) -> Bool {
        let ratioDifference = abs(left.aspectRatio - right.aspectRatio) / max(left.aspectRatio, right.aspectRatio)
        guard ratioDifference <= 0.08, (left.dHash ^ right.dHash).nonzeroBitCount <= 8 else { return false }
        var squared = 0.0
        for index in left.rgb.indices {
            let difference = Double(left.rgb[index] - right.rgb[index])
            squared += difference * difference
        }
        return sqrt(squared / Double(left.rgb.count)) <= 0.12
    }

    private static func chunkKeys(_ hash: UInt64) -> [ChunkKey] {
        var keys: [ChunkKey] = []
        var shift = 0
        for index in 0..<9 {
            let width = index == 8 ? 8 : 7
            let mask = (UInt64(1) << UInt64(width)) - 1
            keys.append(ChunkKey(index: index, value: UInt16((hash >> UInt64(shift)) & mask)))
            shift += width
        }
        return keys
    }

    private static func imageFeature(_ url: URL, pipeline: ImagePipeline) throws -> ImageFeature {
        let image: CGImage
        do { image = try pipeline.thumbnail(for: url, maxPixel: 256) }
        catch { throw SimilarPhotoFinderError.cannotReadImage(url.path) }
        let pixels = try rgba(image, width: 16, height: 16, path: url.path)
        var rgb = [Float]()
        rgb.reserveCapacity(16 * 16 * 3)
        var luminance = [Double]()
        luminance.reserveCapacity(16 * 16)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Float(pixels[offset]) / 255, g = Float(pixels[offset + 1]) / 255, b = Float(pixels[offset + 2]) / 255
            rgb.append(r); rgb.append(g); rgb.append(b)
            luminance.append(0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b))
        }
        let mean = luminance.reduce(0, +) / Double(luminance.count)
        let variance = luminance.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luminance.count)
        let hashPixels = try rgba(image, width: 9, height: 8, path: url.path)
        var dHash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let left = gray(hashPixels, offset: (y * 9 + x) * 4)
                let right = gray(hashPixels, offset: (y * 9 + x + 1) * 4)
                if left > right { dHash |= UInt64(1) << bit }
                bit += 1
            }
        }
        return ImageFeature(dHash: dHash, rgb: rgb,
                            aspectRatio: Double(image.width) / Double(max(1, image.height)),
                            isLowInformation: variance < 0.0004)
    }

    private static func rgba(_ image: CGImage, width: Int, height: Int, path: String) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SimilarPhotoFinderError.cannotReadImage(path)
        }
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw SimilarPhotoFinderError.cannotReadImage(path) }
        return bytes
    }

    private static func gray(_ bytes: [UInt8], offset: Int) -> Double {
        0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.0722 * Double(bytes[offset + 2])
    }

    private static func fileIdentity(_ url: URL) throws -> FileIdentity {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else {
                throw SimilarPhotoFinderError.unreadableFile(url.path)
            }
            return FileIdentity(size: Int64(size), modified: modified)
        } catch let error as SimilarPhotoFinderError { throw error }
        catch { throw SimilarPhotoFinderError.unreadableFile(url.path) }
    }

    private static func streamingSHA256(_ url: URL, isCancelled: @Sendable () -> Bool) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw SimilarPhotoFinderError.unreadableFile(url.path) }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                if isCancelled() { throw CancellationError() }
                hasher.update(data: data)
            }
        } catch let error as CancellationError { throw error }
        catch { throw SimilarPhotoFinderError.unreadableFile(url.path) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stableID(kind: SimilarPhotoKind, photoIDs: [UUID]) -> UUID {
        let value = ([kind.rawValue] + photoIDs.map(\.uuidString).sorted()).joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func failure(for photo: PhotoAsset, error: Error) -> SimilarPhotoFailure {
        SimilarPhotoFailure(photoID: photo.id, path: photo.path,
                            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private struct FileIdentity: Equatable {
        let size: Int64
        let modified: Date
    }

    private struct ExactKey: Hashable {
        let size: Int64
        let digest: String
        let isRAW: Bool
    }

    private struct ImageFeature {
        let dHash: UInt64
        let rgb: [Float]
        let aspectRatio: Double
        let isLowInformation: Bool
    }

    private struct Fingerprint {
        let photo: PhotoAsset
        let identity: FileIdentity
        let digest: String?
        let feature: ImageFeature?
    }

    private struct ChunkKey: Hashable {
        let index: Int
        let value: UInt16
    }
}
