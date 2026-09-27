import Combine
import Foundation
import LighthouseCore
import UniformTypeIdentifiers

enum GoogleDriveUploadContent: String, CaseIterable, Identifiable {
    case original, edited, both

    var id: Self { self }
    var title: String {
        switch self {
        case .original: "원본"
        case .edited: "편집본"
        case .both: "원본과 편집본"
        }
    }

    var includesOriginal: Bool { self != .edited }
    var includesEdited: Bool { self != .original }
}

struct GoogleDriveUploadFailure: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let reason: String
}

private enum GoogleDriveUploadModelError: LocalizedError {
    case folderRequired

    var errorDescription: String? { "업로드할 Drive 폴더를 선택하세요." }
}

@MainActor
final class GoogleDriveUploadModel: ObservableObject {
    @Published private(set) var isConfigured: Bool
    @Published private(set) var isConnected: Bool
    @Published private(set) var account: GoogleDriveAccount?
    @Published private(set) var folders: [GoogleDriveFile] = []
    @Published var selectedFolderID: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isCancelling = false
    @Published private(set) var completedPhotos = 0
    @Published private(set) var totalPhotos = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var uploadedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var uploadFailures: [GoogleDriveUploadFailure] = []
    @Published private(set) var report: String?
    @Published private(set) var errorMessage: String?

    private let service: any GoogleDriveServicing
    private let authorization: any GoogleDriveAuthorizing
    private let pipeline: ImagePipeline
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var restored = false
    private var resultFolderID: String?

    init(service: any GoogleDriveServicing = GoogleDriveClient(),
         authorization: any GoogleDriveAuthorizing = GoogleDriveAuthorization(),
         pipeline: ImagePipeline = ImagePipeline()) {
        self.service = service
        self.authorization = authorization
        self.pipeline = pipeline
        isConfigured = authorization.isConfigured
        isConnected = authorization.isConnected
    }

    var progress: Double {
        guard totalPhotos > 0 else { return 0 }
        return Double(completedPhotos) / Double(totalPhotos)
    }

    var selectedFolder: GoogleDriveFile? {
        selectedFolderID.flatMap { id in folders.first { $0.id == id } }
    }

    var resultFolderURL: URL? {
        guard let id = resultFolderID, !id.isEmpty,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) })
        else { return nil }
        return URL(string: "https://drive.google.com/drive/folders/")?.appendingPathComponent(id)
    }

    func prepare() {
        guard !restored else { return }
        restored = true
        do {
            try authorization.restore()
            syncAuthorizationState()
            if isConnected { loadAccountAndFolders() }
        } catch {
            syncAuthorizationState()
            errorMessage = error.localizedDescription
        }
    }

    func configure(json: Data) {
        invalidateCurrentTask()
        do {
            try authorization.configure(json: json)
            account = nil
            folders = []
            selectedFolderID = nil
            report = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        syncAuthorizationState()
    }

    func configure(fileURL: URL) {
        do {
            configure(json: try Data(contentsOf: fileURL))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn() {
        guard begin(status: "Google 계정 연결을 기다리는 중…") else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await authorization.signIn()
                try Task.checkCancellation()
                let accessToken = try await authorization.accessToken(forceRefresh: false)
                async let loadedAccount = service.account(accessToken: accessToken)
                async let loadedFolders = service.folders(accessToken: accessToken)
                let (account, folders) = try await (loadedAccount, loadedFolders)
                try Task.checkCancellation()
                guard token == generation else { return }
                self.account = account
                self.folders = folders
                self.selectedFolderID = selectedFolderID.flatMap { id in folders.contains { $0.id == id } ? id : nil }
                self.errorMessage = nil
            } catch {
                guard token == generation else { return }
                if !Self.isCancellation(error) { self.errorMessage = error.localizedDescription }
            }
            guard token == generation else { return }
            self.syncAuthorizationState()
            self.finish()
        }
    }

    func loadAccountAndFolders() {
        guard begin(status: "Drive 폴더를 불러오는 중…") else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let accessToken = try await authorization.accessToken(forceRefresh: false)
                async let loadedAccount = service.account(accessToken: accessToken)
                async let loadedFolders = service.folders(accessToken: accessToken)
                let (account, folders) = try await (loadedAccount, loadedFolders)
                try Task.checkCancellation()
                guard token == generation else { return }
                self.account = account
                self.folders = folders
                self.selectedFolderID = selectedFolderID.flatMap { id in folders.contains { $0.id == id } ? id : nil }
                self.errorMessage = nil
            } catch {
                guard token == generation else { return }
                if !Self.isCancellation(error) { self.errorMessage = error.localizedDescription }
            }
            guard token == generation else { return }
            self.syncAuthorizationState()
            self.finish()
        }
    }

    func createFolder(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, begin(status: "Drive 폴더를 만드는 중…") else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let accessToken = try await authorization.accessToken(forceRefresh: false)
                let folder = try await service.createFolder(name: trimmed, accessToken: accessToken)
                try Task.checkCancellation()
                guard token == generation else { return }
                self.folders.removeAll { $0.id == folder.id }
                self.folders.append(folder)
                self.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.selectedFolderID = folder.id
                self.errorMessage = nil
            } catch {
                guard token == generation else { return }
                if !Self.isCancellation(error) { self.errorMessage = error.localizedDescription }
            }
            guard token == generation else { return }
            self.syncAuthorizationState()
            self.finish()
        }
    }

    func disconnect() {
        invalidateCurrentTask()
        do {
            try authorization.disconnect()
            account = nil
            folders = []
            selectedFolderID = nil
            report = "이 Mac의 Google 계정 연결을 해제했습니다. Google 계정의 앱 권한은 별도로 취소할 수 있습니다."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        syncAuthorizationState()
    }

    func upload(photos: [PhotoAsset], content: GoogleDriveUploadContent, options: ExportOptions) {
        guard !photos.isEmpty, let folderID = selectedFolderID else {
            errorMessage = GoogleDriveUploadModelError.folderRequired.localizedDescription
            return
        }
        guard begin(status: "Drive 업로드를 준비하는 중…") else { return }
        let snapshot = photos
        let frozenOptions = options
        let token = generation
        totalPhotos = snapshot.count
        completedPhotos = 0
        uploadedCount = 0
        failedCount = 0
        skippedCount = 0
        uploadFailures = []
        report = nil
        resultFolderID = folderID
        let uniqueOriginalCount = content.includesOriginal
            ? Set(snapshot.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path }).count : 0
        let totalFiles = uniqueOriginalCount + (content.includesEdited ? snapshot.count : 0)

        task = Task { [weak self, pipeline] in
            guard let self else { return }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("lighthouse-drive-\(UUID().uuidString)", isDirectory: true)
            var sentOriginals = Set<String>()
            var reservedEditedNames = Set<String>()
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: temporary) }
                for (index, photo) in snapshot.enumerated() {
                    try Task.checkCancellation()
                    if content.includesOriginal {
                        let resolvedPath = photo.url.standardizedFileURL.resolvingSymlinksInPath().path
                        if sentOriginals.insert(resolvedPath).inserted {
                            try await self.send(photo.url, name: photo.url.lastPathComponent,
                                                mimeType: Self.mimeType(for: photo.url), folderID: folderID,
                                                token: token)
                        }
                    }
                    try Task.checkCancellation()
                    if content.includesEdited {
                        do {
                            self.currentFileName = photo.displayName
                            let staged = try await Self.stageEdited(photo: photo, options: frozenOptions,
                                                                    sequence: index + 1, forBoth: content == .both,
                                                                    directory: temporary, pipeline: pipeline,
                                                                    reservedNames: reservedEditedNames)
                            reservedEditedNames.insert(staged.lastPathComponent.lowercased())
                            do {
                                defer { try? FileManager.default.removeItem(at: staged) }
                                try Task.checkCancellation()
                                try await self.send(staged, name: staged.lastPathComponent,
                                                    mimeType: Self.mimeType(for: staged), folderID: folderID,
                                                    token: token)
                            }
                        } catch {
                            if Self.isCancellation(error) || Self.isFatalAuthorization(error) { throw error }
                            guard token == generation else { return }
                            self.failedCount += 1
                            self.uploadFailures.append(GoogleDriveUploadFailure(
                                name: photo.displayName, reason: Self.safeFailureReason(error)
                            ))
                        }
                    }
                    guard token == generation else { return }
                    self.completedPhotos = index + 1
                }
                guard token == generation else { return }
                self.report = "Drive에 파일 \(uploadedCount)개 업로드 · 실패 \(failedCount)개"
            } catch where Self.isCancellation(error) {
                guard token == generation else { return }
                self.skippedCount = max(0, totalFiles - uploadedCount - failedCount)
                self.report = "업로드 중지 · 완료 \(uploadedCount)개 · 실패 \(failedCount)개 · 건너뜀 \(skippedCount)개" +
                    "\n중지할 때 전송 중이던 파일은 Drive에 도착했을 수 있습니다."
            } catch {
                guard token == generation else { return }
                self.skippedCount = max(0, totalFiles - uploadedCount - failedCount)
                self.errorMessage = error.localizedDescription
                if Self.isFatalAuthorization(error) { try? authorization.disconnect() }
                self.report = "업로드하지 못함 · 완료 \(uploadedCount)개 · 건너뜀 \(skippedCount)개"
            }
            guard token == generation else { return }
            self.currentFileName = nil
            self.syncAuthorizationState()
            self.finish()
        }
    }

    func cancel() {
        guard isBusy else { return }
        isCancelling = true
        task?.cancel()
    }

    func cancelAndWait() async {
        guard let activeTask = task else { return }
        isCancelling = true
        activeTask.cancel()
        await activeTask.value
    }

    private func send(_ fileURL: URL, name: String, mimeType: String, folderID: String,
                      token: UInt64) async throws {
        guard token == generation else { return }
        currentFileName = name
        do {
            try Task.checkCancellation()
            let accessToken = try await authorization.accessToken(forceRefresh: false)
            try Task.checkCancellation()
            _ = try await service.upload(fileURL: fileURL, name: name, mimeType: mimeType,
                                         parentID: folderID, accessToken: accessToken)
            guard token == generation else { return }
            uploadedCount += 1
        } catch {
            if Self.isCancellation(error) || Self.isFatalAuthorization(error) { throw error }
            guard token == generation else { return }
            failedCount += 1
            uploadFailures.append(GoogleDriveUploadFailure(name: name, reason: Self.safeFailureReason(error)))
        }
    }

    private func begin(status: String) -> Bool {
        guard !isBusy else { return false }
        generation &+= 1
        isBusy = true
        isCancelling = false
        totalPhotos = 0
        completedPhotos = 0
        currentFileName = status
        errorMessage = nil
        return true
    }

    private func finish() {
        isBusy = false
        isCancelling = false
        currentFileName = nil
        task = nil
    }

    private func invalidateCurrentTask() {
        generation &+= 1
        task?.cancel()
        task = nil
        isBusy = false
        isCancelling = false
        currentFileName = nil
    }

    private func syncAuthorizationState() {
        isConfigured = authorization.isConfigured
        isConnected = authorization.isConnected
        if !isConnected { account = nil; folders = []; selectedFolderID = nil }
    }

    nonisolated private static func stageEdited(photo: PhotoAsset, options: ExportOptions, sequence: Int,
                                                forBoth: Bool, directory: URL,
                                                pipeline: ImagePipeline,
                                                reservedNames: Set<String>) async throws -> URL {
        let preparation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let rendered = try pipeline.prepareExport(url: photo.url, edits: photo.edits, options: options,
                                                       keywords: photo.keywords, caption: photo.caption)
            try Task.checkCancellation()
            var baseName = ExportOptions.baseName(template: options.filenameTemplate, sourceURL: photo.url,
                                                  capturedAt: photo.metadata.capturedAt, sequence: sequence,
                                                  copyName: photo.copyName)
            if forBoth, baseName.caseInsensitiveCompare(photo.url.deletingPathExtension().lastPathComponent) == .orderedSame {
                baseName += "-edited"
            }
            let fileExtension = options.format.fileExtension
            for number in 1...10_000 {
                let suffix = number == 1 ? "" : "-\(number)"
                let candidateBaseName = baseName + suffix
                let candidateName = candidateBaseName + "." + fileExtension
                if !reservedNames.contains(candidateName.lowercased()) {
                    return try pipeline.writeExport(rendered.data, format: options.format,
                                                    baseName: candidateBaseName, to: directory)
                }
            }
            throw ImagePipelineError.exportFailed(directory)
        }
        return try await withTaskCancellationHandler(operation: { try await preparation.value },
                                                     onCancel: { preparation.cancel() })
    }

    nonisolated private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let error = error as? GoogleDriveAuthorizationError, error == .cancelled { return true }
        if let error = error as? GoogleDriveError, case .cancelled = error { return true }
        return false
    }

    nonisolated private static func isFatalAuthorization(_ error: Error) -> Bool {
        if let error = error as? GoogleDriveAuthorizationError {
            return error == .invalidGrant || error == .notConnected || error == .missingRefreshToken
        }
        if let error = error as? GoogleDriveError, case .httpStatus(401) = error { return true }
        return false
    }

    nonisolated private static func safeFailureReason(_ error: Error) -> String {
        if let error = error as? GoogleDriveError { return error.localizedDescription }
        if let error = error as? ImagePipelineError {
            switch error {
            case .invalidDirectory(_), .exportFailed(_):
                return "보정본 임시 파일을 만들 수 없습니다."
            default:
                return error.localizedDescription
            }
        }
        return "파일을 처리하거나 업로드하지 못했습니다."
    }
}
