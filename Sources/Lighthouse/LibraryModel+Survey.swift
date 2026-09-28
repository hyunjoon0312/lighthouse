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

    /// 보정·경로·선택 세대가 현재 상태와 일치하는 사진만 캐시한다.
    func requestSurveyImages() {
        guard mode == .survey else {
            invalidateSurveyImages(clearAll: true)
            return
        }
        let photos = surveyPhotos
        let state = photos.map { SurveyRequestKey(photoID: $0.id, path: $0.path, edits: $0.edits) }
        if state != surveyState {
            surveyGeneration += 1
            surveyState = state
            surveyRequests.removeAll()
            surveyLoadingIDs.removeAll()
        }
        let ids = Set(state.map(\.photoID))
        surveyImages = surveyImages.filter { ids.contains($0.key) }
        surveyRenderedEdits = surveyRenderedEdits.filter { ids.contains($0.key) }
        surveyRenderedPaths = surveyRenderedPaths.filter { ids.contains($0.key) }
        surveyErrors = surveyErrors.filter { ids.contains($0.key) }
        surveyFailedRequests = surveyFailedRequests.filter { ids.contains($0.key) }

        var pending: [(PhotoAsset, SurveyRequestKey)] = []
        for photo in photos {
            let key = SurveyRequestKey(photoID: photo.id, path: photo.path, edits: photo.edits)
            if surveyRenderedEdits[photo.id] == photo.edits,
               surveyRenderedPaths[photo.id] == photo.path,
               surveyImages[photo.id] != nil { continue }
            if surveyRequests[photo.id] == key || surveyFailedRequests[photo.id] == key { continue }
            surveyImages.removeValue(forKey: photo.id)
            surveyRenderedEdits.removeValue(forKey: photo.id)
            surveyRenderedPaths.removeValue(forKey: photo.id)
            surveyErrors.removeValue(forKey: photo.id)
            surveyRequests[photo.id] = key
            surveyLoadingIDs.insert(photo.id)
            pending.append((photo, key))
        }
        guard !pending.isEmpty else { return }
        let generation = surveyGeneration
        let size = Self.surveyPixels
        surveyQueue.async { [pipeline, pending] in
            for (photo, key) in pending {
                guard DispatchQueue.main.sync(execute: {
                    generation == self.surveyGeneration && self.surveyRequests[photo.id] == key
                }) else { return }
                let result = Result { try pipeline.renderPreview(url: photo.url, edits: photo.edits, maxPixel: size).image }
                DispatchQueue.main.async {
                    guard generation == self.surveyGeneration,
                          self.mode == .survey,
                          self.surveyRequests[photo.id] == key,
                          self.surveyPhotos.contains(where: { $0.id == photo.id }),
                          let latest = self.photo(withID: photo.id),
                          latest.path == key.path, latest.edits == key.edits else { return }
                    self.surveyRequests.removeValue(forKey: photo.id)
                    self.surveyLoadingIDs.remove(photo.id)
                    switch result {
                    case .success(let image):
                        self.surveyImages[photo.id] = NSImage(cgImage: image,
                                                             size: NSSize(width: image.width, height: image.height))
                        self.surveyRenderedEdits[photo.id] = key.edits
                        self.surveyRenderedPaths[photo.id] = key.path
                        self.surveyErrors.removeValue(forKey: photo.id)
                        self.surveyFailedRequests.removeValue(forKey: photo.id)
                    case .failure(let error):
                        self.surveyErrors[photo.id] = error.localizedDescription
                        self.surveyFailedRequests[photo.id] = key
                    }
                }
            }
        }
    }

    func retrySurveyImage(_ id: UUID) {
        guard mode == .survey, surveyPhotos.contains(where: { $0.id == id }) else { return }
        surveyErrors.removeValue(forKey: id)
        surveyFailedRequests.removeValue(forKey: id)
        surveyRequests.removeValue(forKey: id)
        surveyLoadingIDs.remove(id)
        requestSurveyImages()
    }

    func invalidateSurveyImages(clearAll: Bool = false) {
        surveyGeneration += 1
        surveyRequests.removeAll()
        surveyLoadingIDs.removeAll()
        surveyState = []
        guard clearAll else { return }
        surveyImages = [:]
        surveyRenderedEdits = [:]
        surveyRenderedPaths = [:]
        surveyErrors = [:]
        surveyFailedRequests = [:]
    }

    /// 여러 장 보기의 ←/→. 비교 중인 사진 안에서만 기준 사진을 옮긴다.
    func moveInSurvey(_ direction: Int) {
        let photos = surveyPhotos
        guard !photos.isEmpty else { return }
        let index = photos.firstIndex { $0.id == selectedID } ?? 0
        focusPhoto(photos[(index + direction + photos.count) % photos.count])
    }
}
