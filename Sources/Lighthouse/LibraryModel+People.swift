import Foundation
import LighthouseCore

struct PeopleFaceItem: Identifiable, Equatable {
    let id: UUID
    let photoID: UUID
    let thumbnailJPEG: Data
    let fileName: String
    let personID: UUID?
    let personName: String?
}

private struct FaceSourceSignature: Equatable, Sendable {
    let size: Int64
    let modifiedAt: Date
}

private struct FaceScanTarget: Sendable {
    let id: UUID
    let path: String
}

@MainActor
extension LibraryModel {
    var sortedPeople: [PersonProfile] {
        peopleCatalog.people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var currentPeopleCatalog: PeopleCatalog {
        let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var catalog = peopleCatalog
        catalog.analyses = catalog.analyses.filter { analysis in
            byID[analysis.photoID]?.path == analysis.sourcePath
        }
        return catalog
    }

    func confirmedPhotoIDs(for personID: UUID) -> Set<UUID> {
        Set(currentPeopleCatalog.analyses.compactMap { analysis in
            analysis.faces.contains { $0.personID == personID } ? analysis.photoID : nil
        })
    }

    func confirmedPersonNames(for photoID: UUID) -> [String] {
        guard let analysis = currentPeopleCatalog.analyses.first(where: { $0.photoID == photoID }) else { return [] }
        let ids = Set(analysis.faces.compactMap(\.personID))
        return peopleCatalog.people.filter { ids.contains($0.id) }.map(\.name)
    }

    func photoIDsMatchingPersonName(_ search: String) -> Set<UUID> {
        let matchingPeople = Set(peopleCatalog.people.compactMap { person in
            person.name.localizedCaseInsensitiveContains(search) ? person.id : nil
        })
        guard !matchingPeople.isEmpty else { return [] }
        return Set(currentPeopleCatalog.analyses.compactMap { analysis in
            analysis.faces.contains { face in face.personID.map(matchingPeople.contains) == true }
                ? analysis.photoID : nil
        })
    }

    func peopleFaces(personID: UUID?) -> [PeopleFaceItem] {
        let names = Dictionary(uniqueKeysWithValues: peopleCatalog.people.map { ($0.id, $0.name) })
        return currentPeopleCatalog.analyses.flatMap { analysis -> [PeopleFaceItem] in
            guard let photo = photo(withID: analysis.photoID) else { return [] }
            return analysis.faces.compactMap { face in
                guard face.personID == personID else { return nil }
                return PeopleFaceItem(
                    id: face.id,
                    photoID: analysis.photoID,
                    thumbnailJPEG: face.thumbnailJPEG,
                    fileName: photo.displayName,
                    personID: face.personID,
                    personName: face.personID.flatMap { names[$0] }
                )
            }
        }
    }

    func candidateFaces(for personID: UUID) -> [PeopleFaceItem] {
        let catalog = currentPeopleCatalog
        let candidates = FaceMatching.candidates(
            for: personID,
            in: catalog,
            photoIDs: Set(photos.map(\.id))
        )
        let faces = Dictionary(uniqueKeysWithValues: catalog.analyses.flatMap { analysis in
            analysis.faces.map { ($0.id, (analysis.photoID, $0)) }
        })
        return candidates.compactMap { candidate in
            guard let (photoID, face) = faces[candidate.faceID], let photo = photo(withID: photoID) else { return nil }
            return PeopleFaceItem(
                id: face.id,
                photoID: photoID,
                thumbnailJPEG: face.thumbnailJPEG,
                fileName: photo.displayName,
                personID: nil,
                personName: nil
            )
        }
    }

    func validatedPersonName(_ name: String, excluding personID: UUID? = nil) -> Result<String, PeopleNameError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count) else { return .failure(.invalidLength) }
        let key = trimmed.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let duplicate = peopleCatalog.people.contains { person in
            person.id != personID && person.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) == key
        }
        return duplicate ? .failure(.duplicate) : .success(trimmed)
    }

    @discardableResult
    func createPerson(named name: String, assigning faceIDs: Set<UUID>) -> String? {
        guard peopleLoaded, peopleLoadError == nil else { return peopleLoadError ?? "사람 정보를 아직 열지 못했습니다." }
        let validated: String
        switch validatedPersonName(name) {
        case .success(let value): validated = value
        case .failure(let error): return error.localizedDescription
        }
        guard !faceIDs.isEmpty else { return "이름을 붙일 얼굴을 먼저 선택하세요." }
        let person = PersonProfile(name: validated)
        peopleCatalog.people.append(person)
        assignFaces(faceIDs, to: person.id, schedule: false)
        peopleCatalog.people.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        schedulePeopleSave()
        ensureSelectionVisible()
        return nil
    }

    func assignFaces(_ faceIDs: Set<UUID>, to personID: UUID, schedule: Bool = true) {
        guard peopleLoaded, peopleLoadError == nil,
              peopleCatalog.people.contains(where: { $0.id == personID }), !faceIDs.isEmpty else { return }
        var updated = peopleCatalog
        for analysisIndex in updated.analyses.indices {
            for faceIndex in updated.analyses[analysisIndex].faces.indices
            where faceIDs.contains(updated.analyses[analysisIndex].faces[faceIndex].id) {
                updated.analyses[analysisIndex].faces[faceIndex].personID = personID
                updated.analyses[analysisIndex].faces[faceIndex].rejectedPersonIDs.remove(personID)
            }
        }
        peopleCatalog = updated
        if schedule { schedulePeopleSave() }
        ensureSelectionVisible()
    }

    func unassignFace(_ faceID: UUID) {
        guard peopleLoaded, peopleLoadError == nil else { return }
        var updated = peopleCatalog
        for analysisIndex in updated.analyses.indices {
            guard let faceIndex = updated.analyses[analysisIndex].faces.firstIndex(where: { $0.id == faceID }) else { continue }
            if let oldPerson = updated.analyses[analysisIndex].faces[faceIndex].personID {
                updated.analyses[analysisIndex].faces[faceIndex].rejectedPersonIDs.insert(oldPerson)
            }
            updated.analyses[analysisIndex].faces[faceIndex].personID = nil
        }
        peopleCatalog = updated
        schedulePeopleSave()
        ensureSelectionVisible()
    }

    func rejectCandidate(_ faceID: UUID, for personID: UUID) {
        guard peopleLoaded, peopleLoadError == nil else { return }
        var updated = peopleCatalog
        for analysisIndex in updated.analyses.indices {
            guard let faceIndex = updated.analyses[analysisIndex].faces.firstIndex(where: { $0.id == faceID }),
                  updated.analyses[analysisIndex].faces[faceIndex].personID == nil else { continue }
            updated.analyses[analysisIndex].faces[faceIndex].rejectedPersonIDs.insert(personID)
        }
        peopleCatalog = updated
        schedulePeopleSave()
    }

    func renamePerson(_ personID: UUID, to name: String) -> String? {
        guard peopleLoaded, peopleLoadError == nil,
              let index = peopleCatalog.people.firstIndex(where: { $0.id == personID }) else { return "사람을 찾을 수 없습니다." }
        let validated: String
        switch validatedPersonName(name, excluding: personID) {
        case .success(let value): validated = value
        case .failure(let error): return error.localizedDescription
        }
        peopleCatalog.people[index].name = validated
        peopleCatalog.people.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        schedulePeopleSave()
        ensureSelectionVisible()
        return nil
    }

    func deletePerson(_ personID: UUID) {
        guard peopleLoaded, peopleLoadError == nil else { return }
        var updated = peopleCatalog
        updated.people.removeAll { $0.id == personID }
        for analysisIndex in updated.analyses.indices {
            for faceIndex in updated.analyses[analysisIndex].faces.indices {
                if updated.analyses[analysisIndex].faces[faceIndex].personID == personID {
                    updated.analyses[analysisIndex].faces[faceIndex].personID = nil
                }
                updated.analyses[analysisIndex].faces[faceIndex].rejectedPersonIDs.remove(personID)
            }
        }
        peopleCatalog = updated
        if filter == .person(personID) { filter = .all }
        schedulePeopleSave()
        ensureSelectionVisible()
        peopleMessage = "사람 이름만 삭제했습니다. 사진과 얼굴 분석 정보는 보관됩니다."
    }

    func clearPeopleAnalysis() async {
        guard peopleLoaded, peopleLoadError == nil, !isClearingPeople else { return }
        isClearingPeople = true
        defer { isClearingPeople = false }
        cancelFaceAnalysis()
        peopleCatalog = PeopleCatalog()
        if case .person = filter { filter = .all }
        ensureSelectionVisible()
        schedulePeopleSave()
        peopleMessage = "얼굴 분석 정보와 사람 이름을 모두 지웠습니다. 사진은 그대로입니다."
        await cancelFaceAnalysisAndWait()
        peopleMessage = "얼굴 분석 정보와 사람 이름을 모두 지웠습니다. 사진은 그대로입니다."
    }

    func showPhotos(for personID: UUID) {
        showPeople = false
        clearTemporaryFilters()
        filter = .person(personID)
        mode = .grid
        ensureSelectionVisible()
    }

    func openPeoplePhoto(_ photoID: UUID) {
        showPeople = false
        filter = .all
        clearTemporaryFilters()
        guard let photo = photo(withID: photoID) else { return }
        ensureSelectionVisible()
        focusPhoto(photo)
        setMode(.edit)
    }

    func startFaceAnalysis(selectedOnly: Bool) {
        guard catalogLoaded, loadError == nil, peopleLoaded, peopleLoadError == nil,
              !isAnalyzingFaces, !isClearingPeople else { return }
        let selected = selectedPhotoIDs
        let source = selectedOnly ? photos.filter { selected.contains($0.id) } : photos
        guard !source.isEmpty else {
            peopleMessage = selectedOnly ? "선택한 사진이 없습니다." : "분석할 사진이 없습니다."
            return
        }
        let targets = source.map { FaceScanTarget(id: $0.id, path: $0.path) }
        let previous = Dictionary(uniqueKeysWithValues: peopleCatalog.analyses.map { ($0.photoID, $0) })
        let cancellation = CancellationFlag()
        faceBatchGeneration += 1
        let generation = faceBatchGeneration
        faceCancellation = cancellation
        faceAnalysisCompleted = 0
        faceAnalysisTotal = targets.count
        isAnalyzingFaces = true
        isCancellingFaces = false
        peopleMessage = "얼굴 분석을 시작했습니다."
        let analyze: @Sendable (URL) throws -> [DetectedFace]
        if let faceAnalyzeOverride {
            analyze = faceAnalyzeOverride
        } else {
            let analyzer = faceAnalyzer
            let pipeline = facePipeline
            analyze = { try analyzer.analyze(url: $0, pipeline: pipeline) }
        }

        faceQueue.async {
            var failureCount = 0
            var failureReasons: [String] = []
            var foundFaces = 0
            var analyzedPhotos = 0
            var cachedPhotos = 0
            var changedSources = 0
            var cancelled = false
            for target in targets {
                if cancellation.isCancelled { cancelled = true; break }
                let url = URL(fileURLWithPath: target.path)
                guard let before = Self.faceSourceSignature(url) else {
                    let reason = "파일 정보를 읽을 수 없습니다."
                    failureCount += 1
                    if failureReasons.count < 3 { failureReasons.append("\(url.lastPathComponent): \(reason)") }
                    AppLog.catalog.error("face analysis failed for \(target.path, privacy: .private): \(reason, privacy: .private)")
                    self.commitFaceProgress(cancellation: cancellation, generation: generation)
                    continue
                }
                if let old = previous[target.id], old.sourcePath == target.path,
                   old.sourceSize == before.size, old.sourceModifiedAt == before.modifiedAt {
                    cachedPhotos += 1
                    self.commitFaceProgress(cancellation: cancellation, generation: generation)
                    continue
                }
                do {
                    let faces = try autoreleasepool { try analyze(url) }
                    guard let after = Self.faceSourceSignature(url), after == before else {
                        let reason = "분석 중 원본이 변경되었습니다."
                        failureCount += 1
                        if failureReasons.count < 3 { failureReasons.append("\(url.lastPathComponent): \(reason)") }
                        AppLog.catalog.error("face analysis failed for \(target.path, privacy: .private): \(reason, privacy: .private)")
                        self.commitFaceProgress(cancellation: cancellation, generation: generation)
                        continue
                    }
                    let accepted = self.commitFaceAnalysis(
                        PhotoFaceAnalysis(
                            photoID: target.id,
                            sourcePath: target.path,
                            sourceSize: before.size,
                            sourceModifiedAt: before.modifiedAt,
                            faces: faces
                        ),
                        cancellation: cancellation,
                        generation: generation
                    )
                    if accepted {
                        foundFaces += faces.count
                        analyzedPhotos += 1
                        if previous[target.id] != nil { changedSources += 1 }
                    }
                } catch {
                    let reason = error.localizedDescription
                    failureCount += 1
                    if failureReasons.count < 3 { failureReasons.append("\(url.lastPathComponent): \(reason)") }
                    AppLog.catalog.error("face analysis failed for \(target.path, privacy: .private): \(reason, privacy: .private)")
                    self.commitFaceProgress(cancellation: cancellation, generation: generation)
                }
            }
            DispatchQueue.main.async {
                guard self.faceCancellation === cancellation, self.faceBatchGeneration == generation else { return }
                self.faceCancellation = nil
                self.isAnalyzingFaces = false
                self.isCancellingFaces = false
                self.schedulePeopleSave()
                let failures = failureReasons.joined(separator: "; ")
                self.peopleMessage = cancelled
                    ? "얼굴 분석을 중지했습니다. 완료된 결과는 보관됩니다."
                    : "얼굴 분석 완료 · 새로 분석 \(analyzedPhotos)장 · 캐시 사용 \(cachedPhotos)장 · 새 얼굴 \(foundFaces)개" +
                        (failureCount == 0 ? "" : " · 실패 \(failureCount)장" + (failures.isEmpty ? "" : " (\(failures))")) +
                        (changedSources > 0 ? " · 원본이 바뀐 \(changedSources)장은 다시 이름을 붙여야 합니다." : "")
                let waiters = self.faceCompletionWaiters
                self.faceCompletionWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }

    func cancelFaceAnalysis() {
        guard isAnalyzingFaces else { return }
        isCancellingFaces = true
        faceCancellation?.cancel()
    }

    func cancelFaceAnalysisAndWait() async {
        guard isAnalyzingFaces else { isCancellingFaces = false; return }
        cancelFaceAnalysis()
        await withCheckedContinuation { continuation in
            faceCompletionWaiters.append(continuation)
        }
    }

    private nonisolated static func faceSourceSignature(_ url: URL) -> FaceSourceSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        return FaceSourceSignature(size: size.int64Value, modifiedAt: modifiedAt)
    }

    private nonisolated func commitFaceProgress(cancellation: CancellationFlag, generation: Int) {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard faceCancellation === cancellation, faceBatchGeneration == generation else { return }
                faceAnalysisCompleted += 1
            }
        }
    }

    private nonisolated func commitFaceAnalysis(
        _ analysis: PhotoFaceAnalysis,
        cancellation: CancellationFlag,
        generation: Int
    ) -> Bool {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                defer {
                    if faceCancellation === cancellation, faceBatchGeneration == generation {
                        faceAnalysisCompleted += 1
                    }
                }
                guard faceCancellation === cancellation, faceBatchGeneration == generation, !isClearingPeople,
                      let current = photo(withID: analysis.photoID), current.path == analysis.sourcePath else { return false }
                var updated = peopleCatalog
                updated.analyses.removeAll { $0.photoID == analysis.photoID }
                var unique = analysis
                var used = Set(updated.analyses.flatMap { $0.faces.map(\.id) })
                for index in unique.faces.indices where !used.insert(unique.faces[index].id).inserted {
                    unique.faces[index].id = UUID()
                    used.insert(unique.faces[index].id)
                }
                updated.analyses.append(unique)
                peopleCatalog = updated
                ensureSelectionVisible()
                schedulePeopleSave(debounce: true)
                return true
            }
        }
    }

    func schedulePeopleSave(debounce: Bool = false) {
        guard peopleLoaded, peopleLoadError == nil else { return }
        peopleSaveDirty = true
        peopleSaveRevision &+= 1
        if !debounce { peopleSaveUrgent = true }
        guard !peopleSaveScheduled, !peopleSaveInFlight else { return }
        peopleSaveScheduled = true
        let item = DispatchWorkItem { [weak self] in self?.savePeopleNow() }
        peopleSaveDelay = item
        let delay = peopleSaveUrgent ? 0.05 : 1.0
        peopleSaveUrgent = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func savePeopleNow() {
        peopleSaveScheduled = false
        guard peopleLoaded, peopleLoadError == nil, peopleSaveDirty, !peopleSaveInFlight else { return }
        peopleSaveDirty = false
        peopleSaveInFlight = true
        let snapshot = peopleCatalog
        let revision = peopleSaveRevision
        saveQueue.async { [peopleStore] in
            let result = Result { try peopleStore.save(snapshot) }
            DispatchQueue.main.async {
                self.peopleSaveInFlight = false
                switch result {
                case .success:
                    if revision == self.peopleSaveRevision, !self.peopleSaveDirty { self.peopleSaveError = nil }
                case .failure(let error):
                    AppLog.catalog.error("people save failed: \(error.localizedDescription, privacy: .private)")
                    if revision == self.peopleSaveRevision {
                        self.peopleSaveError = "사람 정보 저장 실패: \(error.localizedDescription)"
                        self.peopleMessage = self.peopleSaveError
                    }
                }
                if self.peopleSaveDirty { self.schedulePeopleSave(debounce: !self.peopleSaveUrgent) }
            }
        }
    }
}

enum PeopleNameError: LocalizedError {
    case invalidLength
    case duplicate

    var errorDescription: String? {
        switch self {
        case .invalidLength: "이름은 공백을 제외하고 1–80자여야 합니다."
        case .duplicate: "같은 이름의 사람이 이미 있습니다."
        }
    }
}
