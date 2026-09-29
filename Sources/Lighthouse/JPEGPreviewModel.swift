import AppKit
import Foundation
import LighthouseCore

@MainActor
final class JPEGPreviewModel: ObservableObject {
    @Published private(set) var preview: PreparedJPEGExport?
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?

    private let pipeline: ImagePipeline
    private let queue = DispatchQueue(label: "com.rian.lighthouse.jpeg-preview", qos: .userInitiated)
    private var generation = 0
    private var workItem: DispatchWorkItem?

    init(lutDirectory: URL = LUTStore.defaultDirectory) {
        pipeline = ImagePipeline(lutDirectory: lutDirectory)
    }

    func request(photo: PhotoAsset?, options: ExportOptions, debounce: Bool = true) {
        workItem?.cancel()
        generation += 1
        let token = generation
        preview = nil
        error = nil
        guard let photo else { isPreparing = false; return }
        isPreparing = true
        // 백그라운드 큐에서 돈다. @Sendable로 표시해 화면 상태를 여기서 건드리지 않는지 컴파일러가 검사하게 한다.
        let job = DispatchWorkItem { @Sendable [weak self, pipeline] in
            let result = Result {
                try pipeline.prepareExport(url: photo.url, edits: photo.edits, options: options,
                                           keywords: photo.keywords, caption: photo.caption)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.isPreparing = false
                switch result {
                case .success(let jpeg):
                    self.preview = PreparedJPEGExport(photoID: photo.id, edits: photo.edits, keywords: photo.keywords,
                                                      caption: photo.caption, options: options, result: jpeg)
                case .failure(let error):
                    AppLog.export.error("export preview failed: \(error.localizedDescription, privacy: .private)")
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
