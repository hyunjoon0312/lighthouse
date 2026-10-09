import CoreGraphics
import Foundation

/// 자동 보정 출발점. 사진을 작게 그려 화이트밸런스(색온도·틴트), 노출, 하이라이트·섀도만 정하고
/// 나머지 보정(구도·곡선·LUT·부분 보정 등)은 그대로 둔다. 결과는 사진에 따라 달라 손으로 다듬는 것을 전제로 한다.
public enum AutoAdjust {
    public static let measurePixels = 192
    /// 색 보정은 한쪽으로 치우친 장면(노을·실내 조명)을 지나치게 되돌리지 않게 이 범위로 제한한다.
    public static let temperatureLimit = 1500.0
    public static let tintLimit = 40.0

    public struct Result: Equatable, Sendable {
        public var edits: EditSettings
        /// 측정에 그린 횟수. 진단용.
        public var renders: Int
    }

    /// 매번 실제로 현상해 잰다. 편집 미리보기의 빠른 근사는 S9에서 색이 실제보다 1.5–2배 움직여 쓰지 않는다.
    /// 색 변화는 색온도·틴트에 거의 비례해 할선법으로 축마다 2–3번이면 찾는다(S9 RAW 약 9번 현상).
    public static func suggest(url: URL, current: EditSettings, pipeline: ImagePipeline) throws -> Result {
        var measurement = Measurement(url: url, current: current, pipeline: pipeline)
        // 처음 모습에서 기준 픽셀을 한 번 고른다.
        let start = try measurement.measure()
        try measurement.neutralize(from: start, temperatureLimit: temperatureLimit, tintLimit: tintLimit)
        let probe = measurement.probe

        let stats = try measurement.measure()
        // 어두운 장면은 평균 밝기(로그 평균)를 18% 회색(sRGB 약 0.46)에 맞추되, 밝은 장면은 흰 피사체를
        // 중간 회색으로 내리지 않는다. 넓은 밝은 영역(p95)에 필요한 여유만 확보한다.
        let key = min(2, max(-2, log2(0.18 / max(0.002, stats.logAverage))))
        let headroom = log2(0.95 / max(0.002, stats.percentile(0.995)))
        let brightHeadroom = min(0, log2(0.90 / max(0.002, stats.percentile(0.95))))
        let exposure = key > 0 ? min(key, max(0, headroom)) : max(key, brightHeadroom)
        let gain = pow(2, exposure)
        let clipped = stats.fraction { $0 * gain >= 0.98 }
        let crushed = stats.fraction { $0 * gain < 0.012 }

        var result = current
        result.temperatureShift = (probe.temperatureShift * 10).rounded() / 10
        result.tintShift = (probe.tintShift * 10).rounded() / 10
        result.exposure = (exposure * 100).rounded() / 100
        result.highlights = clipped > 0.02 ? 0.6 : clipped > 0.005 ? 0.8 : 1
        result.shadows = crushed > 0.10 ? 0.3 : crushed > 0.03 ? 0.15 : 0
        return Result(edits: result, renders: measurement.renders)
    }

    /// 누른 곳이 회색이 되도록 색온도·틴트만 정한다(흰색 기준 찍기). `point`는 구도를 적용한 사진의 0…1 좌표이며
    /// y는 위쪽이 0이다. 누른 곳 주변 작은 영역을 기준으로 삼고, 사람이 고른 곳이라 자동 보정보다 넓게(슬라이더 끝까지) 움직인다.
    public static func whiteBalance(url: URL, current: EditSettings, at point: CGPoint,
                                    pipeline: ImagePipeline) throws -> Result {
        var measurement = Measurement(url: url, current: current, pipeline: pipeline)
        let first = try measurement.render()
        measurement.reference = patch(around: point, width: first.width, height: first.height)
        let start = Stats(first, neutralIndices: measurement.reference)
        try measurement.neutralize(from: start, temperatureLimit: 2500, tintLimit: 100)
        var result = current
        result.temperatureShift = (measurement.probe.temperatureShift * 10).rounded() / 10
        result.tintShift = (measurement.probe.tintShift * 10).rounded() / 10
        return Result(edits: result, renders: measurement.renders)
    }

    /// 누른 곳을 가운데로 한 사각형(짧은 변의 약 3%) 안의 픽셀 위치.
    static func patch(around point: CGPoint, width: Int, height: Int) -> [Int] {
        let radius = max(1, Int((Double(min(width, height)) * 0.015).rounded()))
        let centerX = min(width - 1, max(0, Int(point.x * Double(width))))
        let centerY = min(height - 1, max(0, Int(point.y * Double(height))))
        var indices: [Int] = []
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) { indices.append(y * width + x) }
        }
        return indices
    }

    /// 구도만 남긴 상태로 작게 그려 잰다. 크롭한 부분만 보고, 이미 적용한 톤·색 보정에 끌려가지 않는다.
    struct Measurement {
        let url: URL
        let pipeline: ImagePipeline
        var probe: EditSettings
        var reference: [Int]?
        var renders = 0

        init(url: URL, current: EditSettings, pipeline: ImagePipeline) {
            self.url = url
            self.pipeline = pipeline
            probe = EditSettings.neutral.merging(from: current, components: .geometry)
            probe.rawDevelop = current.rawDevelop
        }

        mutating func render() throws -> CGImage {
            renders += 1
            return try pipeline.renderPreview(url: url, edits: probe, maxPixel: measurePixels).image
        }

        /// 처음 잴 때 고른 기준 픽셀을 다음 측정에도 쓴다.
        mutating func measure() throws -> Stats {
            let stats = Stats(try render(), neutralIndices: reference)
            reference = stats.neutralIndices
            return stats
        }

        /// 기준 픽셀의 색이 회색이 되도록 색온도, 이어서 틴트를 찾는다.
        mutating func neutralize(from start: Stats, temperatureLimit: Double, tintLimit: Double) throws {
            func blueCast(_ stats: Stats) -> Double { stats.gray.b - stats.gray.r }
            func greenCast(_ stats: Stats) -> Double { stats.gray.g - (stats.gray.r + stats.gray.b) / 2 }
            // 색온도를 올리면 따뜻해져(파랑↓ 빨강↑) 회색 부분의 파랑−빨강 차이가 줄어든다. 차이가 0이 되는 곳을 찾는다.
            probe.temperatureShift = try AutoAdjust.solve(from: blueCast(start), step: 400, limit: temperatureLimit) { value in
                probe.temperatureShift = value
                return blueCast(try measure())
            }
            // 틴트를 올리면 마젠타로 가(초록↓) 초록−(빨강·파랑 평균) 차이가 줄어든다.
            let warmed = try measure()
            probe.tintShift = try AutoAdjust.solve(from: greenCast(warmed), step: 10, limit: tintLimit) { value in
                probe.tintShift = value
                return greenCast(try measure())
            }
        }
    }

    /// `function(0) = start`에서 시작해 `function`이 0이 되는 값을 할선법으로 찾는다. 값이 커질수록 `function`이
    /// 줄어든다고 보고 첫걸음(`step`)의 방향을 정한다. `-limit…limit` 밖으로는 나가지 않으며 `function`은 최대 3번 부른다.
    static func solve(from start: Double, step: Double, limit: Double,
                      _ function: (Double) throws -> Double) throws -> Double {
        guard start != 0 else { return 0 }
        var (x0, y0) = (0.0, start)
        var x1 = start > 0 ? step : -step
        var y1 = try function(x1)
        for _ in 0..<2 {
            guard y1 != y0, y1 != 0 else { break }
            let next = min(limit, max(-limit, x1 - y1 * (x1 - x0) / (y1 - y0)))
            guard abs(next - x1) > step * 0.05 else { return next }
            (x0, y0, x1) = (x1, y1, next)
            y1 = try function(x1)
        }
        return x1
    }

    /// 작게 그린 사진의 밝기 분포와 기준 픽셀의 평균색(선형).
    struct Stats {
        let luminance: [Double]
        let gray: (r: Double, g: Double, b: Double)
        /// 회색에 가까운 기준 픽셀의 위치. 색온도·틴트를 바꿔 가며 잴 때 같은 픽셀을 비교하도록 처음 것을 넘긴다.
        let neutralIndices: [Int]

        init(_ image: CGImage, neutralIndices fixed: [Int]? = nil) {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let count = width * height
            var red = [Double](repeating: 0, count: count), green = red, blue = red, luminance = red
            for pixel in 0..<count {
                red[pixel] = Self.linear(bytes[pixel * 4])
                green[pixel] = Self.linear(bytes[pixel * 4 + 1])
                blue[pixel] = Self.linear(bytes[pixel * 4 + 2])
                luminance[pixel] = 0.2126 * red[pixel] + 0.7152 * green[pixel] + 0.0722 * blue[pixel]
            }
            let indices: [Int]
            if let fixed, fixed.allSatisfy({ $0 < count }) {
                indices = fixed
            } else {
                // 너무 어둡거나 한 채널이라도 잘린 곳은 색이 믿을 만하지 않아 뺀다. 채도가 낮은 쪽 30%(회색에 가까운 부분)
                // 가운데 밝은 절반을 쓴다. 색이 강한 피사체에 끌려가지 않고, 주 조명을 받는 흰 면을 기준으로 한다.
                let candidates = (0..<count).filter { luminance[$0] > 0.02 && max(red[$0], green[$0], blue[$0]) < 0.95 }
                func chroma(_ i: Int) -> Double {
                    let high = max(red[i], green[i], blue[i])
                    return (high - min(red[i], green[i], blue[i])) / high
                }
                let grayish = candidates.sorted { chroma($0) < chroma($1) }.prefix(max(1, candidates.count * 3 / 10))
                indices = Array(grayish.sorted { luminance[$0] > luminance[$1] }.prefix(max(1, grayish.count / 2)))
            }
            let total = Double(max(1, indices.count))
            gray = (indices.reduce(0) { $0 + red[$1] } / total, indices.reduce(0) { $0 + green[$1] } / total,
                    indices.reduce(0) { $0 + blue[$1] } / total)
            neutralIndices = indices
            self.luminance = luminance.sorted()
        }

        var medianLinear: Double { percentile(0.5) }

        /// 로그 평균(기하 평균). 아주 어두운 점이 지나치게 끌어내리지 않게 0.001을 더한다.
        var logAverage: Double {
            guard !luminance.isEmpty else { return 0.18 }
            return exp(luminance.reduce(0) { $0 + log($1 + 0.001) } / Double(luminance.count))
        }

        func percentile(_ fraction: Double) -> Double {
            guard !luminance.isEmpty else { return 0.18 }
            return luminance[min(luminance.count - 1, Int(Double(luminance.count) * fraction))]
        }

        func fraction(_ predicate: (Double) -> Bool) -> Double {
            luminance.isEmpty ? 0 : Double(luminance.filter(predicate).count) / Double(luminance.count)
        }

        static func linear(_ value: UInt8) -> Double {
            let v = Double(value) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
    }
}
