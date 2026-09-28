import Foundation

public struct FaceCandidate: Identifiable, Sendable, Equatable {
    public var id: UUID { faceID }
    public let faceID: UUID
    public let photoID: UUID
    public let score: Float

    public init(faceID: UUID, photoID: UUID, score: Float) {
        self.faceID = faceID
        self.photoID = photoID
        self.score = score
    }
}

public enum FaceMatching {
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == 128, rhs.count == 128,
              lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite) else { return nil }

        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }
        guard dot.isFinite, lhsMagnitude.isFinite, rhsMagnitude.isFinite,
              lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        let value = dot / sqrt(lhsMagnitude * rhsMagnitude)
        guard value.isFinite else { return nil }
        return Float(max(-1, min(1, value)))
    }

    public static func candidates(
        for personID: UUID,
        in catalog: PeopleCatalog,
        photoIDs: Set<UUID>,
        threshold: Float = 0.50
    ) -> [FaceCandidate] {
        guard threshold.isFinite, catalog.people.contains(where: { $0.id == personID }) else { return [] }
        let minimumScore = max(0.50, min(1, threshold))
        let currentAnalyses = catalog.analyses.filter { photoIDs.contains($0.photoID) }
        let seededPhotoIDs = Set(currentAnalyses.compactMap { analysis in
            analysis.faces.contains(where: { $0.personID == personID }) ? analysis.photoID : nil
        })
        let seeds = currentAnalyses.flatMap(\.faces).filter { $0.personID == personID }
        guard !seeds.isEmpty else { return [] }

        var result: [FaceCandidate] = []
        for analysis in currentAnalyses where !seededPhotoIDs.contains(analysis.photoID) {
            for face in analysis.faces where face.personID == nil && !face.rejectedPersonIDs.contains(personID) {
                let score = seeds.compactMap { cosine(face.embedding, $0.embedding) }.max()
                if let score, score >= minimumScore {
                    result.append(FaceCandidate(faceID: face.id, photoID: analysis.photoID, score: score))
                }
            }
        }
        return result.sorted {
            $0.score == $1.score ? $0.faceID.uuidString < $1.faceID.uuidString : $0.score > $1.score
        }
    }
}
