import Foundation
import LighthouseCore

private struct SidecarWriteRequest: Sendable {
    let photo: PhotoAsset
    let version: UInt64
}

private struct SidecarWriteResult: Sendable {
    let request: SidecarWriteRequest
    let outcome: XMPSidecar.Outcome
}

private struct SidecarFlushError: LocalizedError {
    let failures: [String]

    var errorDescription: String? {
        "XMP 사이드카를 저장하지 못했습니다: " + failures.prefix(3).joined(separator: " · ")
    }
}

/// XMP 사이드카. 켜 둔 동안 별점·라벨·키워드·설명이 바뀌면 잠시 모았다가 백그라운드에서 쓴다.
@MainActor
extension LibraryModel {
    /// 사이드카를 쓸 사진. `<이름>.xmp` 사이드카는 RAW의 방식이라(Lightroom 등은 JPEG·HEIC에서 파일 안의 XMP를 읽는다)
    /// RAW만 쓰고, 가상 사본은 원본이 하나라 뺀다. RAW+JPEG는 RAW 쪽 한 파일이 된다.
    func sidecarTargets(_ ids: Set<UUID>) -> [PhotoAsset] {
        photos.filter { ids.contains($0.id) && $0.isRAW && !$0.isVirtualCopy }
    }

    func scheduleSidecarWrite(_ id: UUID) {
        guard writesXMPSidecars, let photo = photo(withID: id), photo.isRAW, !photo.isVirtualCopy else { return }
        pendingSidecarIDs.insert(id)
        dirtySidecarIDs.insert(id)
        sidecarVersions[id, default: 0] &+= 1
        sidecarDelay?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = self.pendingSidecarIDs
            self.pendingSidecarIDs.subtract(ids)
            self.enqueueSidecarWrites(self.sidecarRequests(ids), announce: false)
        }
        sidecarDelay = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func writeAllSidecars() {
        guard writesXMPSidecars else { return }
        let ids = Set(sidecarTargets(Set(photos.map(\.id))).map(\.id))
        markSidecarsDirty(ids)
        enqueueSidecarWrites(sidecarRequests(ids), announce: true)
    }

    func disableSidecarWrites() {
        sidecarDelay?.cancel()
        sidecarDelay = nil
        pendingSidecarIDs.removeAll()
        dirtySidecarIDs.removeAll()
        sidecarQueue.sync {}
    }

    /// 대기 중인 이전 쓰기를 먼저 끝낸 뒤, 종료를 요청한 시점의 최신 표시를 동기적으로 쓴다.
    func flushSidecars() throws {
        sidecarDelay?.cancel()
        sidecarDelay = nil
        guard writesXMPSidecars else {
            pendingSidecarIDs.removeAll()
            dirtySidecarIDs.removeAll()
            sidecarQueue.sync {}
            return
        }

        let requestedIDs = pendingSidecarIDs.union(dirtySidecarIDs)
        // 이미 큐에 들어간 같은 표시의 완료 콜백도 이번 종료 쓰기의 결과를 덮지 못하게 한다.
        markSidecarsDirty(requestedIDs)
        let requests = sidecarRequests(requestedIDs)
        let validIDs = Set(requests.map { $0.photo.id })
        pendingSidecarIDs.subtract(requestedIDs)
        dirtySidecarIDs.subtract(requestedIDs.subtracting(validIDs))
        let results = sidecarQueue.sync { Self.writeSidecarRequests(requests) }
        finishSidecarWrites(results, announce: false)
        let failures = results.compactMap { result -> String? in
            guard case .failed(let reason) = result.outcome else { return nil }
            pendingSidecarIDs.insert(result.request.photo.id)
            dirtySidecarIDs.insert(result.request.photo.id)
            return "\(result.request.photo.filename): \(reason)"
        }
        if !failures.isEmpty { throw SidecarFlushError(failures: failures) }
    }

    private func markSidecarsDirty(_ ids: Set<UUID>) {
        for id in ids {
            dirtySidecarIDs.insert(id)
            sidecarVersions[id, default: 0] &+= 1
        }
    }

    private func sidecarRequests(_ ids: Set<UUID>) -> [SidecarWriteRequest] {
        sidecarTargets(ids).map { SidecarWriteRequest(photo: $0, version: sidecarVersions[$0.id, default: 0]) }
    }

    /// 다른 프로그램의 사이드카를 건너뛰었거나 실패했으면 알린다. `announce`이면 결과를 항상 알린다.
    private func enqueueSidecarWrites(_ requests: [SidecarWriteRequest], announce: Bool) {
        guard !requests.isEmpty else {
            if announce { operationMessage = "XMP 사이드카 0개 씀" }
            return
        }
        sidecarWritesInFlight += requests.count
        sidecarQueue.async {
            let results = Self.writeSidecarRequests(requests)
            DispatchQueue.main.async {
                self.sidecarWritesInFlight -= requests.count
                self.finishSidecarWrites(results, announce: announce)
            }
        }
    }

    nonisolated private static func writeSidecarRequests(_ requests: [SidecarWriteRequest]) -> [SidecarWriteResult] {
        requests.map { SidecarWriteResult(request: $0, outcome: XMPSidecar.write($0.photo)) }
    }

    private func finishSidecarWrites(_ results: [SidecarWriteResult], announce: Bool) {
        guard writesXMPSidecars else { return }
        var currentResults = 0, written = 0, foreign = 0
        var failures: [String] = []
        for result in results {
            let request = result.request
            guard sidecarVersions[request.photo.id] == request.version,
                  !pendingSidecarIDs.contains(request.photo.id),
                  let current = photo(withID: request.photo.id),
                  current.marks == request.photo.marks else { continue }
            currentResults += 1
            switch result.outcome {
            case .written:
                written += 1
                dirtySidecarIDs.remove(request.photo.id)
            case .unchanged:
                dirtySidecarIDs.remove(request.photo.id)
            case .foreign:
                foreign += 1
                dirtySidecarIDs.remove(request.photo.id)
            case .failed(let reason):
                failures.append("\(request.photo.filename): \(reason)")
                dirtySidecarIDs.insert(request.photo.id)
            }
        }
        guard currentResults > 0 else { return }
        if !failures.isEmpty {
            AppLog.files.error("xmp sidecar failed for \(failures.count, privacy: .public) photos")
        }
        guard announce || foreign > 0 || !failures.isEmpty else { return }
        operationMessage = "XMP 사이드카 \(written)개 씀" +
            (foreign > 0 ? " · 다른 프로그램이 만든 사이드카 \(foreign)개는 덮어쓰지 않음" : "") +
            (failures.isEmpty ? "" : " · 쓰지 못함 \(failures.count)개\n" + failures.prefix(3).joined(separator: "\n"))
    }
}
