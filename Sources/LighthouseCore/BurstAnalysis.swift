import CoreGraphics
import Foundation
import Vision

/// 촬영 시각이 가까운 컷 묶음. 같은 폴더·같은 이름의 RAW+JPEG 같은 파일들은 한 컷이다.
public struct BurstGroup: Identifiable, Equatable, Sendable {
    /// 촬영 순서의 컷. 각 컷은 파일 ID 목록이다.
    public var shots: [[UUID]]

    public init(shots: [[UUID]]) { self.shots = shots }

    public var id: UUID { shots[0][0] }
    public var photoIDs: [UUID] { shots.flatMap { $0 } }
}

public enum BurstGrouping {
    /// EXIF 촬영 시각은 보통 1초 단위라 1초 간격까지 같은 연속 촬영으로 본다.
    public static let defaultMaxGap: TimeInterval = 1

    /// 같은 카메라에서 앞 컷과 `maxGap`초 이내로 이어 찍은 컷이 2개 이상이면 한 묶음이다. 촬영 시각이 없으면 제외한다.
    public static func groups(for photos: [PhotoAsset], maxGap: TimeInterval = defaultMaxGap) -> [BurstGroup] {
        let dated = photos.compactMap { photo in photo.metadata.capturedAt.map { (photo: photo, date: $0) } }
        var result: [(date: Date, group: BurstGroup)] = []
        for (_, items) in Dictionary(grouping: dated, by: { $0.photo.metadata.camera ?? "" }) {
            let sorted = items.sorted {
                $0.date != $1.date ? $0.date < $1.date : $0.photo.path < $1.photo.path
            }
            var run: [(photo: PhotoAsset, date: Date)] = []
            func flush() {
                var shots: [[UUID]] = []
                var shotIndex: [String: Int] = [:]
                for item in run {
                    let key = shotKey(item.photo)
                    if let index = shotIndex[key] { shots[index].append(item.photo.id) }
                    else { shotIndex[key] = shots.count; shots.append([item.photo.id]) }
                }
                if shots.count >= 2, let first = run.first { result.append((first.date, BurstGroup(shots: shots))) }
                run = []
            }
            for item in sorted {
                if let last = run.last, item.date.timeIntervalSince(last.date) > maxGap { flush() }
                run.append(item)
            }
            flush()
        }
        return result.sorted { $0.date != $1.date ? $0.date < $1.date : $0.group.id.uuidString < $1.group.id.uuidString }
            .map(\.group)
    }

    static func shotKey(_ photo: PhotoAsset) -> String {
        photo.url.deletingPathExtension().path.lowercased()
    }
}

/// 한 장의 원본 품질 지표. 보정 전 파일을 기준으로 한다.
public struct PhotoQuality: Equatable, Sendable {
    /// 초점이 맞은 부분의 라플라시안 분산. 같은 묶음 안에서만 비교한다.
    public var sharpness: Double
    /// Vision 얼굴 촬영 품질(0…1). nil이면 얼굴 분석을 할 수 없었다. 빈 배열은 얼굴이 없다는 뜻이다.
    public var faceQualities: [Double]?

    public init(sharpness: Double, faceQualities: [Double]?) {
        self.sharpness = sharpness
        self.faceQualities = faceQualities
    }

    public var faceQuality: Double? {
        guard let faceQualities, !faceQualities.isEmpty else { return nil }
        return faceQualities.reduce(0, +) / Double(faceQualities.count)
    }
}

public enum PhotoQualityAnalyzer {
    /// 긴 변 1024px 미리보기로 분석한다. RAW는 파일 안의 카메라 미리보기를 먼저 쓴다.
    public static func analyze(url: URL, pipeline: ImagePipeline) throws -> PhotoQuality {
        let image = try pipeline.thumbnail(for: url, maxPixel: 1024)
        return PhotoQuality(sharpness: sharpness(of: image), faceQualities: faceQualities(in: image))
    }

    /// 긴 변 768px 회색으로 줄여 32px 칸마다 라플라시안 분산을 구하고, 가장 선명한 10% 칸의 평균을 쓴다.
    /// 배경이 흐린 사진도 초점 맞은 피사체로 판단한다.
    public static func sharpness(of image: CGImage) -> Double {
        let scale = min(1, 768 / Double(max(image.width, image.height)))
        let width = max(3, Int((Double(image.width) * scale).rounded()))
        let height = max(3, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        let tile = 32
        let columns = max(1, (width - 2) / tile), rows = max(1, (height - 2) / tile)
        var sums = [Double](repeating: 0, count: columns * rows)
        var squares = [Double](repeating: 0, count: columns * rows)
        var counts = [Double](repeating: 0, count: columns * rows)
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
        let top = variances.prefix(max(1, variances.count / 10))
        return top.isEmpty ? 0 : top.reduce(0, +) / Double(top.count)
    }

    /// 기기 안의 Vision으로 얼굴마다 촬영 품질(눈 감음·흔들림·표정 등)을 구한다. 실패하면 nil이다.
    public static func faceQualities(in image: CGImage) -> [Double]? {
        let request = VNDetectFaceCaptureQualityRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { return nil }
        return (request.results ?? []).compactMap { $0.faceCaptureQuality.map(Double.init) }
    }
}

public struct BurstRecommendation: Equatable, Sendable {
    /// 추천 컷의 `BurstGroup.shots` 위치.
    public var bestShot: Int
    /// 컷마다의 점수(0…1). 분석하지 못한 컷은 nil이다.
    public var scores: [Double?]
    public var usedFaces: Bool
}

public enum BurstRanking {
    /// 선명도는 묶음 안의 최고값으로 나눈 뒤 제곱근으로 0…1에 맞춘다. 라플라시안 분산은 조금만 흐려져도 크게 줄어서
    /// 그대로 쓰면 약간 더 선명한 눈 감은 컷을 고르기 때문이다. 얼굴이 찍힌 컷이 있으면 얼굴 품질을 절반 반영하고,
    /// 얼굴이 없는 컷은 얼굴 점수 0으로 본다. 동점이면 먼저 찍은 컷이다.
    public static func recommend(_ group: BurstGroup, qualities: [UUID: PhotoQuality]) -> BurstRecommendation? {
        let shotQualities = group.shots.map { shot in shot.lazy.compactMap { qualities[$0] }.first }
        let maxSharpness = shotQualities.compactMap { $0?.sharpness }.max() ?? 0
        guard shotQualities.contains(where: { $0 != nil }) else { return nil }
        let usedFaces = shotQualities.contains { $0?.faceQuality != nil }
        let scores: [Double?] = shotQualities.map { quality in
            guard let quality else { return nil }
            let sharp = maxSharpness > 0 ? (quality.sharpness / maxSharpness).squareRoot() : 0
            return usedFaces ? 0.5 * sharp + 0.5 * (quality.faceQuality ?? 0) : sharp
        }
        var best = 0
        var bestScore = -Double.infinity
        for (index, score) in scores.enumerated() {
            if let score, score > bestScore { best = index; bestScore = score }
        }
        return BurstRecommendation(bestShot: best, scores: scores, usedFaces: usedFaces)
    }
}
