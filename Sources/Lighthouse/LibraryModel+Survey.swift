import AppKit
import Foundation
import LighthouseCore

/// 여러 장 보기(N): 선택한 사진을 한 화면에 나란히 놓고 고른다.
@MainActor
extension LibraryModel {
    static let surveyLimit = 12
    static let surveyPixels = 1400

    /// 여러 장 보기에 놓는 사진. 선택한 사진을 목록 순서대로 최대 12장.
    var surveyPhotos: [PhotoAsset] { Array(selectedPhotos.prefix(Self.surveyLimit)) }

    /// 보정이 바뀌었거나 아직 그리지 않은 사진만 차례로 그린다. 빠진 사진의 그림은 버린다.
    func requestSurveyImages() {
        guard mode == .survey else {
            if !surveyImages.isEmpty { surveyImages = [:]; surveyRenderedEdits = [:] }
            return
        }
        let photos = surveyPhotos
        let ids = Set(photos.map(\.id))
        if surveyImages.keys.contains(where: { !ids.contains($0) }) {
            surveyImages = surveyImages.filter { ids.contains($0.key) }
            surveyRenderedEdits = surveyRenderedEdits.filter { ids.contains($0.key) }
        }
        let stale = photos.filter { surveyRenderedEdits[$0.id] != $0.edits }
        guard !stale.isEmpty else { return }
        surveyGeneration += 1
        let generation = surveyGeneration
        let size = Self.surveyPixels
        surveyQueue.async { [pipeline] in
            for photo in stale {
                guard DispatchQueue.main.sync(execute: { generation == self.surveyGeneration }) else { return }
                let image = try? pipeline.renderPreview(url: photo.url, edits: photo.edits, maxPixel: size).image
                DispatchQueue.main.async {
                    guard self.mode == .survey, let latest = self.photo(withID: photo.id), latest.edits == photo.edits,
                          self.selectedPhotoIDs.contains(photo.id) else { return }
                    self.surveyRenderedEdits[photo.id] = photo.edits
                    if let image { self.surveyImages[photo.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
                }
            }
        }
    }

    /// 여러 장 보기의 ←/→. 비교 중인 사진 안에서만 기준 사진을 옮긴다.
    func moveInSurvey(_ direction: Int) {
        let photos = surveyPhotos
        guard !photos.isEmpty else { return }
        let index = photos.firstIndex { $0.id == selectedID } ?? 0
        focusPhoto(photos[(index + direction + photos.count) % photos.count])
    }
}
