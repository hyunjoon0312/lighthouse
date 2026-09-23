import AppKit
import Foundation
import LighthouseCore

@MainActor
final class JPEGPreviewModel: ObservableObject {
    @Published private(set) var preview: PreparedJPEGExport?
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?

    private let pipeline = ImagePipeline()
    private let queue = DispatchQueue(label: "com.rian.lighthouse.jpeg-preview", qos: .userInitiated)
    private var generation = 0
    private var workItem: DispatchWorkItem?

    func request(photo: PhotoAsset?, maxPixel: Int?, quality: Double, debounce: Bool = true) {
        workItem?.cancel()
        generation += 1
        let token = generation
        preview = nil
        error = nil
        guard let photo else { isPreparing = false; return }
        isPreparing = true
        let job = DispatchWorkItem { [weak self, pipeline] in
            let result = Result {
                try pipeline.prepareJPEG(url: photo.url, edits: photo.edits,
                                         maxPixel: maxPixel, quality: quality)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.isPreparing = false
                switch result {
                case .success(let jpeg):
                    self.preview = PreparedJPEGExport(photoID: photo.id, edits: photo.edits,
                                                      maxPixel: maxPixel, quality: quality,
                                                      result: jpeg)
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
        workItem = job
        queue.asyncAfter(deadline: .now() + (debounce ? 0.28 : 0), execute: job)
    }

    func cancel() {
        workItem?.cancel()
        generation += 1
        isPreparing = false
    }
}
