import AppKit
import Foundation
import LighthouseCore
import UniformTypeIdentifiers

@MainActor
final class ReferenceMatchModel: ObservableObject {
    @Published private(set) var referenceName: String?
    @Published private(set) var sourcePreview: NSImage?
    @Published private(set) var referencePreview: NSImage?
    @Published private(set) var matchedPreview: NSImage?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isPreviewUpdating = false
    @Published private(set) var isWriting = false
    @Published private(set) var isPreviewValid = false
    @Published var strength = 1.0
    @Published var lutName = ""
    @Published var errorMessage: String?
    @Published var successMessage: String?

    let source: PhotoAsset
    private let matcher = ReferenceColorMatcher()
    private let lutStore = LUTStore()
    private let queue = DispatchQueue(label: "com.rian.lighthouse.reference-match", qos: .userInitiated)
    private var result: ReferenceMatchResult?
    private var analysisGeneration = 0
    private var previewGeneration = 0

    init(source: PhotoAsset) {
        self.source = source
    }

    var canWrite: Bool {
        result != nil && isPreviewValid && !isAnalyzing && !isPreviewUpdating && !isWriting &&
            !lutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func chooseReference() {
        guard !isWriting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "참조 사진 선택"
        panel.allowedContentTypes = ImagePipeline.supportedExtensions.sorted().compactMap {
            UTType(filenameExtension: $0)
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.analyze(url) }
        }
    }

    private func analyze(_ url: URL) {
        analysisGeneration += 1
        previewGeneration += 1
        let token = analysisGeneration
        result = nil
        sourcePreview = nil
        referencePreview = nil
        matchedPreview = nil
        isPreviewValid = false
        referenceName = url.lastPathComponent
        lutName = "참조 색감 · \(url.deletingPathExtension().lastPathComponent)"
        strength = 1
        errorMessage = nil
        successMessage = nil
        isAnalyzing = true
        isPreviewUpdating = false
        let source = source
        let matcher = matcher
        queue.async {
            let outcome = Result { () throws -> (ReferenceMatchResult, CGImage) in
                let result = try matcher.analyze(source: source, referenceURL: url)
                return (result, try matcher.preview(result: result, strength: 1))
            }
            DispatchQueue.main.async {
                guard self.analysisGeneration == token else { return }
                self.isAnalyzing = false
                switch outcome {
                case .success(let (result, preview)):
                    self.result = result
                    self.sourcePreview = Self.image(result.sourcePreview)
                    self.referencePreview = Self.image(result.referencePreview)
                    self.matchedPreview = Self.image(preview)
                    self.isPreviewValid = true
                case .failure(let error):
                    self.isPreviewValid = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateStrength() {
        previewGeneration += 1
        let previewToken = previewGeneration
        let analysisToken = analysisGeneration
        guard let result else { return }
        let strength = strength
        let matcher = matcher
        isPreviewUpdating = true
        isPreviewValid = false
        errorMessage = nil
        successMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) {
            guard self.analysisGeneration == analysisToken,
                  self.previewGeneration == previewToken else { return }
            self.queue.async {
                let outcome = Result { try matcher.preview(result: result, strength: strength) }
                DispatchQueue.main.async {
                    guard self.analysisGeneration == analysisToken,
                          self.previewGeneration == previewToken else { return }
                    self.isPreviewUpdating = false
                    switch outcome {
                    case .success(let preview):
                        self.matchedPreview = Self.image(preview)
                        self.isPreviewValid = true
                    case .failure(let error):
                        self.isPreviewValid = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func store(apply: Bool, onStored: @escaping (LUTAdjustment, Bool) -> Void) {
        guard canWrite, let result else { return }
        let name = lutName.trimmingCharacters(in: .whitespacesAndNewlines)
        let strength = strength
        let token = analysisGeneration
        let store = lutStore
        errorMessage = nil
        successMessage = nil
        isWriting = true
        queue.async {
            let outcome = Result { () throws -> LUTAdjustment in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("reference-match.cube")
                try result.transform.cubeData(title: name, strength: strength).write(to: url, options: .atomic)
                let imported = try store.importCube(from: url)
                return LUTAdjustment(id: imported.id, name: imported.name, intensity: 1, isEnabled: true)
            }
            DispatchQueue.main.async {
                guard self.analysisGeneration == token else { return }
                self.isWriting = false
                switch outcome {
                case .success(let adjustment): onStored(adjustment, apply)
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func chooseExportLocation() {
        guard canWrite else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LHLOOK01.cube"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.canCreateDirectories = true
        panel.prompt = "내보내기"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.export(to: url) }
        }
    }

    private func export(to url: URL) {
        guard canWrite, let result else { return }
        let basename = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "cube", (1...8).contains(basename.utf8.count),
              basename.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) }) else {
            errorMessage = "S9용 파일 이름은 영문자와 숫자 1~8자로 정해주세요. 다시 내보내기를 선택하세요."
            return
        }
        let strength = strength
        let name = lutName.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = analysisGeneration
        errorMessage = nil
        successMessage = nil
        isWriting = true
        queue.async {
            let outcome = Result {
                try result.transform.cubeData(title: name, strength: strength).write(to: url, options: .atomic)
            }
            DispatchQueue.main.async {
                guard self.analysisGeneration == token else { return }
                self.isWriting = false
                switch outcome {
                case .success:
                    self.successMessage = "\(url.lastPathComponent) 내보냄 · \(url.path)"
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func invalidate() {
        analysisGeneration += 1
        previewGeneration += 1
    }

    private static func image(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
