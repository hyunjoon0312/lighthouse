import AppKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import XCTest

/// 썸네일 캐시에서 항목이 빠질 때(시스템이 비우거나 앱이 지울 때)를 시각과 함께 적는다. 대리자는 아무 스레드에서나 불린다.
private final class ThumbnailEvictionLog: NSObject, NSCacheDelegate {
    private let lock = NSLock()
    private let start = Date()
    private var lines: [String] = []

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        let entry = obj as? ThumbnailEntry
        let line = String(format: "%.2f초 빠짐 (보정 %@, 대체 %@, 스레드 %@)", Date().timeIntervalSince(start),
                          entry?.edits == nil ? "없음" : "있음", entry?.isFallback == true ? "예" : "아니오",
                          Thread.isMainThread ? "메인" : "뒤")
        lock.lock(); lines.append(line); lock.unlock()
    }

    var report: String {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? "없음" : lines.joined(separator: " / ")
    }
}

/// HDR 하이라이트를 켠 RAW의 편집 미리보기와 썸네일. S9 표본이 없으면 건너뛴다.
@MainActor
final class HDRFlowTests: XCTestCase {
    func testPreviewIsHDROnCapableScreenAndThumbnailStaysSDR() async throws {
        guard let sample = TestSupport.rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let (model, root, _) = try await TestSupport.startedModel(self, photos: 0)
        let evictions = ThumbnailEvictionLog()
        model.thumbnailCache.delegate = evictions
        defer { model.thumbnailCache.delegate = nil }
        let raw = root.appendingPathComponent("S9-hdr.RW2")
        try FileManager.default.copyItem(at: sample, to: raw)
        model.importURLs([raw])
        try await TestSupport.wait("import") { !model.isImporting && model.photos.count == 1 }
        model.focusPhoto(model.photos[0])
        model.setMode(.edit)
        try await TestSupport.wait("first render") { !model.rendering && model.rendered != nil }
        var edits = model.photos[0].edits
        edits.exposure = 1.5
        edits.hdrAmount = 1
        model.updateEdits(edits)
        try await TestSupport.wait("hdr render") {
            !model.rendering && (model.rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.bitsPerComponent ?? 0) ==
                (LibraryModel.hdrDisplayAvailable ? 16 : 8)
        }
        XCTAssertNotNil(model.histogram)
        let afterRender = thumbnailState(model)
        let generation = model.thumbnailGeneration
        model.setMode(.grid)
        model.requestThumbnail(for: model.photos[0])
        let afterRequest = thumbnailState(model)
        let start = Date()
        while model.thumbnail(for: model.photos[0]) == nil, Date().timeIntervalSince(start) < 60 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if model.thumbnail(for: model.photos[0]) == nil {
            // 가끔 이 기다림이 시간을 넘긴다. 다음에 실패하면 원인을 좁힐 수 있게 그때의 상태를 남긴다.
            let report = await failureReport(model, evictions: evictions, generationBefore: generation,
                                             afterRender: afterRender, afterRequest: afterRequest)
            print("HDR 썸네일 진단\n\(report)")
            XCTFail("시간 초과: thumbnail\n\(report)")
            return
        }
        let thumbnail = try XCTUnwrap(model.thumbnail(for: model.photos[0])?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(thumbnail.bitsPerComponent, 8, "썸네일은 SDR")
        print("  HDR display available: \(LibraryModel.hdrDisplayAvailable)")
    }

    /// 썸네일 요청이 그냥 돌아가는 조건들(캐시 항목, 요청 중, 읽을 수 없음)과 화면 상태.
    private func thumbnailState(_ model: LibraryModel) -> String {
        let photo = model.photos[0]
        let key = photo.id.uuidString
        let entry = model.thumbnailCache.object(forKey: key as NSString)
        let entryText = entry.map { "있음(보정 일치 \($0.edits == photo.edits), 대체 \($0.isFallback))" } ?? "없음"
        return "캐시 \(entryText), 요청 중 \(model.loadingThumbnails.contains(key)), " +
            "읽을 수 없음 \(model.unavailableThumbnails.contains(photo.id)), 세대 \(model.thumbnailGeneration), " +
            "화면 \(model.mode), 선택 \(model.selectedID == photo.id), 렌더 중 \(model.rendering), " +
            "정밀 렌더 대기 \(model.exactRenderFollowUp != nil), 원본 없음 \(model.isMissing(photo)), " +
            "스마트 미리보기 \(model.smartPreviewURLs[photo.id] != nil)"
    }

    private func failureReport(_ model: LibraryModel, evictions: ThumbnailEvictionLog, generationBefore: Int,
                               afterRender: String, afterRequest: String) async -> String {
        let photo = model.photos[0]
        var lines = [
            "보정 렌더 직후: \(afterRender)",
            "요청 직후: \(afterRequest)",
            "60초 뒤: \(thumbnailState(model))",
            "요청 전 세대 \(generationBefore), 캐시에서 빠진 기록: \(evictions.report)",
            "화면 오류: \(model.imageError ?? "없음")"
        ]
        // 같은 사진·보정으로 썸네일 경로의 두 렌더를 직접 해 본다. 실패하면 요청은 끝나도 아무것도 넣지 않는다.
        let pipeline = model.pipeline, url = photo.url, edits = photo.edits, size = LibraryModel.thumbnailPixels
        let direct = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                func attempt(_ name: String, _ body: () throws -> CGImage) -> String {
                    let start = Date()
                    do {
                        let image = try body()
                        return String(format: "%@ 성공 %d×%d %.2f초", name, image.width, image.height, Date().timeIntervalSince(start))
                    } catch {
                        return String(format: "%@ 실패 %.2f초: %@", name, Date().timeIntervalSince(start), "\(error)")
                    }
                }
                continuation.resume(returning: [
                    attempt("보정 렌더") { try pipeline.renderPreview(url: url, edits: edits, maxPixel: size).image },
                    attempt("내장 썸네일") { try pipeline.thumbnail(for: url, maxPixel: size) }
                ])
            }
        }
        lines.append("직접 렌더: " + direct.joined(separator: ", "))
        // 요청을 한 번 더 했을 때 채워지면 요청이 사라진 것이고, 그래도 비면 렌더나 그 뒤가 문제다.
        model.requestThumbnail(for: photo)
        lines.append("다시 요청 직후: \(thumbnailState(model))")
        let retryStart = Date()
        while model.thumbnail(for: photo) == nil, Date().timeIntervalSince(retryStart) < 30 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let filled = model.thumbnail(for: photo) != nil
        lines.append(String(format: "다시 요청: %@ (%.2f초)", filled ? "채워짐" : "30초 동안 비어 있음",
                            Date().timeIntervalSince(retryStart)))
        lines.append("다시 요청 30초 뒤: \(thumbnailState(model))")
        // 큐 확인은 다시 요청이 실패했을 때만 한다. 먼저 하면 다시 요청 전에 큐를 비워 결과가 달라질 수 있다.
        if !filled { lines.append("다시 요청 30초 뒤 썸네일 큐: \(await queueResponse(model))") }
        lines.append("마지막까지 캐시에서 빠진 기록: \(evictions.report)")
        return lines.joined(separator: "\n")
    }

    /// 썸네일 요청은 이 큐에서 돈다. 앞선 일이 막혀 있으면 요청이 끝나지 않는다.
    private func queueResponse(_ model: LibraryModel) async -> String {
        let start = Date()
        let answered = await withCheckedContinuation { continuation in
            let signal = DispatchSemaphore(value: 0)
            model.thumbnailQueue.async { signal.signal() }
            DispatchQueue.global().async { continuation.resume(returning: signal.wait(timeout: .now() + 10) == .success) }
        }
        return String(format: "%@ (%.2f초)", answered ? "응답함" : "10초 동안 응답 없음", Date().timeIntervalSince(start))
    }
}
