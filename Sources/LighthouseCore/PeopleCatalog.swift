import Foundation

public struct FaceBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PersonProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct DetectedFace: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bounds: FaceBounds
    public var embedding: [Float]
    public var thumbnailJPEG: Data
    public var personID: UUID?
    public var rejectedPersonIDs: Set<UUID>

    public init(
        id: UUID = UUID(),
        bounds: FaceBounds,
        embedding: [Float],
        thumbnailJPEG: Data,
        personID: UUID? = nil,
        rejectedPersonIDs: Set<UUID> = []
    ) {
        self.id = id
        self.bounds = bounds
        self.embedding = embedding
        self.thumbnailJPEG = thumbnailJPEG
        self.personID = personID
        self.rejectedPersonIDs = rejectedPersonIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, bounds, embedding, thumbnailJPEG, personID, rejectedPersonIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bounds = try container.decode(FaceBounds.self, forKey: .bounds)
        embedding = try container.decode([Float].self, forKey: .embedding)
        thumbnailJPEG = try container.decode(Data.self, forKey: .thumbnailJPEG)
        personID = try container.decodeIfPresent(UUID.self, forKey: .personID)
        rejectedPersonIDs = Set(try container.decodeIfPresent([UUID].self, forKey: .rejectedPersonIDs) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bounds, forKey: .bounds)
        try container.encode(embedding, forKey: .embedding)
        try container.encode(thumbnailJPEG, forKey: .thumbnailJPEG)
        try container.encodeIfPresent(personID, forKey: .personID)
        try container.encode(rejectedPersonIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .rejectedPersonIDs)
    }
}

public struct PhotoFaceAnalysis: Codable, Equatable, Sendable {
    public var photoID: UUID
    public var sourcePath: String
    public var sourceSize: Int64
    public var sourceModifiedAt: Date
    public var faces: [DetectedFace]

    public init(
        photoID: UUID,
        sourcePath: String,
        sourceSize: Int64,
        sourceModifiedAt: Date,
        faces: [DetectedFace]
    ) {
        self.photoID = photoID
        self.sourcePath = sourcePath
        self.sourceSize = sourceSize
        self.sourceModifiedAt = sourceModifiedAt
        self.faces = faces
    }
}

public struct PeopleCatalog: Codable, Equatable, Sendable {
    public static let currentEngineID = "sface-2021dec-v1"

    public var version: Int
    public var engineID: String
    public var people: [PersonProfile]
    public var analyses: [PhotoFaceAnalysis]

    public init(
        version: Int = 1,
        engineID: String = PeopleCatalog.currentEngineID,
        people: [PersonProfile] = [],
        analyses: [PhotoFaceAnalysis] = []
    ) {
        self.version = version
        self.engineID = engineID
        self.people = people
        self.analyses = analyses
    }
}

public enum PeopleStoreError: LocalizedError, Equatable {
    case cannotRead
    case cannotSave
    case damagedCatalog
    case unsupportedVersion(Int)
    case unsupportedEngine(String)
    case duplicatePersonID(UUID)
    case invalidPersonName(String)
    case duplicatePersonName(String)
    case duplicateAnalysisID(UUID)
    case invalidSourcePath(UUID)
    case invalidSourceSize(UUID)
    case invalidSourceModifiedAt(UUID)
    case duplicateFaceID(UUID)
    case invalidBounds(UUID)
    case invalidEmbedding(UUID)
    case invalidThumbnail(UUID)
    case missingPersonReference(UUID)

    public var errorDescription: String? {
        switch self {
        case .cannotRead: "사람 카탈로그를 읽을 수 없습니다."
        case .cannotSave: "사람 카탈로그를 저장할 수 없습니다."
        case .damagedCatalog: "사람 카탈로그가 손상되었거나 형식이 올바르지 않습니다."
        case .unsupportedVersion(let version): "지원하지 않는 사람 카탈로그 버전 \(version)입니다."
        case .unsupportedEngine(let engine): "지원하지 않는 얼굴 분석 엔진입니다: \(engine)"
        case .duplicatePersonID(let id): "중복된 사람 ID입니다: \(id.uuidString)"
        case .invalidPersonName(let name): "사람 이름은 공백을 제외하고 1…80자여야 합니다: \(name)"
        case .duplicatePersonName(let name): "같은 이름의 사람이 이미 있습니다: \(name)"
        case .duplicateAnalysisID(let id): "중복된 사진 얼굴 분석 ID입니다: \(id.uuidString)"
        case .invalidSourcePath(let id): "사진 얼굴 분석의 원본 경로가 비어 있습니다: \(id.uuidString)"
        case .invalidSourceSize(let id): "사진 얼굴 분석의 원본 크기가 올바르지 않습니다: \(id.uuidString)"
        case .invalidSourceModifiedAt(let id): "사진 얼굴 분석의 수정 시각이 올바르지 않습니다: \(id.uuidString)"
        case .duplicateFaceID(let id): "중복된 얼굴 ID입니다: \(id.uuidString)"
        case .invalidBounds(let id): "얼굴 영역이 올바르지 않습니다: \(id.uuidString)"
        case .invalidEmbedding(let id): "얼굴 특징 벡터가 올바르지 않습니다: \(id.uuidString)"
        case .invalidThumbnail(let id): "얼굴 미리보기가 올바른 JPEG가 아닙니다: \(id.uuidString)"
        case .missingPersonReference(let id): "존재하지 않는 사람을 참조합니다: \(id.uuidString)"
        }
    }
}

public struct PeopleStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        CatalogStore.defaultURL.deletingLastPathComponent().appendingPathComponent("people.json")
    }

    public func load() throws -> PeopleCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return PeopleCatalog()
        } catch {
            throw PeopleStoreError.cannotRead
        }

        let catalog: PeopleCatalog
        do {
            catalog = try JSONDecoder().decode(PeopleCatalog.self, from: data)
        } catch {
            throw PeopleStoreError.damagedCatalog
        }
        return try Self.validated(catalog)
    }

    public func save(_ catalog: PeopleCatalog) throws {
        let normalized = try Self.validated(catalog)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(normalized)
        } catch {
            throw PeopleStoreError.damagedCatalog
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw PeopleStoreError.cannotSave
        }
    }

    private static func validated(_ catalog: PeopleCatalog) throws -> PeopleCatalog {
        guard catalog.version == 1 else { throw PeopleStoreError.unsupportedVersion(catalog.version) }
        guard catalog.engineID == PeopleCatalog.currentEngineID else {
            throw PeopleStoreError.unsupportedEngine(catalog.engineID)
        }

        var personIDs = Set<UUID>()
        var personNames = Set<String>()
        let people = try catalog.people.map { person in
            guard personIDs.insert(person.id).inserted else { throw PeopleStoreError.duplicatePersonID(person.id) }
            var normalized = person
            normalized.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(normalized.name.count) else {
                throw PeopleStoreError.invalidPersonName(person.name)
            }
            let key = normalized.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard personNames.insert(key).inserted else { throw PeopleStoreError.duplicatePersonName(normalized.name) }
            return normalized
        }

        var analysisIDs = Set<UUID>()
        var faceIDs = Set<UUID>()
        let analyses = try catalog.analyses.map { analysis in
            guard analysisIDs.insert(analysis.photoID).inserted else {
                throw PeopleStoreError.duplicateAnalysisID(analysis.photoID)
            }
            guard !analysis.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PeopleStoreError.invalidSourcePath(analysis.photoID)
            }
            guard analysis.sourceSize >= 0 else { throw PeopleStoreError.invalidSourceSize(analysis.photoID) }
            guard analysis.sourceModifiedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw PeopleStoreError.invalidSourceModifiedAt(analysis.photoID)
            }
            var normalized = analysis
            normalized.faces = try analysis.faces.map { face in
                guard faceIDs.insert(face.id).inserted else { throw PeopleStoreError.duplicateFaceID(face.id) }
                guard validEmbedding(face.embedding) else { throw PeopleStoreError.invalidEmbedding(face.id) }
                guard validJPEG(face.thumbnailJPEG) else { throw PeopleStoreError.invalidThumbnail(face.id) }
                if let personID = face.personID, !personIDs.contains(personID) {
                    throw PeopleStoreError.missingPersonReference(personID)
                }
                if let missing = face.rejectedPersonIDs.first(where: { !personIDs.contains($0) }) {
                    throw PeopleStoreError.missingPersonReference(missing)
                }
                var normalizedFace = face
                normalizedFace.bounds = try normalizedBounds(face.bounds, faceID: face.id)
                return normalizedFace
            }
            return normalized
        }

        return PeopleCatalog(version: catalog.version, engineID: catalog.engineID, people: people, analyses: analyses)
    }

    private static func normalizedBounds(_ bounds: FaceBounds, faceID: UUID) throws -> FaceBounds {
        let values = [bounds.x, bounds.y, bounds.width, bounds.height]
        guard values.allSatisfy(\.isFinite), bounds.x >= 0, bounds.y >= 0,
              bounds.width > 0, bounds.height > 0 else {
            throw PeopleStoreError.invalidBounds(faceID)
        }
        let tolerance = 1e-9
        guard bounds.x <= 1, bounds.y <= 1,
              bounds.x + bounds.width <= 1 + tolerance,
              bounds.y + bounds.height <= 1 + tolerance else {
            throw PeopleStoreError.invalidBounds(faceID)
        }
        let normalizedWidth = min(bounds.width, 1 - bounds.x)
        let normalizedHeight = min(bounds.height, 1 - bounds.y)
        guard normalizedWidth > 0, normalizedHeight > 0 else {
            throw PeopleStoreError.invalidBounds(faceID)
        }
        return FaceBounds(
            x: bounds.x,
            y: bounds.y,
            width: normalizedWidth,
            height: normalizedHeight
        )
    }

    private static func validEmbedding(_ embedding: [Float]) -> Bool {
        guard embedding.count == 128, embedding.allSatisfy(\.isFinite) else { return false }
        let magnitudeSquared = embedding.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard magnitudeSquared.isFinite, magnitudeSquared > 0 else { return false }
        return abs(sqrt(magnitudeSquared) - 1) <= 0.01
    }

    private static func validJPEG(_ data: Data) -> Bool {
        data.count <= 128 * 1024 && data.count >= 3
            && data[data.startIndex] == 0xff
            && data[data.index(after: data.startIndex)] == 0xd8
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xff
    }
}
