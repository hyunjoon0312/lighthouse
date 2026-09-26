import Foundation
import LighthouseCore

/// XMP 사이드카. 켜 둔 동안 별점·라벨·키워드·설명이 바뀌면 잠시 모았다가 백그라운드에서 쓴다.
@MainActor
extension LibraryModel {
    /// 사이드카를 쓸 사진. 가상 사본은 원본이 하나라 빼고, RAW와 같은 이름의 JPEG·HEIC는 RAW의 사이드카를 함께 쓰므로 뺀다.
    func sidecarTargets(_ ids: Set<UUID>) -> [PhotoAsset] {
        let companions = RAWJPEGPairs.companions(in: photos)
        return photos.filter { ids.contains($0.id) && !$0.isVirtualCopy && companions[$0.id] == nil }
    }

    func scheduleSidecarWrite(_ id: UUID) {
        guard writesXMPSidecars else { return }
        pendingSidecarIDs.insert(id)
        sidecarDelay?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = self.pendingSidecarIDs
            self.pendingSidecarIDs = []
            self.writeSidecars(self.sidecarTargets(ids), announce: false)
        }
        sidecarDelay = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func writeAllSidecars() {
        writeSidecars(sidecarTargets(Set(photos.map(\.id))), announce: true)
    }

    /// 다른 프로그램의 사이드카를 건너뛰었거나 실패했으면 알린다. `announce`이면 결과를 항상 알린다.
    private func writeSidecars(_ targets: [PhotoAsset], announce: Bool) {
        guard !targets.isEmpty else { return }
        sidecarQueue.async {
            var written = 0, foreign = 0
            var failures: [String] = []
            for photo in targets {
                switch XMPSidecar.write(photo) {
                case .written: written += 1
                case .unchanged: break
                case .foreign: foreign += 1
                case .failed(let reason): failures.append("\(photo.filename): \(reason)")
                }
            }
            let failed = failures.count
            DispatchQueue.main.async {
                if failed > 0 { AppLog.files.error("xmp sidecar failed for \(failed, privacy: .public) photos") }
                guard announce || foreign > 0 || !failures.isEmpty else { return }
                self.operationMessage = "XMP 사이드카 \(written)개 씀" +
                    (foreign > 0 ? " · 다른 프로그램이 만든 사이드카 \(foreign)개는 덮어쓰지 않음" : "") +
                    (failures.isEmpty ? "" : " · 쓰지 못함 \(failures.count)개\n" + failures.prefix(3).joined(separator: "\n"))
            }
        }
    }
}
