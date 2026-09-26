import AppKit
import Foundation
import LighthouseCore

/// 썸네일, 편집 미리보기 렌더, 미리 현상.
@MainActor
extension LibraryModel {
    func thumbnail(for photo: PhotoAsset) -> NSImage? {
        thumbnailCache.object(forKey: photo.id.uuidString as NSString)?.image
    }

    /// 보정한 사진은 보정 결과로 썸네일을 만든다. 편집 화면의 사진은 미리보기 렌더가 썸네일을 갱신한다.
    /// 썸네일은 디스크에도 보관해 다음 실행 때 RAW를 다시 현상하지 않고, 원본이 없어도 마지막 모습을 보여 준다.
    func requestThumbnail(for photo: PhotoAsset) {
        let wanted: EditSettings? = photo.edits.isModified ? photo.edits : nil
        // 가상 사본은 같은 파일을 가리키므로 파일 경로가 아니라 항목 ID로 캐시한다.
        let cacheKey = photo.id.uuidString
        let entry = thumbnailCache.object(forKey: cacheKey as NSString)
        // 대신 보여 주던 마지막 썸네일은 원본이 없다고 확인된 동안만 그대로 둔다.
        if let entry, entry.edits == wanted, !entry.isFallback || isMissing(photo) { return }
        if entry != nil, wanted != nil, photo.id == selectedID, showsSingleImage, !isOriginal { return }
        guard !loadingThumbnails.contains(cacheKey), !unavailableThumbnails.contains(photo.id) else { return }
        loadingThumbnails.insert(cacheKey)
        let size = Self.thumbnailPixels
        thumbnailQueue.async { [pipeline, thumbnailStore] in
            // 보정 여부와 관계없이 디스크에 보관한 썸네일을 먼저 쓰고, 없으면 만들어 보관한다.
            // 원본을 읽을 수 없으면 키를 만들 수 없으므로 마지막으로 보관한 썸네일을 보여 준다.
            let key = ThumbnailStore.key(for: photo)
            var image = key.flatMap { thumbnailStore.load(photoID: photo.id, key: $0) }
            if image == nil, let key {
                if let wanted, let rendered = try? pipeline.renderPreview(url: photo.url, edits: wanted, maxPixel: size).image {
                    image = rendered
                    thumbnailStore.store(rendered, photoID: photo.id, key: key)
                } else if let plain = try? pipeline.thumbnail(for: photo.url, maxPixel: size) {
                    image = plain
                    // 보정한 사진인데 보정 렌더에 실패해 보정 전 모습이면 보관하지 않는다.
                    if wanted == nil { thumbnailStore.store(plain, photoID: photo.id, key: key) }
                }
            }
            let fallback = image == nil && key == nil ? thumbnailStore.latest(photoID: photo.id) : nil
            let unavailable = image == nil && key == nil && fallback == nil
            DispatchQueue.main.async {
                self.loadingThumbnails.remove(cacheKey)
                if let shown = image ?? fallback { self.storeThumbnail(shown, id: photo.id, edits: wanted, isFallback: fallback != nil) }
                if unavailable { self.unavailableThumbnails.insert(photo.id) }
                if let latest = self.photo(withID: photo.id),
                   (latest.edits.isModified ? latest.edits : nil) != wanted {
                    self.requestThumbnail(for: latest)
                }
            }
        }
    }

    /// 원본이 돌아오거나 다시 연결된 사진은 대신 보여 주던 썸네일을 새로 만들고, 썸네일이 없던 사진은 다시 찾는다.
    func missingOriginalsDidChange() {
        let returned = fallbackThumbnailIDs.union(unavailableThumbnails).compactMap(photo(withID:)).filter { !isMissing($0) }
        for photo in returned {
            unavailableThumbnails.remove(photo.id)
            requestThumbnail(for: photo)
        }
    }

    private func storeThumbnail(_ image: CGImage, id: UUID, edits: EditSettings?, isFallback: Bool = false) {
        if isFallback { fallbackThumbnailIDs.insert(id) } else { fallbackThumbnailIDs.remove(id) }
        let entry = ThumbnailEntry(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                                   edits: edits, isFallback: isFallback)
        thumbnailCache.setObject(entry, forKey: id.uuidString as NSString, cost: image.width * image.height * 4)
        objectWillChange.send()
    }

    /// HDR을 표시할 수 있는 화면이 있는지. 없으면 HDR 하이라이트를 쓴 사진도 SDR로 그려 시간을 아낀다.
    static var hdrDisplayAvailable: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }

    /// 썸네일은 sRGB 8비트로 줄인다. HDR로 그린 결과도 SDR 흰색에서 잘린다.
    nonisolated private static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 슬라이더를 움직이는 동안에도 `renderInterval`마다 그린다. 같은 사진의 중간 결과는 순서대로 보여 주고,
    /// 다른 사진이나 원본·100% 보기로 바뀐 뒤 도착한 결과는 버린다.
    func requestRender(debounce: Bool = false) {
        renderDelay?.cancel()
        renderJob?.cancel()
        generation += 1
        let token = generation
        let source = "\(selectedID?.uuidString ?? "none"):\(isOriginal):\(actualSize)"
        if renderedSource != source {
            rendered = enlargedForActualSize(previousSource: renderedSource)
            imageError = nil
            renderedSource = source
            displayedToken = 0
            histogram = nil
            clippingOverlay = nil
        }
        if mode != .compare { pinnedImage = nil; pinnedError = nil; pinnedSource = nil; pinnedRenderedEdits = nil }
        requestSplitBefore()
        requestSurveyImages()
        requestMask()
        refreshRAWCapabilities()
        guard showsSingleImage, let photo = selection else { rendering = false; return }
        let edits = isOriginal ? EditSettings.neutral : photo.edits
        let maxPixel: Int? = actualSize ? nil : 2200
        let compare = mode == .compare ? pinned : nil
        let pinnedKey = compare.map { "\($0.id):\(maxPixel ?? 0)" }
        let pinnedEdits = compare.map { compareShowsPinnedEdits ? $0.edits : EditSettings.neutral }
        let reference = pinnedKey != pinnedSource || pinnedEdits != pinnedRenderedEdits ? compare : nil
        let recentKey = actualSize ? nil : "\(photo.id):\(isOriginal)"
        let recent = recentKey.flatMap { key in recentRenders.last { $0.key == key } }
        let renderCurrent = recent?.edits != edits
        if let recent, let recentKey, !renderCurrent {
            rendered = recent.image
            imageError = nil
            displayedToken = token
            histogram = recent.histogram
            refreshClippingOverlay()
            rememberRender(recent.image, key: recentKey, edits: edits, histogram: recent.histogram)
            if reference == nil {
                rendering = false
                prefetchNeighbor()
                return
            }
        } else if rendered == nil {
            if let recent {
                rendered = recent.image
                histogram = recent.histogram
            } else if photo.isRAW, !actualSize, isOriginal || !photo.edits.isModified {
                requestPlaceholder(for: photo, source: source)
            }
        }
        rendering = true
        exactRenderFollowUp?.cancel()
        let approximate = editDragActive && !isOriginal && !actualSize
        requestedApproximation = approximate
        let thumbnailSize = renderCurrent && !isOriginal && edits.isModified ? Self.thumbnailPixels : nil
        let hdr = !isOriginal && photo.isRAW && edits.hdrAmount > 0 && Self.hdrDisplayAvailable
        // 백그라운드 큐에서 돈다. @Sendable로 표시해 화면 상태를 여기서 건드리지 않는지 컴파일러가 검사하게 한다.
        let job = DispatchWorkItem { @Sendable [previewPipeline] in
            let preview = renderCurrent
                ? Result { try previewPipeline.renderPreview(url: photo.url, edits: edits, maxPixel: maxPixel,
                                                             allowApproximation: approximate, hdr: hdr) } : nil
            let current = preview.map { result in result.map(\.image) }
            let isApproximate = (try? preview?.get())?.isApproximate ?? false
            let thumbnail = isApproximate ? nil : thumbnailSize.flatMap { size in
                (try? current?.get()).flatMap { Self.downscaled($0, maxPixel: size) }
            }
            let histogram = (try? current?.get()).flatMap { ImageHistogram.make(from: $0) }
            // 기준 사진도 편집 미리보기 파이프라인으로 그려 같은 사진을 편집하는 동안 현상을 재사용한다.
            let referenceResult = reference.map { fixed in
                Result { try previewPipeline.renderPreview(url: fixed.url, edits: pinnedEdits ?? .neutral,
                                                           maxPixel: maxPixel, allowApproximation: approximate) }
            }
            DispatchQueue.main.async {
                guard token == self.generation else {
                    guard source == self.renderedSource, token > self.displayedToken,
                          case .success(let cg)? = current else { return }
                    self.displayedToken = token
                    self.rendered = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.histogram = histogram
                    return
                }
                self.rendering = false
                switch current {
                case .success(let cg)?:
                    self.imageError = nil
                    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.rendered = image
                    self.displayedToken = token
                    self.histogram = histogram
                    self.refreshClippingOverlay()
                    self.showingApproximation = isApproximate
                    if isApproximate {
                        // 끝을 알리지 않는 입력(키보드로 슬라이더 조절 등)도 잠시 멈추면 정확히 다시 그린다.
                        let followUp = DispatchWorkItem { [weak self] in
                            guard let self, token == self.generation, self.showingApproximation else { return }
                            self.editDragActive = false
                            self.requestRender()
                        }
                        self.exactRenderFollowUp = followUp
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: followUp)
                    } else if let recentKey {
                        self.rememberRender(image, key: recentKey, edits: edits, histogram: histogram)
                    }
                case .failure(let error)?:
                    AppLog.render.error("preview failed: \(photo.filename, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    self.rendered = nil
                    self.imageError = error.localizedDescription
                    self.histogram = nil
                    self.clippingOverlay = nil
                case nil:
                    break
                }
                if let thumbnail, let latest = self.photo(withID: photo.id), latest.edits == edits {
                    self.storeThumbnail(thumbnail, id: photo.id, edits: edits)
                    self.thumbnailQueue.async { [thumbnailStore = self.thumbnailStore] in
                        if let key = ThumbnailStore.key(for: latest) {
                            thumbnailStore.store(thumbnail, photoID: latest.id, key: key)
                        }
                    }
                }
                if let referenceResult {
                    switch referenceResult {
                    case .success(let result):
                        self.pinnedError = nil
                        self.pinnedImage = NSImage(cgImage: result.image,
                                                   size: NSSize(width: result.image.width, height: result.image.height))
                        // 근사로 그린 기준 사진은 다음 렌더에서 정확히 다시 그린다.
                        self.pinnedRenderedEdits = result.isApproximate ? nil : pinnedEdits
                    case .failure(let error):
                        AppLog.render.error("compare reference failed: \(error.localizedDescription, privacy: .private)")
                        self.pinnedImage = nil
                        self.pinnedError = error.localizedDescription
                        self.pinnedRenderedEdits = pinnedEdits
                    }
                    self.pinnedSource = pinnedKey
                }
                self.prefetchNeighbor()
            }
        }
        renderJob = job
        let delay = debounce ? max(0, Self.renderInterval - Date().timeIntervalSince(lastRenderDispatch)) : 0
        let dispatch = DispatchWorkItem {
            self.lastRenderDispatch = Date()
            self.previewQueue.async(execute: job)
        }
        renderDelay = dispatch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dispatch)
    }

    /// 나눠 보기의 보정 전 모습이 보여야 하는지.
    var isSplitActive: Bool { showsSplit && mode == .edit && !isOriginal && !actualSize }

    func toggleSplit() {
        if mode != .edit { setMode(.edit) }
        if isOriginal { isOriginal = false }
        if actualSize { actualSize = false }
        showsSplit.toggle()
        requestRender()
    }

    /// 보정 전 모습은 구도만 적용해 그린다. 사진이나 구도가 바뀔 때만 다시 그리고, 다른 보정을 바꾸는 동안에는 그대로 둔다.
    private func requestSplitBefore() {
        guard isSplitActive, let photo = selection else {
            splitBefore = nil
            splitBeforeState = nil
            return
        }
        let before = EditSettings.neutral.merging(from: photo.edits, components: .geometry)
        if let state = splitBeforeState, state.id == photo.id, state.edits == before { return }
        splitBefore = nil
        splitBeforeState = (photo.id, before)
        splitQueue.async { [pipeline] in
            let image = try? pipeline.renderPreview(url: photo.url, edits: before, maxPixel: 2200).image
            DispatchQueue.main.async {
                guard let state = self.splitBeforeState, state.id == photo.id, state.edits == before else { return }
                self.splitBefore = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
    }

    /// 선택한 RAW에서 조절할 수 있는 디코더 항목과 기본값을 읽는다. 파일마다 한 번만 읽는다.
    private func refreshRAWCapabilities() {
        guard let photo = selection else { rawCapabilities = nil; rawCapabilitiesPath = nil; return }
        guard rawCapabilitiesPath != photo.path else { return }
        rawCapabilitiesPath = photo.path
        if let known = rawCapabilitiesByPath[photo.path] { rawCapabilities = known; return }
        rawCapabilities = nil
        guard photo.isRAW else { return }
        let path = photo.path
        placeholderQueue.async { [pipeline] in
            let capabilities = pipeline.rawCapabilities(for: photo.url)
            DispatchQueue.main.async {
                self.rawCapabilitiesByPath[path] = capabilities
                if self.rawCapabilitiesPath == path { self.rawCapabilities = capabilities }
            }
        }
    }

    private func rememberRender(_ image: NSImage, key: String, edits: EditSettings, histogram: ImageHistogram?) {
        recentRenders.removeAll { $0.key == key }
        recentRenders.append((key, edits, image, histogram))
        if recentRenders.count > Self.recentRenderLimit {
            recentRenders.removeFirst(recentRenders.count - Self.recentRenderLimit)
        }
    }

    /// 현상한 결과가 보일 때만 클리핑 표시를 만든다. 카메라 미리보기에는 히스토그램과 표시를 만들지 않는다.
    func refreshClippingOverlay() {
        overlayToken += 1
        let token = overlayToken
        guard showsClipping, histogram != nil,
              let image = rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            clippingOverlay = nil
            return
        }
        placeholderQueue.async {
            let overlay = ImageHistogram.clippingOverlay(for: image)
            DispatchQueue.main.async {
                guard token == self.overlayToken else { return }
                self.clippingOverlay = overlay.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
    }

    /// 화면 맞춤에서 100%로 바꾸면 원본 크기 렌더가 올 때까지 지금 그림을 원본 크기로 늘려 먼저 보여 준다.
    /// 그 사이 사진이 사라지지 않고 누른 곳이 바로 100% 자리에 온다(S9는 0.3–0.8초).
    private func enlargedForActualSize(previousSource: String?) -> NSImage? {
        guard actualSize, let photo = selection, previousSource == "\(photo.id.uuidString):\(isOriginal):false",
              let cg = rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let size = previewPipeline.outputSize(url: photo.url, edits: isOriginal ? .neutral : photo.edits),
              size.width > CGFloat(cg.width) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    /// RAW 안의 카메라 미리보기를 현상이 끝날 때까지 먼저 보여 준다. 보정하지 않은 사진에만 쓴다.
    private func requestPlaceholder(for photo: PhotoAsset, source: String) {
        placeholderQueue.async { [pipeline] in
            let image = pipeline.embeddedPreview(for: photo.url, maxPixel: 2200)
            DispatchQueue.main.async {
                guard let image, self.renderedSource == source, self.rendered == nil, self.rendering else { return }
                self.rendered = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    /// 방금 이동한 방향의 다음 사진을 미리 현상해 두면 넘기는 즉시 보인다.
    private func prefetchNeighbor() {
        guard showsSingleImage, !actualSize, let current = selectedID else { return }
        let visible = visiblePhotos
        guard let index = visible.firstIndex(where: { $0.id == current }),
              visible.indices.contains(index + moveDirection) else { return }
        let photo = visible[index + moveDirection]
        let originalView = isOriginal
        let edits = originalView ? EditSettings.neutral : photo.edits
        let key = "\(photo.id):\(originalView)"
        guard !prefetching.contains(key), !recentRenders.contains(where: { $0.key == key && $0.edits == edits }) else {
            return
        }
        prefetching.insert(key)
        prefetchQueue.async { [pipeline] in
            let cg = try? pipeline.renderPreview(url: photo.url, edits: edits, maxPixel: 2200).image
            let histogram = cg.flatMap { ImageHistogram.make(from: $0) }
            DispatchQueue.main.async {
                self.prefetching.remove(key)
                guard let cg, let latest = self.photo(withID: photo.id),
                      (originalView ? EditSettings.neutral : latest.edits) == edits else { return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.rememberRender(image, key: key, edits: edits, histogram: histogram)
                if self.renderedSource == "\(photo.id):\(originalView):false", self.displayedToken == 0,
                   self.rendering {
                    self.rendered = image
                    self.histogram = histogram
                }
            }
        }
    }
}
