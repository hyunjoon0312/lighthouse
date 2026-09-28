import Foundation
import XCTest
@testable import LighthouseCore

final class PeopleCatalogTests: XCTestCase {
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9])

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func vector(_ components: [(Int, Float)] = [(0, 1)]) -> [Float] {
        var result = [Float](repeating: 0, count: 128)
        for (index, value) in components { result[index] = value }
        let magnitude = sqrt(result.reduce(0) { $0 + $1 * $1 })
        return result.map { $0 / magnitude }
    }

    private func face(
        id: UUID = UUID(),
        embedding: [Float]? = nil,
        personID: UUID? = nil,
        rejected: Set<UUID> = [],
        bounds: FaceBounds = FaceBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
        jpeg: Data? = nil
    ) -> DetectedFace {
        DetectedFace(
            id: id,
            bounds: bounds,
            embedding: embedding ?? vector(),
            thumbnailJPEG: jpeg ?? self.jpeg,
            personID: personID,
            rejectedPersonIDs: rejected
        )
    }

    private func analysis(
        photoID: UUID = UUID(),
        path: String = "/photos/image.rw2",
        faces: [DetectedFace]
    ) -> PhotoFaceAnalysis {
        PhotoFaceAnalysis(
            photoID: photoID,
            sourcePath: path,
            sourceSize: 42,
            sourceModifiedAt: Date(timeIntervalSinceReferenceDate: 123_456),
            faces: faces
        )
    }

    func testSaveReloadNormalizesNamesBoundsAndLeavesPhotoCatalogUntouched() throws {
        let root = try directory()
        let photoCatalog = root.appendingPathComponent("catalog.json")
        let originalBytes = Data("existing photo catalog".utf8)
        try originalBytes.write(to: photoCatalog)
        let store = PeopleStore(url: root.appendingPathComponent("people.json"))
        let person = PersonProfile(name: "  지윤  ")
        let almostInside = FaceBounds(x: 0.75, y: 0.5, width: 0.2500000005, height: 0.5)
        let catalog = PeopleCatalog(
            people: [person],
            analyses: [analysis(faces: [face(personID: person.id, bounds: almostInside)])]
        )

        try store.save(catalog)
        let loaded = try store.load()
        XCTAssertEqual(loaded.people.first?.name, "지윤")
        XCTAssertEqual(loaded.analyses.first?.faces.first?.bounds.width, 0.25)
        XCTAssertEqual(loaded.analyses.first?.faces.first?.personID, person.id)
        XCTAssertEqual(try Data(contentsOf: photoCatalog), originalBytes)
        XCTAssertEqual(PeopleStore.defaultURL.lastPathComponent, "people.json")
    }

    func testMissingIsEmptyButCorruptUnsupportedAndInvalidFieldsThrow() throws {
        let root = try directory()
        let store = PeopleStore(url: root.appendingPathComponent("people.json"))
        XCTAssertEqual(try store.load(), PeopleCatalog())

        try Data("not json".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? PeopleStoreError, .damagedCatalog) }
        try JSONEncoder().encode(PeopleCatalog(version: 2)).write(to: store.url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? PeopleStoreError, .unsupportedVersion(2)) }
        try JSONEncoder().encode(PeopleCatalog(engineID: "other-engine")).write(to: store.url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? PeopleStoreError, .unsupportedEngine("other-engine")) }

        let person = PersonProfile(name: "A")
        XCTAssertThrowsError(try store.save(PeopleCatalog(people: [person, PersonProfile(id: person.id, name: "B")])))
        XCTAssertThrowsError(try store.save(PeopleCatalog(people: [person, PersonProfile(name: " a ")])))
        XCTAssertThrowsError(try store.save(PeopleCatalog(people: [PersonProfile(name: "   ")])))
        XCTAssertThrowsError(try store.save(PeopleCatalog(people: [PersonProfile(name: String(repeating: "가", count: 81))])))

        let photoID = UUID()
        let first = analysis(photoID: photoID, faces: [])
        XCTAssertThrowsError(try store.save(PeopleCatalog(analyses: [first, analysis(photoID: photoID, faces: [])])))
        XCTAssertThrowsError(try store.save(PeopleCatalog(analyses: [analysis(path: " \n", faces: [])])))
        var invalidSize = analysis(faces: [])
        invalidSize.sourceSize = -1
        XCTAssertThrowsError(try store.save(PeopleCatalog(analyses: [invalidSize])))
        var invalidDate = analysis(faces: [])
        invalidDate.sourceModifiedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try store.save(PeopleCatalog(analyses: [invalidDate])))
    }

    func testFailedSavePreservesOldBytesAndRejectsMalformedFaceData() throws {
        let root = try directory()
        let store = PeopleStore(url: root.appendingPathComponent("people.json"))
        try store.save(PeopleCatalog())
        let original = try Data(contentsOf: store.url)

        var nonfinite = vector()
        nonfinite[1] = .nan
        let invalidFaces = [
            face(embedding: [Float](repeating: 0, count: 128)),
            face(embedding: [Float](repeating: 1, count: 127)),
            face(embedding: nonfinite),
            face(bounds: FaceBounds(x: -0.1, y: 0, width: 0.2, height: 0.2)),
            face(bounds: FaceBounds(x: 0.9, y: 0, width: 0.2, height: 0.2)),
            face(bounds: FaceBounds(x: 0, y: 0, width: 0, height: 0.2)),
            face(jpeg: Data([0xff, 0xd8])),
            face(jpeg: Data(repeating: 0xff, count: 128 * 1024 + 1)),
        ]
        for invalidFace in invalidFaces {
            XCTAssertThrowsError(try store.save(PeopleCatalog(analyses: [analysis(faces: [invalidFace])])))
            XCTAssertEqual(try Data(contentsOf: store.url), original)
        }
    }

    func testMultiFaceReferencesDuplicateIDsAndLegacyDefaults() throws {
        let root = try directory()
        let store = PeopleStore(url: root.appendingPathComponent("people.json"))
        let first = PersonProfile(name: "First")
        let second = PersonProfile(name: "Second")
        let sharedFaceID = UUID()
        let valid = PeopleCatalog(
            people: [first, second],
            analyses: [analysis(faces: [
                face(personID: first.id, rejected: [second.id]),
                face(personID: second.id, rejected: [first.id]),
                face(rejected: [first.id, second.id]),
            ])]
        )
        try store.save(valid)
        XCTAssertEqual(try store.load(), valid)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        let encodedAnalyses = try XCTUnwrap(encodedObject["analyses"] as? [[String: Any]])
        let encodedFaces = try XCTUnwrap(encodedAnalyses[0]["faces"] as? [[String: Any]])
        let rejected = try XCTUnwrap(encodedFaces[2]["rejectedPersonIDs"] as? [String])
        XCTAssertEqual(rejected, rejected.sorted())

        XCTAssertThrowsError(try store.save(PeopleCatalog(
            people: [first],
            analyses: [analysis(faces: [face(id: sharedFaceID)]), analysis(faces: [face(id: sharedFaceID)])]
        )))
        XCTAssertThrowsError(try store.save(PeopleCatalog(
            people: [first], analyses: [analysis(faces: [face(personID: UUID())])]
        )))
        XCTAssertThrowsError(try store.save(PeopleCatalog(
            people: [first], analyses: [analysis(faces: [face(rejected: [UUID()])])]
        )))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var analyses = try XCTUnwrap(object["analyses"] as? [[String: Any]])
        var faces = try XCTUnwrap(analyses[0]["faces"] as? [[String: Any]])
        faces[0].removeValue(forKey: "personID")
        faces[0].removeValue(forKey: "rejectedPersonIDs")
        analyses[0]["faces"] = faces
        object["analyses"] = analyses
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        let decoded = try store.load().analyses[0].faces[0]
        XCTAssertNil(decoded.personID)
        XCTAssertEqual(decoded.rejectedPersonIDs, [])
    }

    func testCosineValidatesAndNormalizesVectors() throws {
        let x = vector([(0, 1)])
        let scaledX = x.map { $0 * 3 }
        let y = vector([(1, 1)])
        XCTAssertEqual(try XCTUnwrap(FaceMatching.cosine(x, scaledX)), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(FaceMatching.cosine(x, y)), 0, accuracy: 0.0001)
        XCTAssertNil(FaceMatching.cosine([], x))
        XCTAssertNil(FaceMatching.cosine([Float](repeating: 0, count: 128), x))
        var nonfinite = x
        nonfinite[4] = .infinity
        XCTAssertNil(FaceMatching.cosine(nonfinite, x))
    }

    func testCandidateRankingThresholdAndAllExclusions() {
        let person = PersonProfile(name: "Person")
        let other = PersonProfile(name: "Other")
        let seedPhoto = UUID()
        let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let tiedID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let suggestionPhoto = UUID()
        let rejectedPhoto = UUID()
        let assignedPhoto = UUID()
        let outsidePhoto = UUID()
        let x = vector([(0, 1)])
        let high = vector([(0, 0.8), (1, 0.6)])
        let low = vector([(0, 0.6), (1, 0.8)])
        let catalog = PeopleCatalog(people: [person, other], analyses: [
            analysis(photoID: seedPhoto, faces: [face(embedding: x, personID: person.id), face(embedding: x)]),
            analysis(photoID: suggestionPhoto, faces: [
                face(id: tiedID, embedding: high), face(id: highID, embedding: high), face(id: lowID, embedding: low),
            ]),
            analysis(photoID: rejectedPhoto, faces: [face(embedding: x, rejected: [person.id])]),
            analysis(photoID: assignedPhoto, faces: [face(embedding: x, personID: other.id), face(embedding: x, personID: UUID())]),
            analysis(photoID: outsidePhoto, faces: [face(embedding: x)]),
        ])
        let current: Set<UUID> = [seedPhoto, suggestionPhoto, rejectedPhoto, assignedPhoto]

        let candidates = FaceMatching.candidates(for: person.id, in: catalog, photoIDs: current)
        XCTAssertEqual(candidates.map(\.faceID), [highID, tiedID, lowID])
        XCTAssertEqual(candidates[0].score, 0.8, accuracy: 0.0001)
        XCTAssertEqual(candidates[1].score, 0.8, accuracy: 0.0001)
        XCTAssertEqual(candidates[2].score, 0.6, accuracy: 0.0001)
        XCTAssertEqual(FaceMatching.candidates(for: person.id, in: catalog, photoIDs: current, threshold: 0.7).count, 2)
        XCTAssertEqual(FaceMatching.candidates(for: person.id, in: catalog, photoIDs: current, threshold: 0).count, 3)
        XCTAssertEqual(FaceMatching.candidates(for: person.id, in: catalog, photoIDs: current, threshold: .nan), [])
        XCTAssertEqual(FaceMatching.candidates(for: UUID(), in: catalog, photoIDs: current), [])

        let suggestionsOnly = PeopleCatalog(people: [person], analyses: [analysis(faces: [face(embedding: x)])])
        XCTAssertEqual(FaceMatching.candidates(for: person.id, in: suggestionsOnly, photoIDs: Set(suggestionsOnly.analyses.map(\.photoID))), [])
    }
}
