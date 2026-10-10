import AppKit
import LighthouseCore

/// 한 사진의 얼굴 확대 결과. 같은 원본(가상 사본 포함)은 결과를 함께 쓴다.
struct FaceCloseupResult {
    let path: String
    /// 분석한 미리보기의 픽셀 크기(방향 적용). 얼굴 위치를 보정 구도로 옮길 때 쓴다.
    let imageSize: CGSize
    let faces: [FaceCloseup]
    /// 얼굴마다 자른 정사각형 확대 그림(`faces`와 같은 순서).
    let crops: [NSImage]
    /// 같은 사진의 다른 얼굴보다 크게 흐린 얼굴의 위치.
    let softFaces: Set<Int>
}

extension LibraryModel {
    /// 사진 보기에서 지금 사진의 얼굴을 모은다(보정 전 원본 미리보기, 긴 변 2048px). 같은 원본은 최근 24장까지 기억해
    /// 다시 분석하지 않고, 사진을 빨리 넘기면 시작 전인 이전 분석은 건너뛴다.
    func refreshFaceCloseups() {
        faceCloseupCancellation?.cancel()
        faceCloseupCancellation = nil
        guard showsFaceCloseups, mode == .edit, let photo = selection, !isMissing(photo) else {
            faceCloseups = nil
            return
        }
        if let cached = faceCloseupCache[photo.path] {
            faceCloseups = cached
            return
        }
        if faceCloseups?.path != photo.path { faceCloseups = nil }
        let cancellation = CancellationFlag()
        faceCloseupCancellation = cancellation
        let url = photo.url, path = photo.path
        faceCloseupQueue.async { [pipeline] in
            guard !cancellation.isCancelled else { return }
            let image = try? pipeline.thumbnail(for: url, maxPixel: 2048)
            let found = image.map { Self.collectFaces(in: $0) } ?? []
            let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            let analyzed = image != nil
            DispatchQueue.main.async {
                let faces = found.map(\.face)
                let result = FaceCloseupResult(
                    path: path, imageSize: size, faces: faces,
                    crops: found.map { NSImage(cgImage: $0.crop, size: NSSize(width: $0.crop.width, height: $0.crop.height)) },
                    softFaces: FaceCloseupAnalyzer.softFaceIndices(faces))
                // 읽지 못한 사진은 기억하지 않아 다음에 다시 시도한다.
                if analyzed { self.rememberFaceCloseups(result) }
                guard self.faceCloseupCancellation === cancellation else { return }
                self.faceCloseupCancellation = nil
                self.faceCloseups = result
            }
        }
    }

    private nonisolated static func collectFaces(in image: CGImage) -> [(face: FaceCloseup, crop: CGImage)] {
        let size = CGSize(width: image.width, height: image.height)
        return FaceCloseupAnalyzer.analyze(image).compactMap { face in
            image.cropping(to: FaceCloseupAnalyzer.cropRect(for: face.bounds, imageSize: size)).map { (face, shrunk($0)) }
        }
    }

    /// 확대 칸은 112pt라 2배 화면에서도 224px면 충분하다. 큰 얼굴을 자른 그대로 기억하면 한 장에 수 MB가 된다.
    private nonisolated static func shrunk(_ crop: CGImage, maxSide: Int = 224) -> CGImage {
        guard max(crop.width, crop.height) > maxSide,
              let context = CGContext(data: nil, width: maxSide, height: maxSide, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: crop.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return crop }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: maxSide, height: maxSide))
        return context.makeImage() ?? crop
    }

    private func rememberFaceCloseups(_ result: FaceCloseupResult) {
        faceCloseupCache[result.path] = result
        faceCloseupCacheOrder.removeAll { $0 == result.path }
        faceCloseupCacheOrder.append(result.path)
        while faceCloseupCacheOrder.count > 24 {
            faceCloseupCache.removeValue(forKey: faceCloseupCacheOrder.removeFirst())
        }
    }

    /// 얼굴 확대에서 누른 얼굴의 가운데를 100%로 보인다. 보정 구도(회전·수평·크롭)를 거친 화면 위치로 바꾼다.
    func showFace(_ index: Int) {
        guard let result = faceCloseups, result.faces.indices.contains(index), let photo = selection,
              result.path == photo.path else { return }
        let face = result.faces[index].bounds
        let geometry = PhotoGeometry(sourceWidth: result.imageSize.width, sourceHeight: result.imageSize.height,
                                     edits: photo.edits)
        let point = geometry.displayPoint(fromSource: MaskPoint(x: face.midX, y: face.midY))
        showActualSize(at: CGPoint(x: point.x, y: point.y))
    }

    /// 사진 안 0…1 위치(위쪽이 0)를 100%로 보인다. 이미 100%면 끄지 않고 그 자리로 옮긴다.
    func showActualSize(at anchor: CGPoint) {
        let clamped = CGPoint(x: min(1, max(0, anchor.x)), y: min(1, max(0, anchor.y)))
        if actualSize {
            zoomAnchor = clamped
            zoomRequest += 1
        } else {
            toggleActualSize(at: clamped)
        }
    }
}
