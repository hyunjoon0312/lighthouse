import AppKit
import Foundation
import ImageIO
@testable import Lighthouse
import LighthouseCore
import UniformTypeIdentifiers
import XCTest

/// 실제 `LibraryModel`을 쓰는 전체 흐름 검사. 만든 JPEG·PNG로 돌고, RAW 표본이 있으면 RAW 부분도 검사한다.
/// RAW 표본은 `LIGHTHOUSE_SAMPLE_RW2` 또는 저장소 위쪽의 `.artifacts/samples/LUMIX-S9.RW2`에서 찾는다.
@MainActor
final class ModelFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestSupport.resetModelDefaults()
    }

    func testModelFlowWithGeneratedPhotos() async throws {
        try await runFlow(rawSample: nil)
    }

    func testModelFlowWithS9RAW() async throws {
        guard let sample = TestSupport.rawSample else {
            throw XCTSkip("RAW 표본이 없습니다. LIGHTHOUSE_SAMPLE_RW2에 S9 RW2 경로를 지정하세요.")
        }
        try await runFlow(rawSample: sample)
    }

    func waitFor(_ label: String, _ ready: @escaping () -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("시간 초과: \(label)")
        throw TestSupport.Timeout(label: label)
    }

    func check(_ condition: Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(condition, label, file: file, line: line)
    }

    func writeImage(_ url: URL, width: Int, height: Int, type: UTType,
                           properties: [CFString: Any] = [:],
                           pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let p = pixel(x, y), i = (y * width + x) * 4
            bytes[i] = p.0; bytes[i + 1] = p.1; bytes[i + 2] = p.2
        } }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
    }

    func meanBrightness(_ image: NSImage) -> Double {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var sum = 0.0, count = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            sum += Double(data[i]) + Double(data[i + 1]) + Double(data[i + 2]); count += 3
        }
        return sum / count
    }

    func runFlow(rawSample: URL?) async throws {
        _ = NSApplication.shared
        let root = try TestSupport.temporaryDirectory(self)
        let rawURL = root.appendingPathComponent("S9-copy.RW2")
        if let rawSample { try FileManager.default.copyItem(at: rawSample, to: rawURL) }
        let dataRoot = root.appendingPathComponent("data-\(UUID().uuidString)")
        let photoRoot = root.appendingPathComponent("photos-\(UUID().uuidString)")
        let exportRoot = root.appendingPathComponent("exports-\(UUID().uuidString)")
        for directory in [dataRoot, photoRoot, exportRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        setenv("LIGHTHOUSE_DATA_DIR", dataRoot.path, 1)

        let a = photoRoot.appendingPathComponent("a-spot.jpg")
        try writeImage(a, width: 320, height: 240, type: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:20 10:11:12"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "DC-S9"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLatitudeRef: "N"]
        ]) { x, y in (150...170).contains(x) && (110...130).contains(y) ? (10, 10, 10) : (UInt8(90 + x / 4), 130, 150) }
        let b = photoRoot.appendingPathComponent("b-plain.png")
        try writeImage(b, width: 300, height: 200, type: .png) { x, _ in (UInt8(40 + x / 3), 90, 120) }
        let c = photoRoot.appendingPathComponent("c-plain.png")
        try writeImage(c, width: 300, height: 200, type: .png) { _, y in (100, UInt8(40 + y / 2), 80) }

        let pipeline = ImagePipeline()
        var photos = try [a, b, c].enumerated().map { index, url in
            PhotoAsset(url: url, metadata: try pipeline.metadata(for: url),
                       importedAt: Date(timeIntervalSince1970: Double(index)))
        }
        photos[1].edits.cropRect = NormalizedCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        photos[1].edits.localAdjustments = [LocalAdjustment(name: "B area", exposure: 0.4,
            strokes: [MaskStroke(points: [MaskPoint(x: 0.3, y: 0.3)], radius: 0.05)])]
        try CatalogStore(url: CatalogStore.defaultURL).save(photos)

        let model = LibraryModel()
        model.start()
        try await waitFor("catalog") { model.catalogLoaded && model.foldersLoaded && !model.isLUTLibraryLoading }
        model.focusPhoto(photos[0])
        model.setMode(.edit)
        try await waitFor("first render") { !model.rendering && model.rendered != nil }

        // 3. 별점·플래그는 다시 렌더하지 않는다.
        let renderedBefore = model.rendered
        model.setRating(4)
        check(!model.rendering && model.rendered === renderedBefore, "rating change does not re-render")
        model.setFlag(.pick)
        check(!model.rendering && model.rendered === renderedBefore, "flag change does not re-render")
        check(model.selection?.rating == 4 && model.selection?.flag == .pick, "rating and flag stored")
        model.updateEdits({ var e = model.selection!.edits; e.contrast = 1.05; return e }())
        check(model.rendering, "edit change still re-renders")
        model.undo()
        try await waitFor("render after undo") { !model.rendering }

        // 5. 슬라이더 드래그는 한 번의 실행 취소다.
        check(model.canUndo, "rating and flag are undoable")
        let start = model.selection!.edits
        for step in 1...30 {
            var e = model.selection!.edits
            e.exposure = Double(step) / 20
            model.updateEdits(e, continuous: true)
        }
        model.endContinuousEdit()
        check(model.selection!.edits.exposure == 1.5, "drag applied final value")
        model.undo()
        check(model.selection!.edits == start && model.selection!.flag == .pick, "one undo reverts whole drag")
        model.redo()
        check(model.selection!.edits.exposure == 1.5, "redo restores whole drag")
        for step in 1...5 {
            var e = model.selection!.edits
            e.saturation = 1 + Double(step) / 10
            model.updateEdits(e, continuous: true)
        }
        var discrete = model.selection!.edits
        discrete.rotationQuarterTurns = 1
        model.updateEdits(discrete)
        model.undo()
        check(model.selection!.edits.rotationQuarterTurns == 0 && model.selection!.edits.saturation == 1.5,
              "discrete edit after unfinished drag is its own undo step")
        model.undo()
        check(model.selection!.edits.saturation == 1 && model.selection!.edits.exposure == 1.5,
              "unfinished drag is committed as one step")
        model.undo()
        check(model.selection!.edits == start, "history back to start")
        try await waitFor("render settle") { !model.rendering }

        // 1. 스팟 복구 위치를 커밋할 때 한 번 찾아 저장한다.
        model.enterRetouchPanel()
        model.retouchMode = .heal
        model.retouchRadius = 0.05
        try await waitFor("retouch canvas") { model.canDrawRetouch }
        let spot = MaskPoint(x: 160.0 / 320, y: 120.0 / 240)
        model.beginRetouch(at: spot)
        model.commitRetouch()
        check(model.isFindingHealSource && !model.canDrawRetouch && model.canvas.retouchDraftPoints.count == 1,
              "heal search runs in background and keeps draft visible")
        try await waitFor("heal source") { !model.isFindingHealSource }
        let strokes = model.selection!.edits.retouchStrokes
        check(strokes.count == 1 && strokes[0].mode == .heal && strokes[0].sourceOffset != nil &&
              model.canvas.retouchDraftPoints.isEmpty && model.retouchError == nil,
              "heal stroke saved with stored source offset")
        let expected = try pipeline.healingSourceOffset(url: a, edits: start,
            stroke: RetouchStroke(mode: .heal, points: strokes[0].points, radius: 0.05))
        check(strokes[0].sourceOffset == expected, "stored offset equals pipeline search")
        model.undo()
        check(model.selection!.edits.retouchStrokes.isEmpty, "heal is one undo step")
        try await waitFor("render after heal undo") { model.canDrawRetouch }
        model.beginRetouch(at: spot)
        model.commitRetouch()
        var bump = model.selection!.edits
        bump.exposure = 0.1
        model.updateEdits(bump)
        check(!model.isFindingHealSource, "edit during search cancels pending heal")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        check(model.selection!.edits.retouchStrokes.isEmpty, "cancelled heal never lands")
        model.undo()
        try await waitFor("retouch canvas again") { model.canDrawRetouch }
        model.beginRetouch(at: MaskPoint(x: 0.1, y: 0.1))
        model.extendRetouch(to: MaskPoint(x: 0.9, y: 0.9), shortSide: 240)
        model.commitRetouch()
        try await waitFor("failed heal") { !model.isFindingHealSource }
        check(model.retouchError != nil && model.selection!.edits.retouchStrokes.isEmpty && model.imageError == nil,
              "heal without source reports error and keeps image renderable")
        model.leaveLocalPanel()

        // 4. 비교 모드의 기준 사진은 다시 렌더하지 않는다.
        model.setMode(.compare)
        try await waitFor("compare render") { !model.rendering && model.pinnedImage != nil }
        let pinnedBefore = model.pinnedImage
        model.move(1)
        try await waitFor("compare render b") { !model.rendering && model.rendered != nil }
        var edited = model.selection!.edits
        edited.exposure = 0.5
        model.updateEdits(edited)
        try await waitFor("compare render after edit") { !model.rendering }
        check(model.pinnedImage === pinnedBefore, "pinned image reused across photo change and edits")
        model.toggleActualSize()
        try await waitFor("compare actual size") { !model.rendering && model.pinnedImage != nil }
        check(model.pinnedImage !== pinnedBefore && model.pinnedImage!.size.width == 320,
              "pinned image re-rendered for 100% view")
        model.toggleActualSize()
        model.undo()
        try await waitFor("compare settle") { !model.rendering }

        // 7. 다음에 붙여넣기는 전체 보정과 LUT만 옮긴다.
        model.setMode(.edit)
        model.focusPhoto(model.photos[0])
        var source = model.selection!.edits
        source.exposure = 0.7
        source.saturation = 1.2
        source.cropRect = NormalizedCrop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        source.retouchStrokes = [RetouchStroke(mode: .clone, points: [MaskPoint(x: 0.5, y: 0.5)],
                                               radius: 0.02, sourceOffset: MaskPoint(x: 0.1, y: 0))]
        model.updateEdits(source)
        model.copyEdits()
        let targetBefore = model.photos[1].edits
        model.pasteToNext()
        let pasted = model.selection!.edits
        check(model.selectedID == model.photos[1].id && pasted.exposure == 0.7 && pasted.saturation == 1.2,
              "paste copies global adjustments")
        check(pasted.cropRect == targetBefore.cropRect && pasted.localAdjustments == targetBefore.localAdjustments &&
              pasted.retouchStrokes.isEmpty, "paste keeps target crop, local areas and retouch")
        model.undo()
        check(model.selection!.edits == targetBefore, "paste is one undo step")
        try await waitFor("render settle 2") { !model.rendering }

        // 9. 보정한 사진의 썸네일은 보정 결과를 보여 준다.
        model.setMode(.grid)
        let gridPhoto = model.photos[2]
        model.requestThumbnail(for: gridPhoto)
        try await waitFor("plain thumbnail") { model.thumbnail(for: gridPhoto) != nil }
        let plain = model.thumbnail(for: gridPhoto)!
        model.focusPhoto(gridPhoto)
        var brighter = gridPhoto.edits
        brighter.exposure = 1.5
        model.updateEdits(brighter)
        let editedPhoto = model.selection!
        model.requestThumbnail(for: editedPhoto)
        try await waitFor("edited thumbnail") { model.thumbnail(for: editedPhoto) !== plain }
        let editedThumb = model.thumbnail(for: editedPhoto)!
        check(meanBrightness(editedThumb) > meanBrightness(plain) + 20, "grid thumbnail shows edits")
        model.setMode(.edit)
        try await waitFor("edit render for thumbnail") { !model.rendering && model.rendered != nil }
        var darker = model.selection!.edits
        darker.exposure = -1
        model.updateEdits(darker)
        model.requestThumbnail(for: model.selection!)
        try await waitFor("preview-fed thumbnail") { !model.rendering && model.thumbnail(for: editedPhoto) !== editedThumb }
        check(meanBrightness(model.thumbnail(for: editedPhoto)!) < meanBrightness(plain) - 10,
              "edit view refreshes thumbnail from preview render")
        model.updateEdits(.neutral)
        model.requestThumbnail(for: model.selection!)
        try await waitFor("neutral thumbnail") {
            abs(self.meanBrightness(model.thumbnail(for: editedPhoto)!) - self.meanBrightness(plain)) < 2
        }
        check(true, "reset photo returns to original thumbnail")

        // 6. 내보낸 JPEG에 촬영 정보가 남고 위치는 선택 사항이다.
        model.focusPhoto(model.photos[0])
        for includeLocation in [false, true] {
            model.export(scope: .current, options: ExportOptions(quality: 0.9, includeLocation: includeLocation),
                         directory: exportRoot)
            try await waitFor("export") { !model.isExporting && model.exportReport != nil }
            check(model.exportReport!.hasPrefix("1장 내보냄"), "export succeeded (location \(includeLocation))")
        }
        let files = try FileManager.default.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        check(files.map(\.lastPathComponent) == ["a-spot-edited-2.jpg", "a-spot-edited.jpg"], "two export files")
        for (file, hasGPS) in [(files[1], false), (files[0], true)] {
            let source = CGImageSourceCreateWithURL(file as CFURL, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            check(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:09:20 10:11:12" &&
                  (properties[kCGImagePropertyGPSDictionary] != nil) == hasGPS,
                  "\(file.lastPathComponent) keeps capture date, GPS \(hasGPS)")
        }

        // 8. 그리드 위아래 이동은 한 줄 단위다.
        model.gridColumnCount = 2
        model.focusPhoto(model.photos[0])
        model.move(model.gridColumnCount)
        check(model.selectedID == model.photos[2].id, "down arrow moves by one grid row")

        // 10. 자동 마스크는 카탈로그 밖 파일로 저장되고 재시작 후 복원된다.
        let maskURL = root.appendingPathComponent("mask-\(UUID().uuidString).png")
        try writeImage(maskURL, width: 64, height: 48, type: .png) { x, _ in x < 32 ? (255, 255, 255) : (0, 0, 0) }
        let maskImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(maskURL as CFURL, nil)!, 0, nil)!
        let gray = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.linearGray)!,
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.draw(maskImage, in: CGRect(x: 0, y: 0, width: 64, height: 48))
        let maskData = NSMutableData()
        let maskDestination = CGImageDestinationCreateWithData(maskData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(maskDestination, gray.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(maskDestination))
        model.setMode(.edit)
        var masked = model.selection!.edits
        masked.localAdjustments = [LocalAdjustment(name: "자동 피사체", exposure: 0.6,
                                                   baseMask: RasterMask(width: 64, height: 48, pngData: maskData as Data))]
        model.updateEdits(masked)
        try await waitFor("masked render") { !model.rendering }
        check(model.imageError == nil, "photo with stored mask renders")
        try model.flushSave()
        let catalogText = try String(contentsOf: CatalogStore.defaultURL, encoding: .utf8)
        let maskFiles = try FileManager.default.contentsOfDirectory(
            at: CatalogStore(url: CatalogStore.defaultURL).maskDirectory, includingPropertiesForKeys: nil)
        check(!catalogText.contains("pngData") && catalogText.contains("sha256") && maskFiles.count == 1,
              "catalog references mask file instead of embedding PNG")
        let reopened = LibraryModel()
        reopened.start()
        try await waitFor("reopened catalog") { reopened.catalogLoaded || reopened.loadError != nil }
        check(reopened.loadError == nil && reopened.photos == model.photos, "mask restored after restart")

        // 3. 별점·플래그도 실행 취소한다.
        model.setMode(.grid)
        model.focusPhoto(model.photos[1])
        let marksBefore = (model.selection!.rating, model.selection!.flag)
        model.setFlag(.reject)
        model.setRating(2)
        model.undo()
        check(model.selection!.rating == marksBefore.0 && model.selection!.flag == .reject, "undo reverts rating first")
        model.undo()
        check(model.selection!.flag == marksBefore.1, "undo reverts flag")
        model.redo()
        check(model.selection!.flag == .reject, "redo restores flag")
        model.setFlag(marksBefore.1)

        // 6. 타일 클릭은 바로 선택하고, 그룹 안 클릭만 더블클릭 판정을 기다린다.
        model.handleTileClick(model.photos[0], clickCount: 1, modifiers: [])
        check(model.selectedPhotoIDs == [model.photos[0].id], "single click selects immediately")
        model.handleTileClick(model.photos[2], clickCount: 1, modifiers: .command)
        check(model.selectedPhotoIDs.count == 2, "command click adds to selection")
        model.handleTileClick(model.photos[0], clickCount: 1, modifiers: [])
        check(model.selectedPhotoIDs.count == 2, "click inside group waits for double click")
        model.handleTileClick(model.photos[0], clickCount: 2, modifiers: [])
        check(model.selectedPhotoIDs.count == 2 && model.mode == .edit && model.selectedID == model.photos[0].id,
              "double click keeps group and opens photo")
        try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.2) * 1_000_000_000))
        check(model.selectedPhotoIDs.count == 2, "double click cancels pending collapse")
        model.setMode(.grid)
        model.handleTileClick(model.photos[2], clickCount: 1, modifiers: [])
        try await waitFor("collapse") { model.selectedPhotoIDs.count == 1 }
        check(model.selectedPhotoIDs == [model.photos[2].id], "single click in group collapses after interval")

        // 7. 목록 캐시가 변경을 따라간다.
        model.filter = .rejects
        check(model.visiblePhotos.isEmpty && model.counts.rejects == 0, "filter cache follows flags")
        model.focusPhoto(model.photos[2])
        model.filter = .all
        model.focusPhoto(model.photos[2])
        model.setFlag(.reject)
        model.filter = .rejects
        check(model.visiblePhotos.map(\.id) == [model.photos[2].id] && model.counts.rejects == 1,
              "visible photos and counts update after flag")
        model.filter = .all
        model.focusPhoto(model.photos[2])
        model.setFlag(.none)
        model.minimumRating = 3
        check(model.visiblePhotos.map(\.id) == [model.photos[0].id], "rating filter uses fresh cache")
        model.minimumRating = 0
        check(model.folders.count == 1 && model.photo(withID: model.photos[1].id) == model.photos[1],
              "folders and id lookup")

        // 2. 최근 렌더와 다음 사진 미리 현상으로 사진을 바로 넘긴다.
        model.focusPhoto(model.photos[0])
        model.setMode(.edit)
        try await waitFor("render p0") { !model.rendering && model.rendered != nil }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        model.move(1)
        check(!model.rendering && model.rendered != nil, "prefetched next photo appears without rendering")
        model.move(-1)
        check(!model.rendering && model.rendered != nil, "recent photo appears without rendering")
        let expected0 = try pipeline.render(url: model.selection!.url, edits: model.selection!.edits, maxPixel: 2200)
        check(model.rendered!.size.width == CGFloat(expected0.width), "recent render has preview size")

        // 1. 슬라이더 드래그 중에도 그리고, 마지막 결과는 마지막 값과 같다.
        var dragEdits = model.selection!.edits
        for step in 1...12 {
            dragEdits.contrast = 1 + Double(step) / 40
            model.updateEdits(dragEdits, continuous: true)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        model.endContinuousEdit()
        try await waitFor("drag settle") { !model.rendering }
        let finalExpected = try pipeline.render(url: model.selection!.url, edits: dragEdits, maxPixel: 2200)
        check(meanBrightness(model.rendered!) == meanBrightness(NSImage(cgImage: finalExpected,
              size: NSSize(width: finalExpected.width, height: finalExpected.height))), "final drag render matches final edits")
        model.undo()
        try await waitFor("drag undo settle") { !model.rendering }
        model.move(1); model.move(1); model.move(-1)
        try await waitFor("switch settle") { !model.rendering }
        let switched = try pipeline.render(url: model.selection!.url, edits: model.selection!.edits, maxPixel: 2200)
        check(model.selectedID == model.photos[1].id &&
              meanBrightness(model.rendered!) == meanBrightness(NSImage(cgImage: switched,
              size: NSSize(width: switched.width, height: switched.height))), "rapid photo switch shows selected photo")

        // 4. 내보내기 중지.
        model.setMode(.grid)
        model.clearPhotoSelection()
        model.focusPhoto(model.photos[0])
        model.export(scope: .visible, options: ExportOptions(quality: 0.9), directory: exportRoot)
        model.cancelExport()
        check(model.isCancellingExport, "cancel shows stopping state")
        try await waitFor("cancelled export") { !model.isExporting && model.exportReport != nil }
        check(model.exportReport!.contains("중지해서") && !model.isCancellingExport, "export stops and reports skipped photos")

        if rawSample != nil {
            // 2·5. RAW 카메라 미리보기를 먼저 보여 주고, 보정 썸네일은 디스크에서 다시 읽는다.
            model.importURLs([rawURL])
            try await waitFor("raw import") { !model.isImporting && model.photos.contains { $0.path.hasSuffix("S9-copy.RW2") } }
            let raw = model.photos.first { $0.path.hasSuffix("S9-copy.RW2") }!
            model.focusPhoto(raw)
            model.setMode(.edit)
            try await waitFor("raw placeholder") { model.rendered != nil }
            let placeholderSize = model.rendered!.size
            let sawPlaceholder = model.rendering
            let histogramDuringPlaceholder = model.histogram
            try await waitFor("raw render") { !model.rendering }
            print("  placeholder \(placeholderSize) rendering-at-first-image \(sawPlaceholder) final \(model.rendered?.size ?? .zero) error \(model.imageError ?? "-")"); fflush(stdout)
            check(sawPlaceholder && placeholderSize.width == 1920 && model.rendered!.size.width == 2200,
                  "embedded preview shown first, then RAW render")
            check(histogramDuringPlaceholder == nil, "no histogram for camera preview")
            try await waitFor("raw histogram") { model.histogram != nil }
            let rawRender = model.rendered!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            var timer0 = Date()
            let expectedHistogram = ImageHistogram.make(from: rawRender)
            let histogramTime = Date().timeIntervalSince(timer0)
            check(model.histogram == expectedHistogram, "histogram matches displayed render")
            model.showsClipping = true
            timer0 = Date()
            try await waitFor("clipping overlay") { model.clippingOverlay != nil }
            print(String(format: "  histogram %.3fs, clipping overlay ready after %.3fs", histogramTime, Date().timeIntervalSince(timer0)))
            check(model.clippingOverlay!.size == model.rendered!.size, "clipping overlay matches render size")
            model.showsClipping = false
            check(model.clippingOverlay == nil, "clipping overlay cleared when turned off")
            model.setMode(.grid)
            var rawEdits = raw.edits
            rawEdits.exposure = 0.7
            model.updateEdits(rawEdits)
            let editedRaw = model.selection!
            model.requestThumbnail(for: editedRaw)
            let thumbStart = Date()
            let thumbKey = ThumbnailStore.key(for: editedRaw)!
            let thumbFolder = ThumbnailStore().directory.appendingPathComponent(editedRaw.id.uuidString)
            let thumbFile = thumbFolder.appendingPathComponent(thumbKey + ".jpg")
            try await waitFor("raw edited thumbnail") {
                FileManager.default.fileExists(atPath: thumbFile.path) &&
                    model.thumbnailCache.object(forKey: editedRaw.id.uuidString as NSString)?.edits == editedRaw.edits
            }
            let renderedThumbTime = Date().timeIntervalSince(thumbStart)
            let storedAt = try FileManager.default.attributesOfItem(atPath: thumbFile.path)[.modificationDate] as? Date
            try model.flushSave()
            let restarted = LibraryModel()
            restarted.start()
            try await waitFor("restart catalog") { restarted.catalogLoaded }
            let again = restarted.photo(withID: editedRaw.id)!
            let diskStart = Date()
            restarted.requestThumbnail(for: again)
            try await waitFor("disk thumbnail") { restarted.thumbnail(for: again) != nil }
            let diskTime = Date().timeIntervalSince(diskStart)
            print(String(format: "  edited RAW thumbnail: render %.3fs, from disk after restart %.3fs", renderedThumbTime, diskTime))
            // 걸린 시간 대신, 보관한 파일을 다시 쓰지 않고 그대로 읽었는지로 확인한다.
            check(try FileManager.default.attributesOfItem(atPath: thumbFile.path)[.modificationDate] as? Date == storedAt &&
                  (try? FileManager.default.contentsOfDirectory(atPath: thumbFolder.path)) == [thumbKey + ".jpg"],
                  "restart reads edited thumbnail from disk")
        }

        // 7. 사진이 많을 때 반복 읽기 비용.
        let many = (0..<5000).map { index -> PhotoAsset in
            var photo = PhotoAsset(url: photoRoot.appendingPathComponent("many-\(index).jpg"))
            photo.rating = index % 6
            photo.flag = index % 3 == 0 ? .pick : .none
            return photo
        }
        let big = LibraryModel()
        big.photos = many
        big.search = "many-1"
        let timer = Date()
        for _ in 0..<50 { _ = big.visiblePhotos.count; _ = big.counts.picks; _ = big.folders.count; _ = big.photo(withID: many[4999].id) }
        print(String(format: "  5000 photos x50 reads: %.4fs", Date().timeIntervalSince(timer)))
        // 걸린 시간 대신, 한 번 계산한 값을 보관하고 사진 목록이 바뀌면 버리는지 확인한다.
        check(big.visibleCache?.count == big.visiblePhotos.count && big.countsCache != nil &&
              big.foldersCache != nil && big.indexCache?.count == many.count, "library reads are cached")
        big.photos[0].rating = 0
        check(big.visibleCache == nil && big.countsCache == nil && big.foldersCache == nil && big.indexCache == nil,
              "changing photos clears the cached reads")
        check(big.counts.picks == many.filter { $0.flag == .pick }.count &&
              big.visiblePhotos.count == many.filter { $0.filename.localizedCaseInsensitiveContains("many-1") }.count,
              "recomputed reads match the photos")

        if rawSample != nil {
            // 8. 카드에서 복사해 가져오기.
            let card = root.appendingPathComponent("card-\(UUID().uuidString)/DCIM/100_PANA", isDirectory: true)
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: rawURL, to: card.appendingPathComponent("P1000123.RW2"))
            try writeImage(card.appendingPathComponent("P1000124.JPG"), width: 64, height: 48, type: .jpeg, properties: [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:20 18:05:00"]
            ]) { x, _ in (UInt8(x * 3), 100, 80) }
            let cardHashes = try FileManager.default.contentsOfDirectory(at: card, includingPropertiesForKeys: nil)
                .sorted { $0.path < $1.path }.map { try Data(contentsOf: $0) }
            let library = root.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
            let before = model.photos.count
            model.importByCopying(from: card.deletingLastPathComponent().deletingLastPathComponent(), to: library,
                                  organizeByDate: true)
            check(model.canCancelImport, "card copy can be cancelled while running")
            try await waitFor("card import") { !model.isImporting && model.photos.count == before + 2 }
            let copiedJPEG = library.appendingPathComponent("2026/2026-09-20/P1000124.JPG")
            let rawCapture = try pipeline.metadata(for: rawURL).capturedAt!
            let rawFolder = PhotoCopier.folder(for: rawCapture, in: library, organizeByDate: true)
            check(FileManager.default.fileExists(atPath: copiedJPEG.path) &&
                  FileManager.default.fileExists(atPath: rawFolder.appendingPathComponent("P1000123.RW2").path),
                  "card photos copied into capture-date folders")
            let importedPaths = Set(model.photos.suffix(from: 0).map(\.path))
            check(importedPaths.contains(copiedJPEG.resolvingSymlinksInPath().path) &&
                  !model.photos.contains { $0.path.hasPrefix(card.resolvingSymlinksInPath().path) },
                  "catalog references copies, not the card")
            let cardAfter = try FileManager.default.contentsOfDirectory(at: card, includingPropertiesForKeys: nil)
                .sorted { $0.path < $1.path }.map { try Data(contentsOf: $0) }
            check(cardAfter == cardHashes, "card originals unchanged")
            check(model.operationMessage?.hasPrefix("복사 2장 · 이미 있음 0장") == true, "copy summary reported")
            model.importByCopying(from: card, to: library, organizeByDate: true)
            try await waitFor("card reimport") { !model.isImporting && model.operationMessage?.contains("이미 있음 2장") == true }
            check(model.photos.count == before + 2, "re-import of same card adds nothing")
            model.importByCopying(from: card, to: root.appendingPathComponent("library-cancel-\(UUID().uuidString)"),
                                  organizeByDate: false)
            model.cancelImport()
            try await waitFor("cancelled card import") { !model.isImporting && model.operationMessage?.contains("중지해서") == true }
            check(true, "cancelled card copy reports skipped photos")
        }

        // 6. 표시 후 다음 사진과 클릭 위치 확대.
        model.setMode(.grid)
        model.filter = .all
        model.autoAdvance = true
        let order = model.visiblePhotos.map(\.id)
        model.focusPhoto(model.photo(withID: order[0])!)
        model.markFromKeyboard(flag: .reject)
        check(model.selectedID == order[1] && model.photo(withID: order[0])!.flag == .reject,
              "flag then advance to next photo")
        model.markFromKeyboard(flag: .reject)
        model.filter = .rejects
        model.focusPhoto(model.photo(withID: order[0])!)
        model.markFromKeyboard(flag: PhotoFlag.none)
        check(model.selectedID == order[1] && model.visiblePhotos.map(\.id) == [order[1]],
              "advance targets the next photo even when the marked one leaves the filter")
        model.autoAdvance = false
        model.markFromKeyboard(flag: PhotoFlag.none)
        check(model.selectedID == nil || model.selectedID == order[1], "no advance when turned off")
        model.filter = .all
        model.focusPhoto(model.photo(withID: order[0])!)
        model.setMode(.edit)
        model.toggleActualSize(at: CGPoint(x: 0.2, y: 0.7))
        check(model.actualSize && model.zoomAnchor == CGPoint(x: 0.2, y: 0.7), "click position becomes zoom anchor")
        model.toggleActualSize()
        check(!model.actualSize, "second click returns to fit")
        model.toggleActualSize()
        check(model.zoomAnchor == CGPoint(x: 0.5, y: 0.5), "keyboard zoom centers")
        model.toggleActualSize()
        try await waitFor("zoom settle") { !model.rendering }

        // 7. 프리셋.
        model.setMode(.grid)
        model.focusPhoto(model.photos[0])
        var look = model.selection!.edits
        look.vibrance = 0.4
        look.clarity = 0.3
        look.cropRect = NormalizedCrop(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
        model.updateEdits(look)
        check(model.savePreset(name: "선명한 거리", components: [.global]) == nil &&
              FileManager.default.fileExists(atPath: EditPresetStore.defaultURL.path), "preset saved to presets.json")
        check(model.savePreset(name: "선명한 거리", components: [.global]) != nil, "duplicate preset name rejected")
        let preset = model.presets.first { $0.name == "선명한 거리" }!
        model.handleTileClick(model.photos[1], clickCount: 1, modifiers: [])
        model.handleTileClick(model.photos[2], clickCount: 1, modifiers: .command)
        let beforePreset = [model.photos[1].edits, model.photos[2].edits]
        model.applyPreset(preset)
        check(model.photos[1].edits.vibrance == 0.4 && model.photos[2].edits.clarity == 0.3 &&
              model.photos[1].edits.cropRect == beforePreset[0].cropRect, "preset applies global only to selection")
        model.undo()
        check([model.photos[1].edits, model.photos[2].edits] == beforePreset, "preset application is one undo step")
        check(model.renamePreset(preset.id, to: "거리 룩") == nil && model.presets.contains { $0.name == "거리 룩" },
              "preset renamed")
        model.importPresetID = preset.id
        let presetImport = photoRoot.appendingPathComponent("preset-import.png")
        try writeImage(presetImport, width: 40, height: 30, type: .png) { _, _ in (90, 100, 110) }
        model.importURLs([presetImport])
        try await waitFor("preset import") { !model.isImporting && model.photos.contains { $0.path.hasSuffix("preset-import.png") } }
        let presetPhoto = model.photos.first { $0.path.hasSuffix("preset-import.png") }!
        check(presetPhoto.edits.vibrance == 0.4 && presetPhoto.edits.cropRect == nil &&
              model.operationMessage?.contains("거리 룩") == true, "import applies chosen preset")
        model.deletePreset(preset.id)
        check(model.presets.isEmpty && model.importPresetID == nil, "deleting preset clears import preset")
        try Data("broken".utf8).write(to: EditPresetStore.defaultURL)
        let presetReload = LibraryModel()
        presetReload.start()
        try await waitFor("preset reload") { presetReload.catalogLoaded }
        let presetFileAfter = try Data(contentsOf: EditPresetStore.defaultURL)
        check(presetReload.presetLoadError != nil && presetReload.savePreset(name: "X", components: .global) != nil &&
              presetFileAfter == Data("broken".utf8),
              "damaged presets.json is reported and not overwritten")
        try FileManager.default.removeItem(at: EditPresetStore.defaultURL)

        // 9. 파일 이름 규칙과 워터마크.
        let namedRoot = root.appendingPathComponent("named-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: namedRoot, withIntermediateDirectories: true)
        let spotPhoto = model.photos.first { $0.path.hasSuffix("a-spot.jpg") }!
        model.focusPhoto(spotPhoto)
        model.clearPhotoSelection()
        model.focusPhoto(spotPhoto)
        let marked = ExportOptions(maxPixel: 200, quality: 0.9, filenameTemplate: "{날짜}_{번호}_{원본}",
                                   watermark: Watermark(text: "LIGHTHOUSE", position: .bottomRight, size: 0.1, opacity: 1))
        model.export(scope: .current, options: marked, directory: namedRoot)
        try await waitFor("named export") { !model.isExporting && model.exportReport != nil }
        let namedFiles = try FileManager.default.contentsOfDirectory(atPath: namedRoot.path)
        check(namedFiles == ["2026-09-20_001_a-spot.jpg"], "filename template applied")
        let plainExport = try pipeline.prepareJPEG(url: spotPhoto.url, edits: model.photo(withID: spotPhoto.id)!.edits,
                                                   maxPixel: 200, quality: 0.9)
        let namedData = try Data(contentsOf: namedRoot.appendingPathComponent(namedFiles[0]))
        check(namedData != plainExport.data, "watermark changes exported pixels")

        // 4. 그라데이션 부분 보정.
        model.setMode(.edit)
        try await waitFor("gradient base render") { !model.rendering && model.rendered != nil }
        let beforeGradient = model.selection!.edits
        model.addGradientLocal(radial: false)
        let linearArea = model.selectedLocal!
        check(linearArea.gradient != nil && !model.isLocalEditing && model.adjustmentPanel == .local &&
              linearArea.exposure < 0, "linear gradient added in handle mode")
        try await waitFor("gradient render") { !model.rendering }
        check(model.canEditGradient && !model.canDrawLocal, "gradient handles available instead of brush")
        let gradientPhoto = model.selection!
        let gradientGeometry = LocalMaskGeometry(sourceWidth: Double(gradientPhoto.metadata.width),
                                                 sourceHeight: Double(gradientPhoto.metadata.height),
                                                 edits: gradientPhoto.edits)
        model.moveGradientHandle(.end, toDisplay: MaskPoint(x: 0.5, y: 0.8))
        model.moveGradientHandle(.end, toDisplay: MaskPoint(x: 0.5, y: 0.9))
        model.endContinuousEdit()
        let expectedEnd = gradientGeometry.sourcePoint(fromDisplay: MaskPoint(x: 0.5, y: 0.9))
        if case .linear(_, let end)? = model.selectedLocal?.gradient {
            check(abs(end.x - expectedEnd.x) < 1e-9 && abs(end.y - expectedEnd.y) < 1e-9, "handle drag stores source point")
        } else { check(false, "gradient kept linear") }
        model.undo()
        check(model.selectedLocal?.gradient == linearArea.gradient, "handle drag is one undo step")
        model.undo()
        check(model.selection!.edits == beforeGradient, "gradient add undone")
        model.addGradientLocal(radial: true)
        let radialID = model.selectedLocalID!
        model.updateLocal(continuous: true) { $0.temperature = 0.5; $0.saturation = -0.3; $0.clarity = 0.4 }
        model.endContinuousEdit()
        try await waitFor("radial render") { !model.rendering }
        check(model.imageError == nil && model.selectedLocal?.hasEffect == true, "radial area with color renders")
        model.chooseLocal(radialID, drawing: true)
        check(model.isLocalEditing && !model.canEditGradient, "brush refine mode hides handles")
        model.chooseLocal(radialID)
        check(!model.isLocalEditing, "choosing gradient area opens handle mode")
        try model.flushSave()
        let gradientReload = LibraryModel()
        gradientReload.start()
        try await waitFor("gradient reload") { gradientReload.catalogLoaded }
        check(gradientReload.photo(withID: gradientPhoto.id)?.edits.localAdjustments.last?.gradient ==
              model.selection?.edits.localAdjustments.last?.gradient, "gradient restored after restart")

        // 5. 연속 촬영 묶음과 베스트 컷 추천.
        // 얼굴 표본이 있으면 얼굴 품질까지, 없으면 선명도가 다른 만든 컷으로 선명도만 본다.
        let faces = TestSupport.faceBurstSamples
        let burstRoot = root.appendingPathComponent("burst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: burstRoot, withIntermediateDirectories: true)
        var burstURLs: [URL] = []
        for (index, name) in ["burst-1-sharp.jpg", "burst-2-blur.jpg", "burst-3-motion.jpg", "burst-4-eyes.jpg"].enumerated() {
            let copy = burstRoot.appendingPathComponent(name)
            if let faces {
                try FileManager.default.copyItem(at: faces.appendingPathComponent(name), to: copy)
            } else {
                try writeImage(copy, width: 400, height: 300, type: .jpeg, properties: [
                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:21 09:00:00",
                                                     kCGImagePropertyExifSubsecTimeOriginal: "\(100 + index * 200)"],
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Panasonic", kCGImagePropertyTIFFModel: "DC-S9"]
                ]) { x, y in
                    let cell = [2, 0, 8, 16][index]
                    guard cell > 0 else { return (UInt8(x * 255 / 399), 120, 120) }
                    let on = (x / cell + y / cell) % 2 == 0
                    return index == 3 ? (on ? 140 : 110, 120, 120) : (on ? 230 : 30, 120, 120)
                }
            }
            burstURLs.append(copy)
        }
        let burstHashes = try burstURLs.map { try Data(contentsOf: $0) }
        model.setMode(.grid)
        model.importURLs(burstURLs)
        try await waitFor("burst import") { !model.isImporting && model.photos.filter { $0.path.contains(burstRoot.lastPathComponent) }.count == 4 }
        let burstIDs = burstURLs.map { url in model.photos.first { $0.path.hasSuffix(url.lastPathComponent) && $0.path.contains(burstRoot.lastPathComponent) }!.id }
        let burstGroup = model.burstIndex.groups.first { Set($0.photoIDs) == Set(burstIDs) }
        check(burstGroup?.shots.map { $0[0] } == burstIDs, "four shots within a second form one burst in capture order")
        model.filter = .bursts
        check(Set(burstIDs).isSubset(of: Set(model.visiblePhotos.map(\.id))), "burst filter shows burst photos")
        check(model.burstBadge(for: model.photo(withID: burstIDs[2])!) == BurstBadge(shot: 3, count: 4, isBest: nil),
              "badge shows position before analysis")
        model.search = "burst-"
        model.analyzeBursts()
        check(model.isAnalyzingBursts, "analysis runs in background")
        try await waitFor("burst analysis") { !model.isAnalyzingBursts }
        let recommendation = model.burstRecommendations[burstGroup!.id]
        check(recommendation?.bestShot == 0 && recommendation?.usedFaces == (faces != nil),
              "sharpest shot recommended (faces used: \(faces != nil)): \(String(describing: recommendation?.scores))")
        check(model.burstBadge(for: model.photo(withID: burstIDs[0])!)?.isBest == true &&
              model.burstBadge(for: model.photo(withID: burstIDs[3])!)?.isBest == false, "badge marks recommendation")
        check(burstIDs.map { model.burstBadge(for: model.photo(withID: $0)!)?.eyesClosed ?? false } ==
              (faces != nil ? [false, false, false, true] : [false, false, false, false]),
              "the shot with covered eyes is marked (faces used: \(faces != nil))")
        print("  " + (model.burstMessage ?? ""))
        model.focusPhoto(model.photo(withID: burstIDs[2])!)
        model.setFlag(.pick)
        model.markBurstRecommendations()
        let flags = burstIDs.map { model.photo(withID: $0)!.flag }
        check(flags == [.pick, .reject, .pick, .reject], "best picked, others rejected, existing flag kept")
        model.undo()
        check(burstIDs.map { model.photo(withID: $0)!.flag } == [.none, .none, .pick, .none], "marking is one undo step")
        model.selectBurstRecommendations()
        check(model.selectedPhotoIDs == [burstIDs[0]], "select recommendations")
        check(try burstURLs.map { try Data(contentsOf: $0) } == burstHashes, "burst originals untouched")
        model.search = ""
        model.filter = .all

        // 10. 가상 사본.
        model.setMode(.grid)
        model.filter = .all
        let masterPhoto = model.photos.first { $0.path.hasSuffix("burst-1-sharp.jpg") }!
        model.focusPhoto(masterPhoto)
        var masterEdits = masterPhoto.edits
        masterEdits.exposure = 0.8
        model.updateEdits(masterEdits)
        let countBeforeCopy = model.photos.count
        model.createVirtualCopy()
        let copyPhoto = model.selection!
        let masterIndex = model.photos.firstIndex { $0.id == masterPhoto.id }!
        check(model.photos.count == countBeforeCopy + 1 && copyPhoto.id != masterPhoto.id &&
              copyPhoto.path == masterPhoto.path && copyPhoto.copyName == "사본 1" &&
              model.photos[masterIndex + 1].id == copyPhoto.id && copyPhoto.edits.exposure == 0.8,
              "copy created after original with same file and edits")
        var copyEdits = copyPhoto.edits
        copyEdits.exposure = -1.5
        copyEdits.saturation = 0
        model.updateEdits(copyEdits)
        check(model.photo(withID: masterPhoto.id)!.edits.exposure == 0.8, "editing copy leaves original edits")
        model.undo()
        check(model.photo(withID: copyPhoto.id)!.edits.exposure == 0.8, "copy edit undo")
        model.redo()
        model.requestThumbnail(for: model.photo(withID: masterPhoto.id)!)
        model.requestThumbnail(for: model.photo(withID: copyPhoto.id)!)
        try await waitFor("copy thumbnails") {
            model.thumbnail(for: model.photo(withID: masterPhoto.id)!) != nil && model.thumbnail(for: model.photo(withID: copyPhoto.id)!) != nil
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let masterBrightness = meanBrightness(model.thumbnail(for: model.photo(withID: masterPhoto.id)!)!)
        let copyBrightness = meanBrightness(model.thumbnail(for: model.photo(withID: copyPhoto.id)!)!)
        check(masterBrightness > copyBrightness + 30, "copy has its own thumbnail (\(Int(masterBrightness)) vs \(Int(copyBrightness)))")
        check(model.burstIndex.groups.first { $0.photoIDs.contains(masterPhoto.id) }?.shots.first?.contains(copyPhoto.id) == true,
              "copy shares its original's burst shot")

        _ = model.commitFolderSheet(PhotoFolderSheetRequest(kind: .create, initialName: "", selectedIDs: [masterPhoto.id]),
                                    name: "사본 폴더", includeSelected: true)
        model.focusPhoto(model.photo(withID: masterPhoto.id)!)
        model.createVirtualCopy()
        let secondCopy = model.selection!
        check(secondCopy.copyName == "사본 2" && model.visiblePhotos.contains { $0.id == secondCopy.id },
              "copy made inside a folder stays visible there")

        model.filter = .all
        model.handleTileClick(model.photo(withID: copyPhoto.id)!, clickCount: 1, modifiers: [])
        model.handleTileClick(model.photo(withID: masterPhoto.id)!, clickCount: 1, modifiers: .command)
        let copyExport = root.appendingPathComponent("copy-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copyExport, withIntermediateDirectories: true)
        model.export(scope: .selected, options: ExportOptions(maxPixel: 300), directory: copyExport)
        try await waitFor("copy export") { !model.isExporting }
        let exported = try FileManager.default.contentsOfDirectory(atPath: copyExport.path).sorted()
        check(exported == ["burst-1-sharp-edited-사본1.jpg", "burst-1-sharp-edited.jpg"],
              "original and copy export with the copy name: \(exported)")

        try model.flushSave()
        let copyReload = LibraryModel()
        copyReload.start()
        try await waitFor("copy reload") { copyReload.catalogLoaded && copyReload.foldersLoaded }
        check(copyReload.photo(withID: copyPhoto.id)?.edits.exposure == -1.5 &&
              copyReload.photo(withID: secondCopy.id)?.copyName == "사본 2", "copies restored after restart")

        // 비교 모드에서 기준 사진도 보정한 모습으로 보여 사본끼리 비교할 수 있다.
        model.filter = .all
        model.focusPhoto(model.photo(withID: masterPhoto.id)!)
        model.setMode(.compare)
        model.focusPhoto(model.photo(withID: copyPhoto.id)!)
        try await waitFor("copy compare") { !model.rendering && model.pinnedImage != nil && model.rendered != nil }
        let editedPinned = meanBrightness(model.pinnedImage!)
        let editedCopy = meanBrightness(model.rendered!)
        model.compareShowsPinnedEdits = false
        try await waitFor("pinned original") { !model.rendering && model.pinnedImage != nil }
        let originalPinned = meanBrightness(model.pinnedImage!)
        check(editedPinned > originalPinned + 20 && editedPinned > editedCopy + 30,
              "compare shows the pinned copy with its edits (\(Int(editedPinned)) vs original \(Int(originalPinned)), current \(Int(editedCopy)))")
        model.compareShowsPinnedEdits = true
        try await waitFor("pinned edited again") { !model.rendering && model.pinnedImage != nil }
        check(abs(meanBrightness(model.pinnedImage!) - editedPinned) < 1, "toggle back shows edits again")
        model.setMode(.grid)

        model.importURLs([masterPhoto.url])
        try await waitFor("reimport") { !model.isImporting }
        check(model.photos.filter { $0.path == masterPhoto.path }.count == 3, "re-importing the file adds no entry")

        let thumbFolder = ThumbnailStore.defaultDirectory.appendingPathComponent(copyPhoto.id.uuidString)
        check(FileManager.default.fileExists(atPath: thumbFolder.path), "copy thumbnail stored on disk")
        model.handleTileClick(model.photo(withID: copyPhoto.id)!, clickCount: 1, modifiers: [])
        model.requestDeleteVirtualCopies()
        check(model.catalogRemoval?.photos.map(\.id) == [copyPhoto.id] && model.catalogRemoval?.isCopiesOnly == true &&
              model.hasModalPresentation, "delete asks first")
        model.catalogRemoval = nil
        model.removeFromCatalog([copyPhoto.id])
        try await Task.sleep(nanoseconds: 300_000_000)
        check(model.photo(withID: copyPhoto.id) == nil && model.photo(withID: masterPhoto.id) != nil &&
              model.selectedID == masterPhoto.id && FileManager.default.fileExists(atPath: thumbFolder.path),
              "deleting removes only the copy, returns to the original and keeps its thumbnail for undo")
        model.removeFromCatalog([secondCopy.id])
        check(!model.photoFolders.contains { $0.photoIDs.contains(secondCopy.id) }, "deleted copy leaves folders")

        // 날짜 없는 사진의 사본은 다음 가져오기 뒤에도 원래 항목 옆에 있고, 검색으로 찾을 수 있다.
        model.filter = .all
        let undated = root.appendingPathComponent("undated-\(UUID().uuidString).png")
        try writeImage(undated, width: 30, height: 20, type: .png) { _, _ in (100, 110, 120) }
        let undatedB = root.appendingPathComponent("undatedb-\(UUID().uuidString).png")
        try writeImage(undatedB, width: 30, height: 20, type: .png) { _, _ in (120, 110, 100) }
        model.importURLs([undated, undatedB])
        try await waitFor("undated import") { !model.isImporting && model.photos.contains { $0.path.hasSuffix(undated.lastPathComponent) } }
        model.focusPhoto(model.photos.first { $0.path.hasSuffix(undated.lastPathComponent) }!)
        model.createVirtualCopy()
        let undatedCopy = model.selection!
        var copyLook = undatedCopy.edits
        copyLook.saturation = 0
        model.updateEdits(copyLook)
        let later = root.appendingPathComponent("later-\(UUID().uuidString).png")
        try writeImage(later, width: 30, height: 20, type: .png) { _, _ in (10, 20, 30) }
        model.importURLs([later])
        try await waitFor("later import") { !model.isImporting && model.photos.contains { $0.path.hasSuffix(later.lastPathComponent) } }
        let undatedIndex = model.photos.firstIndex { $0.path.hasSuffix(undated.lastPathComponent) && !$0.isVirtualCopy }!
        check(model.photos[undatedIndex + 1].id == undatedCopy.id, "undated copy stays next to its original after import")
        model.search = "사본"
        check(model.visiblePhotos.contains { $0.id == undatedCopy.id } && model.visiblePhotos.allSatisfy(\.isVirtualCopy),
              "search finds copies by name")
        model.search = ""
        model.focusPhoto(model.photos[undatedIndex])
        model.setRating(2)
        model.removeFromCatalog([undatedCopy.id])
        model.undo()
        check(model.photos[undatedIndex + 1].id == undatedCopy.id && model.photos[undatedIndex + 1].edits.saturation == 0,
              "undo puts a deleted copy back in place with its edits")
        model.undo()
        check(model.photos[undatedIndex].rating == 0, "the step before the deletion undoes next")
        model.undo()
        check(model.photo(withID: undatedCopy.id)?.edits.saturation == 1, "the restored copy's own steps undo too")
        model.removeFromCatalog([undatedCopy.id])
        check(FileManager.default.fileExists(atPath: masterPhoto.path), "original file kept")

        if rawSample != nil {
            // 10. RAW+JPEG 한 장으로 보기.
            let pairRoot = root.appendingPathComponent("pair-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: pairRoot, withIntermediateDirectories: true)
            let pairRAW = pairRoot.appendingPathComponent("PAIR1.RW2")
            try FileManager.default.copyItem(at: root.appendingPathComponent("S9-copy.RW2"), to: pairRAW)
            let pairJPEG = pairRoot.appendingPathComponent("PAIR1.JPG")
            try writeImage(pairJPEG, width: 60, height: 40, type: .jpeg) { _, _ in (140, 130, 120) }
            model.filter = .all
            model.collapsesRAWJPEGPairs = true
            let totalBefore = model.counts.total
            model.importURLs([pairRAW, pairJPEG])
            try await waitFor("pair import") { !model.isImporting && model.photos.contains { $0.path.hasSuffix("PAIR1.JPG") } }
            let rawEntry = model.photos.first { $0.path.hasSuffix("PAIR1.RW2") }!
            let jpegEntry = model.photos.first { $0.path.hasSuffix("PAIR1.JPG") }!
            check(model.visiblePhotos.contains { $0.id == rawEntry.id } && !model.visiblePhotos.contains { $0.id == jpegEntry.id } &&
                  model.hidesCompanion(of: rawEntry) && model.counts.total == totalBefore + 1,
                  "RAW+JPEG pair shows as one RAW")
            _ = model.commitFolderSheet(PhotoFolderSheetRequest(kind: .create, initialName: "", selectedIDs: [jpegEntry.id]),
                                        name: "JPEG만", includeSelected: true)
            let jpegFolder = model.photoFolders.first { $0.name == "JPEG만" }!
            check(model.visiblePhotos.map(\.id) == [jpegEntry.id] && model.counts.folders[jpegFolder.id] == 1,
                  "folder holding only the JPEG still shows it")
            model.filter = .all
            model.collapsesRAWJPEGPairs = false
            check(model.visiblePhotos.contains { $0.id == jpegEntry.id } && model.counts.total == totalBefore + 2 &&
                  !model.hidesCompanion(of: rawEntry), "turning off shows the JPEG again")
            model.collapsesRAWJPEGPairs = true

            // 11. 카탈로그에서 빼기: 한 장으로 본 RAW+JPEG는 함께, 원본 파일은 그대로.
            model.focusPhoto(model.photo(withID: rawEntry.id)!)
            model.requestRemoveFromCatalog()
            check(Set(model.catalogRemoval?.photos.map(\.id) ?? []) == [rawEntry.id, jpegEntry.id] &&
                  model.catalogRemoval?.hiddenCompanions == 1 && model.catalogRemoval?.isCopiesOnly == false,
                  "removing a collapsed RAW asks to take its JPEG too")
            let removal = model.catalogRemoval!
            model.catalogRemoval = nil
            model.removeFromCatalog(Set(removal.photos.map(\.id)))
            check(model.photo(withID: rawEntry.id) == nil && model.photo(withID: jpegEntry.id) == nil &&
                  !model.photoFolders.contains { $0.photoIDs.contains(jpegEntry.id) } && model.counts.total == totalBefore &&
                  FileManager.default.fileExists(atPath: pairRAW.path) && FileManager.default.fileExists(atPath: pairJPEG.path),
                  "catalog removal drops entries and folder links but keeps files")
            model.collapsesRAWJPEGPairs = false
            model.importURLs([pairJPEG])
            try await waitFor("jpeg reimport") { !model.isImporting && model.photos.contains { $0.path == jpegEntry.path } }
            let fresh = model.photos.first { $0.path == jpegEntry.path }!
            model.focusPhoto(fresh)
            model.requestRemoveFromCatalog()
            check(model.catalogRemoval?.photos.map(\.id) == [fresh.id] && model.catalogRemoval?.hiddenCompanions == 0,
                  "lone JPEG removal asks for itself only")
            model.catalogRemoval = nil
        }

        let backupDay = CatalogBackup.defaultDirectory.appendingPathComponent(CatalogBackup.folderName(for: Date()))
        try await waitFor("backup") { FileManager.default.fileExists(atPath: backupDay.appendingPathComponent("catalog.json").path) }
        check(try CatalogStore(url: backupDay.appendingPathComponent("catalog.json")).load().count == photos.count,
              "today's backup holds the catalog as first opened")
        model.collapsesRAWJPEGPairs = true

        // 12. 원본 없음 표시와 위치 다시 찾기.
        let moveRoot = root.appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
        let oldTrip = moveRoot.appendingPathComponent("Trip", isDirectory: true)
        for day in ["Day1", "Day2"] {
            try FileManager.default.createDirectory(at: oldTrip.appendingPathComponent(day), withIntermediateDirectories: true)
        }
        let m1 = oldTrip.appendingPathComponent("Day1/m1.png"), m2 = oldTrip.appendingPathComponent("Day2/m2.png")
        try writeImage(m1, width: 30, height: 20, type: .png) { _, _ in (10, 200, 10) }
        try writeImage(m2, width: 30, height: 20, type: .png) { _, _ in (200, 10, 10) }
        model.filter = .all
        model.importURLs([oldTrip])
        try await waitFor("trip import") { !model.isImporting && model.photos.contains { $0.path.hasSuffix("Day2/m2.png") } }
        let e1 = model.photos.first { $0.path.hasSuffix("Day1/m1.png") }!, e2 = model.photos.first { $0.path.hasSuffix("Day2/m2.png") }!
        model.requestThumbnail(for: e1)
        model.requestThumbnail(for: e2)
        try await waitFor("trip thumbnails") { model.thumbnail(for: e1) != nil && model.thumbnail(for: e2) != nil }
        model.focusPhoto(e1)
        model.createVirtualCopy()
        let e1Copy = model.selection!
        check(model.counts.missing == 0 && !model.isMissing(e1), "present originals are not missing")
        let newTrip = moveRoot.appendingPathComponent("NewTrip", isDirectory: true)
        try FileManager.default.moveItem(at: oldTrip, to: newTrip)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await waitFor("missing scan") { model.counts.missing == 3 }
        model.filter = .missing
        check(Set(model.visiblePhotos.map(\.id)) == [e1.id, e1Copy.id, e2.id] && model.isMissing(e1Copy),
              "moved originals show as missing after returning to the app")
        // 다시 실행한 것처럼 메모리 캐시를 비우면 원본 없이도 보관한 마지막 썸네일이 보인다.
        model.thumbnailCache.removeAllObjects()
        for photo in [e1, e1Copy, e2] { model.requestThumbnail(for: photo) }
        try await waitFor("fallback thumbnails") {
            model.thumbnail(for: e1) != nil && model.thumbnail(for: e2) != nil && model.unavailableThumbnails.contains(e1Copy.id)
        }
        check(model.thumbnailCache.object(forKey: e1.id.uuidString as NSString)?.isFallback == true &&
              model.thumbnail(for: e1)?.size == NSSize(width: 30, height: 20),
              "missing original shows its last stored thumbnail")
        model.requestThumbnail(for: e1Copy)
        model.requestThumbnail(for: e1)
        check(!model.loadingThumbnails.contains(e1Copy.id.uuidString) && !model.loadingThumbnails.contains(e1.id.uuidString),
              "missing originals are not retried on every appearance")
        model.relocateMissing(from: e1, to: newTrip.appendingPathComponent("Day1"))
        check(model.photo(withID: e1.id)!.path.hasSuffix("NewTrip/Day1/m1.png") &&
              model.photo(withID: e1Copy.id)!.path == model.photo(withID: e1.id)!.path &&
              model.isMissing(model.photo(withID: e2.id)!) && model.counts.missing == 1,
              "choosing the file's folder relinks that folder and its copies only")
        try await waitFor("relinked thumbnails") {
            model.thumbnailCache.object(forKey: e1.id.uuidString as NSString)?.isFallback == false &&
                model.thumbnail(for: e1Copy) != nil
        }
        check(model.thumbnailCache.object(forKey: e2.id.uuidString as NSString)?.isFallback == true &&
              !model.unavailableThumbnails.contains(e1Copy.id),
              "relinking refreshes that folder's thumbnails and leaves still-missing ones as they were")
        model.relocateMissing(from: model.photo(withID: e2.id)!, to: newTrip)
        check(model.photo(withID: e2.id)!.path.hasSuffix("NewTrip/Day2/m2.png") && model.counts.missing == 0,
              "choosing a parent folder relinks through the date folders")
        model.relocateMissing(from: model.photo(withID: e2.id)!, to: root)
        check(model.photo(withID: e2.id)!.path.hasSuffix("NewTrip/Day2/m2.png"), "wrong folder changes nothing")
        try FileManager.default.removeItem(at: newTrip.appendingPathComponent("Day2/m2.png"))
        model.refreshMissingOriginals()
        try await waitFor("second scan") { model.counts.missing == 1 }
        check(model.visiblePhotos.map(\.id) == [e2.id], "deleted file shows up in the missing list")
        model.filter = .all

        // 13. 정렬.
        let captureOrder = model.visiblePhotos.map(\.id)
        model.sortOrder = .fileName
        let names = model.visiblePhotos.map(\.displayName)
        check(zip(names, names.dropFirst()).allSatisfy { $0.localizedStandardCompare($1) != .orderedDescending } &&
              Set(model.visiblePhotos.map(\.id)) == Set(captureOrder), "file name order sorts the same photos")
        model.sortOrder = .rating
        let ratings = model.visiblePhotos.map(\.rating)
        check(zip(ratings, ratings.dropFirst()).allSatisfy { $0 >= $1 }, "rating order puts higher stars first")
        model.sortOrder = .captureTime
        check(model.visiblePhotos.map(\.id) == captureOrder, "capture order is restored")

        model.setMode(.grid)
        model.clearPhotoSelection()
        model.focusPhoto(model.visiblePhotos[0])
        model.toggleFocusView()
        check(model.isFocusView && model.mode == .edit, "F from the grid opens the photo alone")
        model.setMode(.grid)
        check(!model.isFocusView, "returning to the grid ends the focus view")
        model.toggleFocusView()
        model.toggleFocusView()
        check(!model.isFocusView && model.mode == .edit, "F again leaves the photo view open")

        // 15. ⇧⌘C / ⇧⌘V 보정 복사·붙여넣기.
        let pasteSource = model.visiblePhotos[0], pasteA = model.visiblePhotos[1], pasteB = model.visiblePhotos[2]
        model.focusPhoto(pasteSource)
        var pastedLook = pasteSource.edits
        pastedLook.exposure = 0.55
        pastedLook.cropRect = NormalizedCrop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        model.updateEdits(pastedLook)
        model.copyEdits()
        let cropBeforeA = model.photo(withID: pasteA.id)!.edits.cropRect
        model.focusPhoto(model.photo(withID: pasteA.id)!)
        model.handleTileClick(model.photo(withID: pasteB.id)!, clickCount: 1, modifiers: [.command])
        model.pasteEditsToSelection()
        check(model.photo(withID: pasteA.id)!.edits.exposure == 0.55 && model.photo(withID: pasteB.id)!.edits.exposure == 0.55 &&
              model.photo(withID: pasteA.id)!.edits.cropRect == cropBeforeA, "paste copies global edits to the selection, not crop")
        model.undo()
        check(model.photo(withID: pasteA.id)!.edits.exposure != 0.55 && model.photo(withID: pasteB.id)!.edits.exposure != 0.55,
              "one undo reverts the paste on every photo")
        model.clearPhotoSelection()

        // 14. 키워드·설명.
        let tagged = model.visiblePhotos[0], other = model.visiblePhotos[1]
        model.focusPhoto(tagged)
        model.setKeywords(" 바다, 노을 ,바다", for: tagged.id)
        model.setCaption("  제주 협재  ", for: tagged.id)
        check(model.photo(withID: tagged.id)!.keywords == ["바다", "노을"] && model.photo(withID: tagged.id)!.caption == "제주 협재",
              "keywords and caption are cleaned and stored")
        model.search = "노을"
        check(model.visiblePhotos.map(\.id) == [tagged.id], "search finds photos by keyword")
        model.search = "협재"
        check(model.visiblePhotos.map(\.id) == [tagged.id], "search finds photos by caption")
        model.search = ""
        model.undo()
        check(model.photo(withID: tagged.id)!.caption == "" && model.photo(withID: tagged.id)!.keywords == ["바다", "노을"],
              "undo restores the caption first")
        model.redo()
        model.handleTileClick(model.photo(withID: other.id)!, clickCount: 1, modifiers: [.command])
        check(model.selectedPhotoIDs == [tagged.id, other.id], "two photos selected for keywords")
        model.addKeywordsToSelection("여행, 바다")
        check(model.photo(withID: tagged.id)!.keywords == ["바다", "노을", "여행"] && model.photo(withID: other.id)!.keywords.contains("여행"),
              "adding keywords appends to each selected photo")
        model.undo()
        check(model.photo(withID: tagged.id)!.keywords == ["바다", "노을"] && !model.photo(withID: other.id)!.keywords.contains("여행"),
              "adding to a selection undoes in one step")
        model.clearPhotoSelection()
        model.focusPhoto(model.photo(withID: tagged.id)!)
        let keywordRoot = root.appendingPathComponent("keyword-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: keywordRoot, withIntermediateDirectories: true)
        model.export(scope: .current, options: ExportOptions(quality: 0.8), directory: keywordRoot)
        try await waitFor("keyword export") { !model.isExporting }
        let keywordFiles = try FileManager.default.contentsOfDirectory(at: keywordRoot, includingPropertiesForKeys: nil)
        let keywordSource = CGImageSourceCreateWithURL(keywordFiles[0] as CFURL, nil)!
        let keywordProperties = CGImageSourceCopyPropertiesAtIndex(keywordSource, 0, nil) as! [CFString: Any]
        let iptc = keywordProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        check(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["바다", "노을"] &&
              iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String == "제주 협재", "exported JPEG carries keywords and caption")
        model.export(scope: .current, options: ExportOptions(quality: 0.8, format: .heif, colorSpace: .displayP3),
                     directory: keywordRoot)
        try await waitFor("heif export") { !model.isExporting }
        let heif = try FileManager.default.contentsOfDirectory(at: keywordRoot, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "heic" }
        let heifSource = heif.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        check(heifSource.flatMap { CGImageSourceGetType($0) as String? } == "public.heic" &&
              model.exportReport?.hasPrefix("1장 내보냄") == true, "HEIF export writes a .heic file")

        try model.flushSave()
        let original = try Data(contentsOf: a)
        check(!original.isEmpty && [a, b, c].allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
              "originals untouched in place")
    }
}
