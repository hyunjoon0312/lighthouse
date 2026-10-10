import CoreGraphics
import CoreImage
import Foundation
import Vision

/// 사진 속 얼굴 하나의 확대 정보. 좌표는 방향을 적용한 사진의 0…1(왼쪽 위 원점)이다.
public struct FaceCloseup: Equatable, Sendable {
    /// Vision이 찾은 얼굴 영역.
    public var bounds: CGRect
    /// 두 눈을 모두 감았으면 true. 눈 위치를 찾지 못했으면 nil이다.
    public var eyesClosed: Bool?
    /// 얼굴 안 라플라시안 분산(가장 선명한 1/4 칸 평균, 긴 변 128px 기준). 같은 사진의 얼굴끼리만 비교한다.
    /// 판단하기에 너무 작은 얼굴은 nil이다.
    public var sharpness: Double?

    public init(bounds: CGRect, eyesClosed: Bool?, sharpness: Double?) {
        self.bounds = bounds
        self.eyesClosed = eyesClosed
        self.sharpness = sharpness
    }
}

/// 사진 보기에서 얼굴을 크게 모아 보이기 위한 분석. 보정 전 원본(방향 적용) 미리보기를 쓰며, 결과는 저장하지 않는다.
public enum FaceCloseupAnalyzer {
    /// 확대해도 알아보기 어려운 얼굴(분석 그림에서 32px 미만)은 뺀다.
    static let minimumFace = 32.0
    /// 흐림을 비교할 수 있는 얼굴 크기.
    static let judgeableFace = 48.0
    /// 같은 사진에서 가장 선명한 얼굴보다 이만큼(배) 덜 선명하면 흐린 얼굴로 본다. 서로 다른 사람의 선명한 얼굴도
    /// 조명·피부에 따라 3배 차이가 나서(표본 1409 대 452) 그보다 훨씬 아래로 잡았다. σ 1.5 흐림은 0.05배였다.
    static let softRatio = 0.2

    /// 큰 얼굴부터 `limit`개. 눈 감음은 Core Image 얼굴 검출기의 눈 깜빡임 판정을 Vision 얼굴과 겹치는 것끼리 맞춰 쓴다
    /// (`PhotoQualityAnalyzer.eyesClosed`와 같은 판정).
    public static func analyze(_ image: CGImage, limit: Int = 12) -> [FaceCloseup] {
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) } catch { return [] }
        let width = Double(image.width), height = Double(image.height)
        let blinks = eyeStates(in: image)
        let faces = (request.results ?? [])
            .filter { $0.confidence >= 0.5 }
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            .filter { $0.width * width >= minimumFace && $0.height * height >= minimumFace }
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(limit)
        return faces.map { bounds in
            let pixels = CGRect(x: bounds.minX * width, y: bounds.minY * height, width: bounds.width * width,
                                height: bounds.height * height)
            let match = blinks.max { overlap($0.bounds, bounds) < overlap($1.bounds, bounds) }
            return FaceCloseup(bounds: bounds,
                               eyesClosed: match.flatMap { overlap($0.bounds, bounds) >= 0.3 ? $0.closed : nil },
                               sharpness: pixels.width >= judgeableFace ? sharpness(of: image, in: pixels) : nil)
        }
    }

    /// 같은 사진의 가장 선명한 얼굴보다 크게 흐린 얼굴의 위치. 비교할 얼굴이 둘 이상일 때만 판단한다.
    public static func softFaceIndices(_ faces: [FaceCloseup]) -> Set<Int> {
        let judged = faces.enumerated().compactMap { index, face in face.sharpness.map { (index, $0) } }
        guard judged.count >= 2, let sharpest = judged.map(\.1).max(), sharpest > 0 else { return [] }
        return Set(judged.filter { $0.1 < sharpest * softRatio }.map(\.0))
    }

    /// 확대 칸으로 자를 정사각형(픽셀). 얼굴 가운데에 얼굴 긴 변의 1.6배이고, 사진 가장자리에서는 사진 안으로 밀어 넣는다.
    public static func cropRect(for bounds: CGRect, imageSize: CGSize) -> CGRect {
        let face = CGRect(x: bounds.minX * imageSize.width, y: bounds.minY * imageSize.height,
                          width: bounds.width * imageSize.width, height: bounds.height * imageSize.height)
        let side = min(min(imageSize.width, imageSize.height), max(judgeableFace, max(face.width, face.height) * 1.6)).rounded()
        let x = min(max(0, face.midX - side / 2), imageSize.width - side).rounded()
        let y = min(max(0, face.midY - side / 2), imageSize.height - side).rounded()
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 두 영역이 겹치는 비율(교집합 ÷ 합집합).
    private static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        let common = shared.width * shared.height
        return common / (a.width * a.height + b.width * b.height - common)
    }

    /// Core Image 얼굴 검출기로 얼굴마다 두 눈을 감았는지. 눈을 찾지 못한 얼굴은 nil이다. 영역은 0…1(왼쪽 위 원점).
    private static func eyeStates(in image: CGImage) -> [(bounds: CGRect, closed: Bool?)] {
        guard let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        let width = Double(image.width), height = Double(image.height)
        return detector.features(in: CIImage(cgImage: image), options: [CIDetectorEyeBlink: true])
            .compactMap { $0 as? CIFaceFeature }
            .map { face in
                let bounds = CGRect(x: face.bounds.minX / width, y: 1 - face.bounds.maxY / height,
                                    width: face.bounds.width / width, height: face.bounds.height / height)
                let found = face.hasLeftEyePosition && face.hasRightEyePosition
                return (bounds, found ? face.leftEyeClosed && face.rightEyeClosed : nil)
            }
    }

    /// 얼굴 영역을 긴 변 128px 회색으로 맞춰 16px 칸마다 라플라시안 분산을 구하고, 가장 선명한 1/4 칸의 평균을 쓴다.
    /// 피부처럼 매끈한 칸보다 눈·눈썹·머리카락 칸이 초점을 잘 드러낸다.
    static func sharpness(of image: CGImage, in rect: CGRect) -> Double {
        guard let crop = image.cropping(to: rect.integral) else { return 0 }
        let scale = min(1, 128 / Double(max(crop.width, crop.height)))
        let width = max(3, Int((Double(crop.width) * scale).rounded()))
        let height = max(3, Int((Double(crop.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        let tile = 16
        let columns = max(1, (width - 2) / tile), rows = max(1, (height - 2) / tile)
        var sums = [Double](repeating: 0, count: columns * rows)
        var squares = sums, counts = sums
        for y in 1..<(height - 1) {
            let row = min(rows - 1, (y - 1) / tile)
            for x in 1..<(width - 1) {
                let index = y * width + x
                let laplacian = 4 * Double(pixels[index]) - Double(pixels[index - 1]) - Double(pixels[index + 1]) -
                    Double(pixels[index - width]) - Double(pixels[index + width])
                let cell = row * columns + min(columns - 1, (x - 1) / tile)
                sums[cell] += laplacian
                squares[cell] += laplacian * laplacian
                counts[cell] += 1
            }
        }
        let variances = zip(zip(sums, squares), counts).compactMap { pair, count -> Double? in
            guard count > 0 else { return nil }
            let mean = pair.0 / count
            return max(0, pair.1 / count - mean * mean)
        }.sorted(by: >)
        let top = variances.prefix(max(1, variances.count / 4))
        return top.isEmpty ? 0 : top.reduce(0, +) / Double(top.count)
    }
}
