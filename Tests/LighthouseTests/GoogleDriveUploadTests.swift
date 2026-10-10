import Foundation
import ImageIO
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
final class GoogleDriveUploadTests: XCTestCase {
    func testOriginalUploadsExactBytesWithoutChangingSource() async throws {
        let (photo, source, bytes) = try makePhoto(name: "original.jpg")
        let service = DriveServiceSpy()
        let model = makeModel(service: service)

        model.upload(photos: [photo], content: .original, options: ExportOptions())
        try await wait(model)

        let uploads = await service.uploads
        XCTAssertEqual(uploads.map(\.data), [bytes])
        XCTAssertEqual(uploads.first?.url, source)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(model.uploadedCount, 1)
    }

    func testEditedUploadHonorsSizeAndCleansTemporaryFile() async throws {
        let (photo, _, _) = try makePhoto(name: "edit.jpg", width: 80, height: 50)
        let service = DriveServiceSpy()
        let model = makeModel(service: service)

        model.upload(photos: [photo], content: .edited,
                     options: ExportOptions(maxPixel: 24, quality: 0.7, filenameTemplate: "small"))
        try await wait(model)

        let uploaded = await service.uploads
        let upload = try XCTUnwrap(uploaded.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(upload.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                     properties[kCGImagePropertyPixelHeight] as? Int ?? 0), 24)
        XCTAssertEqual(upload.name, "small.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.url.path))
    }

    func testEditedBatchReclaimsEachStageAndReservesNamesAfterDeletion() async throws {
        let first = try makePhoto(name: "first.jpg", width: 80, height: 50).0
        let second = try makePhoto(name: "second.jpg", width: 80, height: 50).0
        let third = try makePhoto(name: "third.jpg", width: 80, height: 50).0
        let service = DriveServiceSpy(failingNames: ["shared.jpg"])
        let model = makeModel(service: service)

        model.upload(photos: [first, second, third], content: .edited,
                     options: ExportOptions(maxPixel: 24, filenameTemplate: "shared"))
        try await wait(model)

        let uploads = await service.uploads
        let attemptedNames = await service.attemptedNames
        let attemptedURLs = await service.attemptedURLs
        let stageSnapshots = await service.stageSnapshots
        XCTAssertEqual(attemptedNames, ["shared.jpg", "shared-2.jpg", "shared-3.jpg"])
        XCTAssertEqual(uploads.map(\.name), ["shared-2.jpg", "shared-3.jpg"])
        XCTAssertEqual(stageSnapshots.map(\.fileCount), [1, 1, 1])
        XCTAssertTrue(stageSnapshots.allSatisfy { $0.byteCount > 0 })
        XCTAssertTrue(attemptedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(model.failedCount, 1)
        XCTAssertEqual(model.uploadedCount, 2)
    }

    func testFailedEditedSendPromptlyCleansPreparedFile() async throws {
        let photo = try makePhoto(name: "failed.jpg").0
        let service = DriveServiceSpy(failingNames: ["failed-stage.jpg"])
        let model = makeModel(service: service)

        model.upload(photos: [photo], content: .edited,
                     options: ExportOptions(filenameTemplate: "failed-stage"))
        try await wait(model)

        let attemptedURLs = await service.attemptedURLs
        let attemptedURL = try XCTUnwrap(attemptedURLs.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attemptedURL.path))
        XCTAssertEqual(model.failedCount, 1)
    }

    func testBothDeduplicatesVirtualCopyOriginalsAndNamesEditedCollision() async throws {
        let (photo, _, bytes) = try makePhoto(name: "shared.jpg")
        var copy = photo
        copy.id = UUID()
        copy.copyName = "사본 1"
        let service = DriveServiceSpy()
        let model = makeModel(service: service)

        model.upload(photos: [photo, copy], content: .both,
                     options: ExportOptions(maxPixel: 24, filenameTemplate: "{원본}"))
        try await wait(model)

        let uploads = await service.uploads
        XCTAssertEqual(uploads.count, 3)
        XCTAssertEqual(uploads.filter { $0.data == bytes }.count, 1)
        XCTAssertTrue(uploads.contains { $0.name == "shared-edited.jpg" })
        XCTAssertTrue(uploads.contains { $0.name == "shared-사본1.jpg" })
    }

    func testOneFileFailureContinuesRemainingPhotos() async throws {
        let first = try makePhoto(name: "fail.jpg").0
        let second = try makePhoto(name: "ok.jpg").0
        let service = DriveServiceSpy(failingNames: ["fail.jpg"])
        let model = makeModel(service: service)

        model.upload(photos: [first, second], content: .original, options: ExportOptions())
        try await wait(model)

        let attemptedNames = await service.attemptedNames
        XCTAssertEqual(attemptedNames, ["fail.jpg", "ok.jpg"])
        XCTAssertEqual(model.failedCount, 1)
        XCTAssertEqual(model.uploadedCount, 1)
        XCTAssertEqual(model.completedPhotos, 2)
    }

    func testMultipleFailuresRetainEveryReasonWhileLaterSuccessProceeds() async throws {
        let first = try makePhoto(name: "fail-one.jpg").0
        let second = try makePhoto(name: "fail-two.jpg").0
        let third = try makePhoto(name: "success.jpg").0
        let service = DriveServiceSpy(failingNames: ["fail-one.jpg", "fail-two.jpg"])
        let model = makeModel(service: service)

        model.upload(photos: [first, second, third], content: .original, options: ExportOptions())
        try await wait(model)

        XCTAssertEqual(model.uploadFailures.map(\.name), ["fail-one.jpg", "fail-two.jpg"])
        XCTAssertTrue(model.uploadFailures.allSatisfy { !$0.reason.isEmpty })
        XCTAssertEqual(model.failedCount, 2)
        XCTAssertEqual(model.uploadedCount, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testResultFolderLinkUsesFrozenUploadFolderAfterSelectionChanges() async throws {
        let photo = try makePhoto(name: "folder.jpg").0
        let service = DriveServiceSpy()
        let model = makeModel(service: service)

        model.upload(photos: [photo], content: .original, options: ExportOptions())
        try await wait(model)
        model.selectedFolderID = "different-folder"

        XCTAssertEqual(model.resultFolderURL?.absoluteString,
                       "https://drive.google.com/drive/folders/folder-1")
    }

    func testImmediateCancellationStartsNoRemoteSend() async throws {
        let photo = try makePhoto(name: "cancel.jpg", width: 600, height: 400).0
        let service = DriveServiceSpy()
        let model = makeModel(service: service)

        model.upload(photos: [photo], content: .edited,
                     options: ExportOptions(maxPixel: 500, filenameTemplate: "cancelled"))
        model.cancel()
        try await wait(model)

        let attemptedNames = await service.attemptedNames
        XCTAssertTrue(attemptedNames.isEmpty)
        XCTAssertEqual(model.uploadedCount, 0)
        XCTAssertEqual(model.skippedCount, 1)
    }

    func testRefreshBoundaryIsPerFileAndAuthorizationFailureStopsBatch() async throws {
        let first = try makePhoto(name: "first.jpg").0
        let denied = try makePhoto(name: "denied.jpg").0
        let never = try makePhoto(name: "never.jpg").0
        let service = DriveServiceSpy(unauthorizedNames: ["denied.jpg"])
        let authorization = DriveAuthorizationStub()
        let model = GoogleDriveUploadModel(service: service, authorization: authorization)
        model.selectedFolderID = "folder-1"

        model.upload(photos: [first, denied, never], content: .original, options: ExportOptions())
        try await wait(model)

        let attemptedNames = await service.attemptedNames
        XCTAssertEqual(attemptedNames, ["first.jpg", "denied.jpg"])
        XCTAssertEqual(authorization.tokenRequests, 2)
        XCTAssertEqual(model.uploadedCount, 1)
        XCTAssertEqual(model.skippedCount, 2)
        XCTAssertTrue(model.errorMessage?.contains("다시 연결") == true)
    }

    func testCancelAndWaitReturnsAfterTemporaryCleanupAndPreventsLaterSend() async throws {
        let first = try makePhoto(name: "wait-first.jpg", width: 120, height: 80).0
        let second = try makePhoto(name: "wait-second.jpg", width: 120, height: 80).0
        let service = DriveServiceSpy(suspendingNames: ["wait-first-edited.jpg"])
        let model = makeModel(service: service)

        model.upload(photos: [first, second], content: .edited,
                     options: ExportOptions(maxPixel: 60, filenameTemplate: "{원본}-edited"))
        for _ in 0..<200 {
            if await service.attemptedNames.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let attemptedURLs = await service.attemptedURLs
        let stagedURL = try XCTUnwrap(attemptedURLs.first)

        await model.cancelAndWait()

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        var attemptedNames = await service.attemptedNames
        XCTAssertEqual(attemptedNames, ["wait-first-edited.jpg"])
        await Task.yield()
        attemptedNames = await service.attemptedNames
        XCTAssertEqual(attemptedNames, ["wait-first-edited.jpg"])
    }

    /// 업로드 창을 닫아도 위쪽 작업 표시에 몇 장째인지 보이고, 목록의 중지로 멈춘다.
    func testUploadAppearsAsBackgroundActivityAndStops() async throws {
        let first = try makePhoto(name: "activity-first.jpg").0
        let second = try makePhoto(name: "activity-second.jpg").0
        let service = DriveServiceSpy(suspendingNames: ["activity-first.jpg"])
        let drive = makeModel(service: service)
        let library = LibraryModel(dataDirectory: try TestSupport.temporaryDirectory(self), driveUpload: drive)

        drive.upload(photos: [first, second], content: .original, options: ExportOptions())
        for _ in 0..<200 {
            if await service.attemptedNames.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let activity = try XCTUnwrap(library.backgroundActivities.first { $0.kind == .driveUpload })
        XCTAssertEqual(activity.title, "Google Drive 업로드")
        XCTAssertEqual(activity.detail, "0/2장")
        XCTAssertEqual(activity.progress, 0)
        XCTAssertTrue(activity.canCancel)

        library.cancelBackgroundActivity(.driveUpload)
        try await wait(drive)
        XCTAssertNil(library.backgroundActivities.first { $0.kind == .driveUpload })
        let attemptedNames = await service.attemptedNames
        XCTAssertEqual(attemptedNames, ["activity-first.jpg"], "멈춘 뒤에는 다음 사진을 보내지 않는다")
    }

    private func makeModel(service: DriveServiceSpy) -> GoogleDriveUploadModel {
        let model = GoogleDriveUploadModel(service: service, authorization: DriveAuthorizationStub())
        model.selectedFolderID = "folder-1"
        return model
    }

    private func wait(_ model: GoogleDriveUploadModel) async throws {
        try await TestSupport.wait("Drive upload") { !model.isBusy }
    }

    private func makePhoto(name: String, width: Int = 48, height: Int = 32)
        throws -> (PhotoAsset, URL, Data) {
        let directory = try TestSupport.temporaryDirectory(self)
        let url = directory.appendingPathComponent(name)
        try TestSupport.writeJPEG(url, width: width, height: height, color: (80, 120, 160))
        return (PhotoAsset(url: url), url, try Data(contentsOf: url))
    }
}

private actor DriveServiceSpy: GoogleDriveServicing {
    struct Upload: Sendable {
        let url: URL
        let name: String
        let data: Data
    }

    struct StageSnapshot: Sendable {
        let fileCount: Int
        let byteCount: Int
    }

    private(set) var uploads: [Upload] = []
    private(set) var attemptedNames: [String] = []
    private(set) var attemptedURLs: [URL] = []
    private(set) var stageSnapshots: [StageSnapshot] = []
    let failingNames: Set<String>
    let unauthorizedNames: Set<String>
    let suspendingNames: Set<String>

    init(failingNames: Set<String> = [], unauthorizedNames: Set<String> = [],
         suspendingNames: Set<String> = []) {
        self.failingNames = failingNames
        self.unauthorizedNames = unauthorizedNames
        self.suspendingNames = suspendingNames
    }

    func account(accessToken: String) async throws -> GoogleDriveAccount {
        GoogleDriveAccount(displayName: "Test", emailAddress: "test@example.com")
    }

    func folders(accessToken: String) async throws -> [GoogleDriveFile] {
        [GoogleDriveFile(id: "folder-1", name: "Lighthouse")]
    }

    func createFolder(name: String, accessToken: String) async throws -> GoogleDriveFile {
        GoogleDriveFile(id: "folder-1", name: name)
    }

    func upload(fileURL: URL, name: String, mimeType: String, parentID: String,
        accessToken: String) async throws -> GoogleDriveFile {
        attemptedNames.append(name)
        attemptedURLs.append(fileURL)
        let directory = fileURL.deletingLastPathComponent()
        if directory.lastPathComponent.hasPrefix("lighthouse-drive-") {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: [.fileSizeKey])
            let byteCount = try files.reduce(into: 0) { total, file in
                total += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
            stageSnapshots.append(StageSnapshot(fileCount: files.count, byteCount: byteCount))
        }
        if suspendingNames.contains(name) { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if unauthorizedNames.contains(name) { throw GoogleDriveError.httpStatus(401) }
        if failingNames.contains(name) { throw DriveTestError.rejected }
        uploads.append(Upload(url: fileURL, name: name, data: try Data(contentsOf: fileURL)))
        return GoogleDriveFile(id: UUID().uuidString, name: name)
    }
}

@MainActor
private final class DriveAuthorizationStub: GoogleDriveAuthorizing {
    var isConfigured = true
    var isConnected = true
    private(set) var tokenRequests = 0
    func restore() throws {}
    func configure(json: Data) throws {}
    func signIn() async throws {}
    func accessToken(forceRefresh: Bool) async throws -> String {
        tokenRequests += 1
        return "token"
    }
    func disconnect() throws { isConnected = false }
}

private enum DriveTestError: Error { case rejected }
