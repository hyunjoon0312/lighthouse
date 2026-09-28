import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class PeopleFlowTests: XCTestCase {
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9])

    private func embedding(_ axis: Int = 0, secondary: (Int, Float)? = nil) -> [Float] {
        var values = [Float](repeating: 0, count: 128)
        values[axis] = 1
        if let secondary { values[secondary.0] = secondary.1 }
        let length = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return values.map { $0 / length }
    }

    private func face(_ axis: Int = 0, secondary: (Int, Float)? = nil) -> DetectedFace {
        DetectedFace(
            bounds: FaceBounds(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            embedding: embedding(axis, secondary: secondary),
            thumbnailJPEG: jpeg
        )
    }

    private func analysis(for photo: PhotoAsset, faces: [DetectedFace]) throws -> PhotoFaceAnalysis {
        let attributes = try FileManager.default.attributesOfItem(atPath: photo.path)
        return PhotoFaceAnalysis(
            photoID: photo.id,
            sourcePath: photo.path,
            sourceSize: (attributes[.size] as! NSNumber).int64Value,
            sourceModifiedAt: attributes[.modificationDate] as! Date,
            faces: faces
        )
    }

    func testLegacyMissingPeopleFileLoadsAndCorruptFileDisablesOnlyPeopleWrites() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 1)
        XCTAssertTrue(model.peopleLoaded)
        XCTAssertNil(model.peopleLoadError)
        XCTAssertEqual(model.peopleCatalog, PeopleCatalog())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/people.json").path))

        try model.flushSave()
        let bad = Data("damaged people catalog".utf8)
        try bad.write(to: root.appendingPathComponent("data/people.json"))
        let reopened = LibraryModel()
        reopened.start()
        try await TestSupport.wait("corrupt people load") { reopened.catalogLoaded && reopened.peopleLoadError != nil }
        XCTAssertEqual(reopened.photos.count, 1, "사진 카탈로그는 계속 열린다")
        reopened.peopleCatalog.people.append(PersonProfile(name: "저장하면 안 됨"))
        reopened.schedulePeopleSave()
        try reopened.flushSave()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("data/people.json")), bad)
    }

    func testNameCreationConfirmedSearchPersonFilterAndSuggestionsStayOutOfSearch() async throws {
        let firstFaces = [face(0), face(1)]
        let secondFaces = [face(0, secondary: (2, 0.1))]
        let analyzer = LockedPeopleAnalyzer { url, _ in
            url.lastPathComponent == "photo-00.jpg" ? firstFaces : secondFaces
        }
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        model.faceAnalyzeOverride = analyzer.analyze
        model.startFaceAnalysis(selectedOnly: false)
        try await TestSupport.wait("face scan") { !model.isAnalyzingFaces }
        XCTAssertEqual(analyzer.callCount, 2)
        let firstPhotoFaces = try XCTUnwrap(model.peopleCatalog.analyses.first { $0.photoID == model.photos[0].id }).faces
        XCTAssertNil(model.createPerson(named: " Alice ", assigning: [firstPhotoFaces[0].id]))
        XCTAssertNil(model.createPerson(named: "Bob", assigning: [firstPhotoFaces[1].id]))
        let alice = try XCTUnwrap(model.peopleCatalog.people.first { $0.name == "Alice" })
        let bob = try XCTUnwrap(model.peopleCatalog.people.first { $0.name == "Bob" })

        model.search = "Alice"
        XCTAssertEqual(model.visiblePhotos.map(\.id), [model.photos[0].id], "확정된 이름만 검색한다")
        XCTAssertEqual(model.candidateFaces(for: alice.id).map(\.photoID), [model.photos[1].id])
        XCTAssertFalse(model.visiblePhotos.contains { $0.id == model.photos[1].id }, "후보는 이름 검색 결과가 아니다")
        model.search = ""
        model.filter = .person(alice.id)
        XCTAssertEqual(model.visiblePhotos.map(\.id), [model.photos[0].id])
        XCTAssertEqual(model.counts.people[alice.id], 1)
        XCTAssertEqual(model.counts.people[bob.id], 1, "한 사진에 여러 사람을 셀 수 있다")
    }

    func testRejectUnassignReassignRenameDeleteClearAndRestart() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        let candidate = face()
        let second = face(1)
        model.peopleCatalog = PeopleCatalog(analyses: [
            try analysis(for: model.photos[0], faces: [candidate]),
            try analysis(for: model.photos[1], faces: [second]),
        ])
        XCTAssertNil(model.createPerson(named: "하나", assigning: [candidate.id]))
        let person = try XCTUnwrap(model.peopleCatalog.people.first)
        model.rejectCandidate(second.id, for: person.id)
        XCTAssertTrue(model.peopleCatalog.analyses[1].faces[0].rejectedPersonIDs.contains(person.id))
        model.unassignFace(candidate.id)
        XCTAssertNil(model.peopleCatalog.analyses[0].faces[0].personID)
        XCTAssertTrue(model.peopleCatalog.analyses[0].faces[0].rejectedPersonIDs.contains(person.id))
        model.assignFaces([candidate.id], to: person.id)
        XCTAssertEqual(model.peopleCatalog.analyses[0].faces[0].personID, person.id)
        XCTAssertFalse(model.peopleCatalog.analyses[0].faces[0].rejectedPersonIDs.contains(person.id))
        XCTAssertNil(model.renamePerson(person.id, to: "둘"))
        XCTAssertNotNil(model.renamePerson(person.id, to: "   "))
        XCTAssertNotNil(model.createPerson(named: "둘", assigning: [second.id]))
        model.deletePerson(person.id)
        XCTAssertTrue(model.peopleCatalog.people.isEmpty)
        XCTAssertTrue(model.peopleCatalog.analyses.flatMap(\.faces).allSatisfy { $0.personID == nil && !$0.rejectedPersonIDs.contains(person.id) })

        let replacement = PersonProfile(name: "다시")
        model.peopleCatalog.people = [replacement]
        model.assignFaces([candidate.id], to: replacement.id)
        try model.flushSave()
        let restarted = LibraryModel()
        restarted.start()
        try await TestSupport.wait("people restart") { restarted.catalogLoaded && restarted.peopleLoaded }
        XCTAssertEqual(restarted.peopleCatalog.people, [replacement])
        XCTAssertEqual(restarted.peopleCatalog.analyses[0].faces[0].personID, replacement.id)
        await restarted.clearPeopleAnalysis()
        XCTAssertEqual(restarted.peopleCatalog, PeopleCatalog())
        XCTAssertEqual(restarted.photos.count, 2)
    }

    func testChangedSourceAndRemovedLateResultsAreIgnoredAndFailureRetries() async throws {
        let (model, _, urls) = try await TestSupport.startedModel(self, photos: 1)
        let retryFace = face()
        let calls = LockedPeopleAnalyzer { _, count in
            if count == 1 { throw MockPeopleError.failed }
            return [retryFace]
        }
        model.faceAnalyzeOverride = calls.analyze
        model.startFaceAnalysis(selectedOnly: false)
        try await TestSupport.wait("failed scan") { !model.isAnalyzingFaces }
        XCTAssertTrue(model.peopleCatalog.analyses.isEmpty, "오류는 얼굴 없음으로 캐시하지 않는다")
        XCTAssertTrue(model.peopleMessage?.contains(MockPeopleError.failed.localizedDescription) == true)
        model.startFaceAnalysis(selectedOnly: false)
        try await TestSupport.wait("retry scan") { !model.isAnalyzingFaces }
        XCTAssertEqual(model.peopleCatalog.analyses.count, 1)
        XCTAssertEqual(calls.callCount, 2)
        model.startFaceAnalysis(selectedOnly: false)
        try await TestSupport.wait("cached scan") { !model.isAnalyzingFaces }
        XCTAssertEqual(calls.callCount, 2)
        XCTAssertTrue(model.peopleMessage?.contains("캐시 사용 1장") == true)

        model.peopleCatalog.analyses = []
        let mutatedFace = face()
        let mutation = LockedPeopleAnalyzer { url, _ in
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            return [mutatedFace]
        }
        model.faceAnalyzeOverride = mutation.analyze
        model.startFaceAnalysis(selectedOnly: false)
        try await TestSupport.wait("mutated source") { !model.isAnalyzingFaces }
        XCTAssertTrue(model.peopleCatalog.analyses.isEmpty, "분석 중 바뀐 원본 결과를 받지 않는다")

        try TestSupport.writeJPEG(urls[0])
        let gate = BlockingPeopleAnalyzer(result: [face()])
        model.faceAnalyzeOverride = gate.analyze
        model.startFaceAnalysis(selectedOnly: false)
        try await gate.waitUntilStarted()
        model.removeFromCatalog([model.photos[0].id])
        gate.resume()
        try await TestSupport.wait("removed late callback") { !model.isAnalyzingFaces }
        XCTAssertTrue(model.peopleCatalog.analyses.isEmpty)
    }

    func testCancellationResumesMultipleWaitersAndKeepsCompletedResult() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 3)
        let gate = BlockingPeopleAnalyzer(result: [face()])
        model.faceAnalyzeOverride = gate.analyze
        model.startFaceAnalysis(selectedOnly: false)
        try await gate.waitUntilStarted()
        model.cancelFaceAnalysis()
        let first = Task { @MainActor in await model.cancelFaceAnalysisAndWait() }
        let second = Task { @MainActor in await model.cancelFaceAnalysisAndWait() }
        gate.resume()
        await first.value
        await second.value
        XCTAssertFalse(model.isAnalyzingFaces)
        XCTAssertFalse(model.isCancellingFaces)
        XCTAssertEqual(model.peopleCatalog.analyses.count, 1, "이미 읽은 사진 결과는 남긴다")
        XCTAssertEqual(gate.callCount, 1, "다음 사진을 시작하지 않는다")
    }

    func testClearPublishesEmptyCatalogBeforeWaitingAndBlocksAnotherScan() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 2)
        model.peopleCatalog.people = [PersonProfile(name: "지울 사람")]
        let gate = BlockingPeopleAnalyzer(result: [face()])
        model.faceAnalyzeOverride = gate.analyze
        model.startFaceAnalysis(selectedOnly: false)
        try await gate.waitUntilStarted()

        let clear = Task { @MainActor in await model.clearPeopleAnalysis() }
        try await TestSupport.wait("people clear starts") { model.isClearingPeople }
        XCTAssertEqual(model.peopleCatalog, PeopleCatalog(), "취소 대기 전부터 비운 상태를 저장할 수 있어야 한다")
        model.startFaceAnalysis(selectedOnly: false)
        XCTAssertEqual(gate.callCount, 1, "지우는 동안 새 분석을 시작하지 않는다")

        gate.resume()
        await clear.value
        XCTAssertFalse(model.isClearingPeople)
        XCTAssertFalse(model.isAnalyzingFaces)
        XCTAssertEqual(model.peopleCatalog, PeopleCatalog(), "늦게 끝난 분석 결과가 지운 정보를 되살리지 않는다")
    }

    func testPeopleSaveFailureIsVisibleAndFlushRetriesLatestCatalog() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 1)
        let peopleURL = root.appendingPathComponent("data/people.json")
        try FileManager.default.createDirectory(at: peopleURL, withIntermediateDirectories: true)
        let person = PersonProfile(name: "재시도")
        model.peopleCatalog.people = [person]
        model.schedulePeopleSave()
        try await TestSupport.wait("people save failure") { model.peopleSaveError != nil }

        try FileManager.default.removeItem(at: peopleURL)
        try model.flushSave()
        XCTAssertNil(model.peopleSaveError)
        XCTAssertEqual(try PeopleStore(url: peopleURL).load().people, [person])
    }

    func testRelocationPreservesAssignmentsRemovedAssetsHideAndOriginalBytesStayUnchanged() async throws {
        let (model, root, urls) = try await TestSupport.startedModel(self, photos: 1)
        let originalBytes = try Data(contentsOf: urls[0])
        let person = PersonProfile(name: "사람")
        var assigned = face()
        assigned.personID = person.id
        model.peopleCatalog = PeopleCatalog(people: [person], analyses: [try analysis(for: model.photos[0], faces: [assigned])])
        let originalPhoto = model.photos[0]
        model.removeFromCatalog([originalPhoto.id])
        XCTAssertTrue(model.peopleFaces(personID: person.id).isEmpty)
        model.undo()
        XCTAssertEqual(model.peopleFaces(personID: person.id).count, 1)

        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let destination = moved.appendingPathComponent(urls[0].lastPathComponent)
        try FileManager.default.copyItem(at: urls[0], to: destination)
        try FileManager.default.removeItem(at: urls[0])
        model.missingPaths = [urls[0].path]
        model.relocateMissing(from: model.photos[0], to: moved)
        XCTAssertEqual(model.photos[0].path, destination.path)
        XCTAssertEqual(model.peopleCatalog.analyses[0].sourcePath, destination.path)
        XCTAssertEqual(model.peopleCatalog.analyses[0].faces[0].personID, person.id)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        model.showPeople = true
        XCTAssertTrue(model.hasModalPresentation, "사람 시트가 열리면 전역 키 입력을 막는다")
    }
}

private enum MockPeopleError: LocalizedError {
    case failed

    var errorDescription: String? { "얼굴 모델을 불러오지 못했습니다." }
}

private final class LockedPeopleAnalyzer: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let body: @Sendable (URL, Int) throws -> [DetectedFace]

    init(body: @escaping @Sendable (URL, Int) throws -> [DetectedFace]) { self.body = body }

    var analyze: @Sendable (URL) throws -> [DetectedFace] {
        { [self] url in
            lock.lock(); count += 1; let call = count; lock.unlock()
            return try body(url, call)
        }
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class BlockingPeopleAnalyzer: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let result: [DetectedFace]
    private let lock = NSLock()
    private var count = 0

    init(result: [DetectedFace]) { self.result = result }

    var analyze: @Sendable (URL) throws -> [DetectedFace] {
        { [self] _ in
            lock.lock(); count += 1; lock.unlock()
            started.signal()
            release.wait()
            return result
        }
    }

    func waitUntilStarted() async throws {
        let result = await Task.detached { [self] in waitForStart() }.value
        if result == .timedOut { throw TestSupport.Timeout(label: "face analyzer start") }
    }

    private nonisolated func waitForStart() -> DispatchTimeoutResult {
        started.wait(timeout: .now() + 5)
    }

    func resume() { release.signal() }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
}
