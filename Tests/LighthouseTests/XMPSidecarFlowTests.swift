import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

@MainActor
private final class SidecarCallbackFlag {
    var value = false
}

/// 켜 둔 동안 표시가 바뀌면 사이드카를 고쳐 쓴다.
@MainActor
final class XMPSidecarFlowTests: XCTestCase {
    func testSidecarsFollowMarksOnlyWhenEnabled() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 1)
        // 사이드카는 원본을 읽지 않으므로 RAW 항목은 이름만 있어도 된다.
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let marked = PhotoAsset(url: folder.appendingPathComponent("P1000001.RW2"))
        let plain = PhotoAsset(url: folder.appendingPathComponent("P1000002.RW2"))
        let jpeg = try XCTUnwrap(model.photos.first)
        model.photos += [marked, plain]
        let first = XMPSidecar.url(for: marked), second = XMPSidecar.url(for: plain)
        model.focusPhoto(marked)
        model.setRating(2)
        model.focusPhoto(jpeg)
        model.setRating(4)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "꺼져 있으면 쓰지 않는다")

        model.writesXMPSidecars = true
        try await TestSupport.wait("all sidecars") { FileManager.default.fileExists(atPath: first.path) }
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("xmp:Rating=\"2\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path), "표시가 없는 사진 옆에는 만들지 않는다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecar.url(for: jpeg).path), "JPEG에는 쓰지 않는다")
        model.focusPhoto(marked)
        model.setColorLabel(.green)
        try await TestSupport.wait("updated sidecar") {
            (try? String(contentsOf: first, encoding: .utf8))?.contains("xmp:Label=\"Green\"") == true
        }
        model.undo()
        try await TestSupport.wait("undone sidecar") {
            (try? String(contentsOf: first, encoding: .utf8))?.contains("xmp:Label") == false
        }
        model.focusPhoto(plain)
        model.setRating(1)
        try await TestSupport.wait("new sidecar") { FileManager.default.fileExists(atPath: second.path) }

        model.focusPhoto(marked)
        model.createVirtualCopy()
        XCTAssertEqual(Set(model.sidecarTargets(Set(model.photos.map(\.id))).map(\.id)), [marked.id, plain.id],
                       "사본과 JPEG는 빼고 RAW에만 쓴다")
        model.writesXMPSidecars = false
    }

    func testFlushPersistsImmediateLatestMarkAndQueuedOrder() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        model.writesXMPSidecars = true
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let raw = PhotoAsset(url: folder.appendingPathComponent("queued.RW2"))
        model.photos.append(raw)
        model.focusPhoto(raw)
        model.setRating(1)

        let gate = DispatchSemaphore(value: 0)
        model.sidecarQueue.async { gate.wait() }
        model.writeAllSidecars()
        model.setRating(5)
        gate.signal()
        try model.flushSave()

        let contents = try String(contentsOf: XMPSidecar.url(for: raw), encoding: .utf8)
        XCTAssertTrue(contents.contains("xmp:Rating=\"5\""), "큐의 오래된 쓰기 뒤에 종료 시점의 최신 표시를 쓴다")
        XCTAssertFalse(contents.contains("xmp:Rating=\"1\""))
        XCTAssertTrue(model.pendingSidecarIDs.isEmpty)
        XCTAssertTrue(model.dirtySidecarIDs.isEmpty)
    }

    func testEarlierEqualMarksCannotAcknowledgeLatestQueuedJob() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        model.writesXMPSidecars = true
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let raw = PhotoAsset(url: folder.appendingPathComponent("aba.RW2"))
        model.photos.append(raw)
        let firstGate = DispatchSemaphore(value: 0)
        let laterGate = DispatchSemaphore(value: 0)
        let earlierCompletionProcessed = SidecarCallbackFlag()
        defer { firstGate.signal(); laterGate.signal() }

        model.sidecarQueue.async { firstGate.wait() }
        model.photos[0].rating = 1
        model.writeAllSidecars() // A
        model.sidecarQueue.async {
            DispatchQueue.main.async { earlierCompletionProcessed.value = true }
            laterGate.wait()
        }
        model.photos[0].rating = 2
        model.writeAllSidecars() // B
        model.photos[0].rating = 1
        model.writeAllSidecars() // A, 최신 작업
        model.operationMessage = "최신 작업 대기"

        firstGate.signal()
        try await TestSupport.wait("earlier A completion") { earlierCompletionProcessed.value }
        XCTAssertTrue(model.dirtySidecarIDs.contains(raw.id), "같은 표시여도 이전 A 작업은 최신 A 작업을 완료 처리하지 않는다")
        XCTAssertEqual(model.operationMessage, "최신 작업 대기", "오래된 완료는 결과 안내도 바꾸지 않는다")

        laterGate.signal()
        try await TestSupport.wait("latest A completion") { !model.dirtySidecarIDs.contains(raw.id) }
        let contents = try String(contentsOf: XMPSidecar.url(for: raw), encoding: .utf8)
        XCTAssertTrue(contents.contains("xmp:Rating=\"1\""))
    }

    func testFailedFlushKeepsTargetForSuccessfulRetry() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        model.writesXMPSidecars = true
        let missingFolder = root.appendingPathComponent("unavailable", isDirectory: true)
        let raw = PhotoAsset(url: missingFolder.appendingPathComponent("retry.RW2"))
        model.photos.append(raw)
        model.focusPhoto(raw)
        model.setRating(3)

        XCTAssertThrowsError(try model.flushSave()) { error in
            XCTAssertTrue(error.localizedDescription.contains("XMP 사이드카"), error.localizedDescription)
        }
        XCTAssertTrue(model.pendingSidecarIDs.contains(raw.id), "실패한 종료 쓰기는 다음 종료에서 다시 시도한다")
        XCTAssertTrue(model.dirtySidecarIDs.contains(raw.id))

        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        try model.flushSave()
        XCTAssertTrue(FileManager.default.fileExists(atPath: XMPSidecar.url(for: raw).path))
        XCTAssertTrue(model.pendingSidecarIDs.isEmpty)
        XCTAssertTrue(model.dirtySidecarIDs.isEmpty)
    }

    func testStaleFailureCannotRedirtySuccessfulFlush() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        model.writesXMPSidecars = true
        let missingFolder = root.appendingPathComponent("late-volume", isDirectory: true)
        let raw = PhotoAsset(url: missingFolder.appendingPathComponent("late-failure.RW2"))
        model.photos.append(raw)
        model.photos[0].rating = 2
        model.writeAllSidecars()

        // 첫 실패의 메인 액터 완료 콜백은 대기시키고, 직렬 큐에서 실패한 사실만 확인한다.
        let oldWriteFinished = DispatchSemaphore(value: 0)
        let staleCompletionProcessed = SidecarCallbackFlag()
        model.sidecarQueue.async {
            oldWriteFinished.signal()
            DispatchQueue.main.async { staleCompletionProcessed.value = true }
        }
        XCTAssertEqual(oldWriteFinished.wait(timeout: .now() + 2), .success)
        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        try model.flushSave()
        XCTAssertTrue(model.dirtySidecarIDs.isEmpty)

        model.operationMessage = "종료 저장 성공"
        try await TestSupport.wait("stale failure callback") { staleCompletionProcessed.value }
        XCTAssertTrue(model.dirtySidecarIDs.isEmpty, "성공한 flush 뒤의 과거 실패 콜백은 dirty를 되살리지 않는다")
        XCTAssertTrue(model.pendingSidecarIDs.isEmpty)
        XCTAssertEqual(model.operationMessage, "종료 저장 성공", "과거 실패는 성공 뒤에 오류를 알리지 않는다")
    }

    func testDisablingCancelsPendingWriteAndFlushDoesNotRestartIt() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        model.writesXMPSidecars = true
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let raw = PhotoAsset(url: folder.appendingPathComponent("disabled.RW2"))
        model.photos.append(raw)
        model.focusPhoto(raw)
        model.setRating(4)
        let sidecar = XMPSidecar.url(for: raw)

        model.writesXMPSidecars = false
        try model.flushSave()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(model.pendingSidecarIDs.isEmpty)
        XCTAssertTrue(model.dirtySidecarIDs.isEmpty)
    }

    func testForeignSidecarIsNonfatalAndExcludedTargetsStayUntouched() async throws {
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 1)
        model.writesXMPSidecars = true
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let raw = PhotoAsset(url: folder.appendingPathComponent("foreign.RW2"))
        let virtual = raw.virtualCopy(among: [raw])
        let jpeg = try XCTUnwrap(model.photos.first)
        model.photos += [raw, virtual]
        let foreign = XMPSidecar.url(for: raw)
        let foreignBytes = Data("made by another app".utf8)
        try foreignBytes.write(to: foreign)

        model.focusPhoto(raw)
        model.setRating(2)
        model.focusPhoto(virtual)
        model.setRating(3)
        model.focusPhoto(jpeg)
        model.setRating(4)
        try model.flushSave()

        XCTAssertEqual(try Data(contentsOf: foreign), foreignBytes)
        XCTAssertFalse(model.dirtySidecarIDs.contains(raw.id), "다른 프로그램의 사이드카는 비치명적으로 건너뛴다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecar.url(for: jpeg).path))
        XCTAssertFalse(model.pendingSidecarIDs.contains(virtual.id))
        XCTAssertFalse(model.dirtySidecarIDs.contains(virtual.id))
    }
}
