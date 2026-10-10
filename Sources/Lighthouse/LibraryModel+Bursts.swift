import Foundation
import LighthouseCore

/// 연속 촬영 묶음과 베스트 컷 분석·추천.
@MainActor
extension LibraryModel {
    // MARK: 연속 촬영

    /// 보정·별점만 바뀐 경우는 다시 묶지 않는다. 사진 5000장에서 묶기는 약 25ms, 이 비교는 약 1ms다.
    var burstIndex: BurstIndex {
        let signature = structureSignature
        if let burstCache, burstCache.signature == signature { return burstCache.index }
        var index = BurstIndex(groups: BurstGrouping.groups(for: photos))
        for (groupIndex, group) in index.groups.enumerated() {
            for (shotIndex, shot) in group.shots.enumerated() {
                for id in shot { index.positions[id] = (groupIndex, shotIndex) }
            }
        }
        burstCache = (signature, index)
        burstRecommendationCache = nil
        return index
    }

    /// 모든 컷을 분석했거나 읽지 못한 묶음만 추천한다. 분석을 중간에 멈춘 묶음은 일부 컷만 보고 고르지 않는다.
    var burstRecommendations: [UUID: BurstRecommendation] {
        if let burstRecommendationCache { return burstRecommendationCache }
        var computed: [UUID: BurstRecommendation] = [:]
        if !burstQualities.isEmpty {
            for group in burstIndex.groups where isBurstAnalyzed(group) {
                if let recommendation = BurstRanking.recommend(group, qualities: burstQualities) {
                    computed[group.id] = recommendation
                }
            }
        }
        burstRecommendationCache = computed
        return computed
    }

    private func isBurstAnalyzed(_ group: BurstGroup) -> Bool {
        group.shots.allSatisfy { shot in
            shot.contains { burstQualities[$0] != nil || burstFailedIDs.contains($0) }
        }
    }

    func burstBadge(for photo: PhotoAsset) -> BurstBadge? {
        guard let position = burstIndex.positions[photo.id] else { return nil }
        let group = burstIndex.groups[position.group]
        let recommendation = burstRecommendations[group.id]
        return BurstBadge(shot: position.shot + 1, count: group.shots.count,
                          isBest: recommendation.map { $0.bestShot == position.shot },
                          eyesClosed: recommendation?.closedEyeShots.contains(position.shot) ?? false)
    }

    /// 지금 목록에 한 장이라도 보이는 묶음.
    private var visibleBurstGroups: [BurstGroup] {
        let visible = Set(visiblePhotos.map(\.id))
        return burstIndex.groups.filter { $0.photoIDs.contains(where: visible.contains) }
    }

    /// 보이는 묶음의 컷마다 원본 미리보기 한 장(RAW+JPEG이면 RAW)을 기기 안에서 분석한다.
    /// 선명도와 Vision 얼굴 촬영 품질만 계산하며 원본·표시·보정은 바꾸지 않는다.
    func analyzeBursts() {
        guard catalogLoaded, loadError == nil, !isAnalyzingBursts else { return }
        let groups = visibleBurstGroups
        guard !groups.isEmpty else { burstMessage = "지금 목록에 연속 촬영 묶음이 없습니다."; return }
        let targets: [(id: UUID, url: URL)] = groups.flatMap(\.shots).compactMap { shot in
            guard !shot.contains(where: { burstQualities[$0] != nil }) else { return nil }
            let members = shot.compactMap { photo(withID: $0) }
            guard let chosen = members.first(where: \.isRAW) ?? members.first else { return nil }
            return (chosen.id, chosen.url)
        }
        guard !targets.isEmpty else { burstMessage = burstSummary(groups, failed: 0, cancelled: false); return }
        isAnalyzingBursts = true
        burstAnalysisProgress = 0
        burstMessage = "연속 촬영 \(groups.count)묶음 분석 중…"
        let cancellation = CancellationFlag()
        burstCancellation = cancellation
        burstQueue.async { [pipeline] in
            var failed = 0
            var cancelled = false
            for (index, target) in targets.enumerated() {
                if cancellation.isCancelled { cancelled = true; break }
                let quality = try? PhotoQualityAnalyzer.analyze(url: target.url, pipeline: pipeline)
                if quality == nil { failed += 1 }
                let progress = Double(index + 1) / Double(targets.count)
                DispatchQueue.main.async {
                    guard self.burstCancellation === cancellation else { return }
                    if let quality {
                        self.burstQualities[target.id] = quality
                        self.burstFailedIDs.remove(target.id)
                    } else {
                        self.burstFailedIDs.insert(target.id)
                    }
                    self.burstAnalysisProgress = progress
                }
            }
            DispatchQueue.main.async {
                guard self.burstCancellation === cancellation else { return }
                self.burstCancellation = nil
                self.isAnalyzingBursts = false
                self.burstMessage = self.burstSummary(groups, failed: failed, cancelled: cancelled)
            }
        }
    }

    /// 지금 분석 중인 한 장은 끝까지 하고 나머지를 건너뛴다. 이미 분석한 결과는 남긴다.
    func cancelBurstAnalysis() {
        burstCancellation?.cancel()
    }

    private func burstSummary(_ groups: [BurstGroup], failed: Int, cancelled: Bool) -> String {
        let recommendations = burstRecommendations
        let analyzed = groups.filter { recommendations[$0.id] != nil }
        let unfinished = groups.filter { !isBurstAnalyzed($0) }.count
        let faceGroups = analyzed.filter { recommendations[$0.id]?.usedFaces == true }.count
        let noFaceModel = groups.flatMap(\.photoIDs).contains { burstQualities[$0].map { $0.faceQualities == nil } ?? false }
        return "연속 촬영 \(groups.count)묶음 중 \(analyzed.count)묶음 추천 완료" +
            (unfinished > 0 ? " · 분석이 끝나지 않은 \(unfinished)묶음은 추천하지 않음" : "") +
            (faceGroups > 0 ? " · 얼굴 반영 \(faceGroups)묶음" : "") +
            (failed > 0 ? " · 읽지 못한 컷 \(failed)장은 표시하지 않음" : "") +
            (noFaceModel ? " · 얼굴 분석을 쓸 수 없어 선명도만 반영한 컷이 있음" : "") +
            (cancelled ? " · 중지함" : "")
    }

    /// 보이는 묶음의 추천 컷만 선택한다. RAW+JPEG이면 두 파일을 함께 선택한다.
    func selectBurstRecommendations() {
        let recommendations = burstRecommendations
        var picks = Set<UUID>()
        for group in visibleBurstGroups {
            guard let recommendation = recommendations[group.id] else { continue }
            picks.formUnion(group.shots[recommendation.bestShot])
        }
        let ordered = visiblePhotos.map(\.id).filter(picks.contains)
        guard !ordered.isEmpty else { burstMessage = "먼저 연속 촬영을 분석하세요."; return }
        let previous = selectedID
        photoSelection.selectAll(in: ordered)
        selectionDidChange(previousActive: previous)
        burstMessage = "추천 컷 \(ordered.count)장을 선택했습니다."
    }

    /// 분석한 묶음에서 추천 컷은 채택(P), 나머지는 제외(X)로 표시한다. 이미 표시한 사진은 그대로 둔다.
    /// 한 번에 실행 취소된다.
    func markBurstRecommendations() {
        guard catalogLoaded, loadError == nil else { return }
        let recommendations = burstRecommendations
        let visible = Set(visiblePhotos.map(\.id))
        var changes: [PhotoMarkChange] = []
        for group in visibleBurstGroups {
            guard let recommendation = recommendations[group.id] else { continue }
            for (shotIndex, shot) in group.shots.enumerated() where recommendation.scores[shotIndex] != nil {
                for id in shot where visible.contains(id) {
                    guard let photo = photo(withID: id), photo.flag == .none else { continue }
                    let before = photo.marks
                    var after = before
                    after.flag = shotIndex == recommendation.bestShot ? .pick : .reject
                    changes.append(PhotoMarkChange(id: id, before: before, after: after))
                }
            }
        }
        let unfinished = visibleBurstGroups.filter { !isBurstAnalyzed($0) }.count
        let skipped = unfinished > 0 ? " 분석이 끝나지 않은 \(unfinished)묶음은 건너뛰었습니다. ‘베스트 컷 분석’을 다시 누르면 남은 컷만 분석합니다." : ""
        guard !changes.isEmpty else {
            burstMessage = (recommendations.isEmpty && unfinished == 0 ? "먼저 연속 촬영을 분석하세요." :
                            recommendations.isEmpty ? "추천할 수 있는 묶음이 없습니다." :
                            "새로 표시할 사진이 없습니다. 이미 표시한 사진은 바꾸지 않습니다.") + skipped
            return
        }
        editHistory.recordMarks(changes)
        let flags = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0.after.flag) })
        var updated = photos
        for index in updated.indices { if let flag = flags[updated[index].id] { updated[index].flag = flag } }
        photos = updated
        scheduleSave()
        ensureSelectionVisible()
        let picks = changes.filter { $0.after.flag == .pick }.count
        burstMessage = "추천 \(picks)장 선택 · \(changes.count - picks)장 제외로 표시했습니다. ⌘Z로 되돌릴 수 있습니다." + skipped
    }
}
