import CoreGraphics
import CoreImage
import Foundation

public extension ImagePipeline {
    func analyzeFlicker(url: URL) throws -> FlickerAnalysis {
        let rendered = try render(url: url, edits: .neutral, maxPixel: 768)
        let image = CIImage(cgImage: rendered, options: [.colorSpace: colorSpace])
        let width = rendered.width
        let height = rendered.height
        let rowBytes = width * 4 * MemoryLayout<Float>.size
        var pixels = Data(count: rowBytes * height)
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: rowBytes, bounds: image.extent,
                           format: .RGBAf, colorSpace: linear)
        }

        let horizontal = try Self.analyzeBands(pixels: pixels, width: width, height: height,
                                               rowBytes: rowBytes, direction: .horizontal)
        let vertical = try Self.analyzeBands(pixels: pixels, width: width, height: height,
                                             rowBytes: rowBytes, direction: .vertical)
        let best = horizontal.score >= vertical.score ? horizontal : vertical
        guard best.confidence >= 0.4, best.referenceAmplitudeEV >= 0.01 else {
            throw ImagePipelineError.flickerFailed("신뢰할 수 있는 반복 밴딩 패턴을 찾지 못했습니다.")
        }
        let profile = FlickerProfile(redCoefficients: best.coefficients[0],
                                     greenCoefficients: best.coefficients[1],
                                     blueCoefficients: best.coefficients[2],
                                     referenceAmplitudeEV: best.referenceAmplitudeEV)
        let settings = FlickerSettings(isEnabled: true, amount: 0.7, direction: best.direction,
                                       cycles: best.cycles, phase: 0,
                                       amplitudeEV: min(2, best.referenceAmplitudeEV),
                                       colorAmount: best.colorAmount, profile: profile)
        let directionName = best.direction == .horizontal ? "가로" : "세로"
        return FlickerAnalysis(settings: settings, confidence: best.confidence,
                               message: "\(directionName) 밴딩 약 \(String(format: "%.1f", best.cycles))회")
    }
}

extension ImagePipeline {
    func applyFlicker(_ settings: FlickerSettings, to image: CIImage) throws -> CIImage {
        guard settings.isEnabled else { return image }
        guard settings.isValid else {
            throw ImagePipelineError.flickerFailed("설정 값이 유한한 허용 범위를 벗어났습니다.")
        }
        guard settings.amount > 0 else { return image }
        guard image.extent.width.isFinite, image.extent.height.isFinite,
              image.extent.width > 0, image.extent.height > 0,
              let kernel = CoreImageKernels.flickerCorrection else {
            throw ImagePipelineError.flickerFailed("보정 커널을 준비하지 못했습니다.")
        }

        var channels: [[Double]]
        if let profile = settings.profile {
            let scale = settings.amplitudeEV / profile.referenceAmplitudeEV
            channels = [profile.redCoefficients, profile.greenCoefficients, profile.blueCoefficients]
                .map { $0.map { $0 * scale } }
        } else {
            channels = Array(repeating: [settings.amplitudeEV, 0, 0, 0, 0, 0], count: 3)
        }
        func vectors(_ values: [Double]) -> [CIVector] {
            [CIVector(x: values[0], y: values[1], z: values[2], w: values[3]),
             CIVector(x: values[4], y: values[5], z: 0, w: 0)]
        }
        let red = vectors(channels[0]), green = vectors(channels[1]), blue = vectors(channels[2])
        let extent = image.extent
        let arguments: [Any] = [
            image, settings.direction == .horizontal ? Float(0) : Float(1), Float(settings.cycles),
            Float(settings.phase), Float(settings.amount), Float(settings.colorAmount),
            Float(extent.minX), Float(extent.minY), Float(extent.width), Float(extent.height),
            red[0], red[1], green[0], green[1], blue[0], blue[1],
        ]
        guard let output = kernel.apply(extent: extent, arguments: arguments) else {
            throw ImagePipelineError.flickerFailed("보정 커널 실행에 실패했습니다.")
        }
        return output.cropped(to: extent)
    }

    private struct BandAnalysis {
        let direction: BandDirection
        let cycles: Double
        let coefficients: [[Double]]
        let referenceAmplitudeEV: Double
        let colorAmount: Double
        let score: Double
        let confidence: Double
    }

    private static func analyzeBands(pixels: Data, width: Int, height: Int, rowBytes: Int,
                                     direction: BandDirection) throws -> BandAnalysis {
        let length = direction == .horizontal ? height : width
        let crossLength = direction == .horizontal ? width : height
        guard length >= 16, crossLength >= 4 else {
            throw ImagePipelineError.flickerFailed("플리커 분석 이미지가 너무 작습니다.")
        }
        var stripProfiles = Array(repeating: Array(repeating: Double.nan, count: length), count: 4)
        var channelProfile = Array(repeating: Array(repeating: Double.nan, count: length), count: 3)

        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for position in 0..<length {
                var stripValues = Array(repeating: [Double](), count: 4)
                var channelValues = Array(repeating: [Double](), count: 3)
                for cross in 0..<crossLength {
                    let x = direction == .horizontal ? cross : position
                    let y = direction == .horizontal ? position : cross
                    let pixel = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                    let offset = x * 4
                    let alpha = Double(pixel[offset + 3])
                    let rgb = (0..<3).map { Double(pixel[offset + $0]) / max(alpha, 0.000_001) }
                    guard alpha >= 0.05, rgb.allSatisfy({ $0.isFinite && $0 > 0.002 && $0 < 0.995 }) else { continue }
                    let ev = rgb.map { log2(max($0, 0.002)) }
                    let luma = 0.2126 * ev[0] + 0.7152 * ev[1] + 0.0722 * ev[2]
                    let strip = min(3, cross * 4 / crossLength)
                    stripValues[strip].append(luma)
                    for channel in 0..<3 { channelValues[channel].append(ev[channel]) }
                }
                for strip in 0..<4 {
                    if let mean = trimmedMean(stripValues[strip]) { stripProfiles[strip][position] = mean }
                }
                for channel in 0..<3 {
                    if let mean = trimmedMean(channelValues[channel]) { channelProfile[channel][position] = mean }
                }
            }
        }
        stripProfiles = stripProfiles.map(detrended)
        channelProfile = channelProfile.map(detrended)
        guard stripProfiles.allSatisfy({ $0.filter(\.isFinite).count >= length / 3 }) else {
            throw ImagePipelineError.flickerFailed("플리커 분석에 사용할 유효 픽셀이 부족합니다.")
        }

        let upperCycle = max(2, min(64, length / 4))
        var bestCycles = 2.0
        var bestScore = -Double.infinity
        for cycle in 2...upperCycle {
            let score = spectralScore(profiles: stripProfiles, cycles: Double(cycle))
            if score > bestScore { bestScore = score; bestCycles = Double(cycle) }
        }
        let integerCenter = bestCycles
        for step in -9...9 {
            let candidate = integerCenter + Double(step) / 10
            guard candidate >= 2, candidate <= Double(upperCycle) else { continue }
            let score = spectralScore(profiles: stripProfiles, cycles: candidate)
            if score > bestScore { bestScore = score; bestCycles = candidate }
        }
        let coefficients = channelProfile.map { jointlyFittedHarmonics(profile: $0, cycles: bestCycles) }
        let predictedRanges = coefficients.map { coefficients -> Double in
            let values = (0..<512).map { index -> Double in
                let angle = 2 * Double.pi * bestCycles * Double(index) / 512
                return (1...3).reduce(0) { partial, harmonic in
                    partial + coefficients[(harmonic - 1) * 2] * sin(Double(harmonic) * angle)
                        + coefficients[(harmonic - 1) * 2 + 1] * cos(Double(harmonic) * angle)
                }
            }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        let reference = min(2, max(0.000_001, predictedRanges.max() ?? 0))
        let lumaCoefficients = (0..<6).map {
            0.2126 * coefficients[0][$0] + 0.7152 * coefficients[1][$0] + 0.0722 * coefficients[2][$0]
        }
        let colorEnergy = zip(coefficients.flatMap { $0 }, Array(repeating: lumaCoefficients, count: 3).flatMap { $0 })
            .reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        let totalEnergy = coefficients.flatMap { $0 }.reduce(0) { $0 + $1 * $1 }
        let colorAmount = min(1, sqrt(colorEnergy / max(totalEnergy, 0.000_001)))
        let confidence = min(1, max(0, bestScore))
        return BandAnalysis(direction: direction, cycles: bestCycles, coefficients: coefficients,
                            referenceAmplitudeEV: reference, colorAmount: colorAmount,
                            score: bestScore, confidence: confidence)
    }

    private static func detrended(_ values: [Double]) -> [Double] {
        let valid = values.indices.filter { values[$0].isFinite }
        guard valid.count >= 2 else { return values }
        let meanX = valid.reduce(0.0) { $0 + Double($1) } / Double(valid.count)
        let meanY = valid.reduce(0.0) { $0 + values[$1] } / Double(valid.count)
        let denominator = valid.reduce(0.0) { $0 + pow(Double($1) - meanX, 2) }
        let slope = denominator > 0 ? valid.reduce(0.0) {
            $0 + (Double($1) - meanX) * (values[$1] - meanY)
        } / denominator : 0
        return values.indices.map { index in
            values[index].isFinite ? values[index] - meanY - slope * (Double(index) - meanX) : .nan
        }
    }

    private static func spectralScore(profiles: [[Double]], cycles: Double) -> Double {
        let pairs = profiles.map { firstHarmonic(profile: $0, cycles: cycles) }
        let amplitudes = pairs.map { hypot($0.0, $0.1) }
        let meanAmplitude = amplitudes.reduce(0, +) / Double(amplitudes.count)
        guard meanAmplitude > 0 else { return 0 }
        let meanSin = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let meanCos = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        let coherence = hypot(meanSin, meanCos) / meanAmplitude
        let variances = profiles.map { profile in
            let finite = profile.filter(\.isFinite)
            return finite.reduce(0) { $0 + $1 * $1 } / Double(max(1, finite.count))
        }
        let explained = amplitudes.enumerated().map {
            min(1, $0.element * $0.element / max(variances[$0.offset] * 2, 0.000_001))
        }
        let amplitudeConsistency = (amplitudes.min() ?? 0) / max(amplitudes.max() ?? 0, 0.000_001)
        let weakestEnergy = explained.min() ?? 0
        // 네 독립 strip 모두에 비슷한 진폭·위상이 있어야 한다. 한 영역의 줄무늬 패치는 여기서 탈락한다.
        return min(1, max(0, coherence * sqrt(weakestEnergy) * sqrt(amplitudeConsistency)))
    }

    private static func firstHarmonic(profile: [Double], cycles: Double) -> (Double, Double) {
        let coefficients = harmonicCoefficients(profile: profile, cycles: cycles)
        return (coefficients[0], coefficients[1])
    }

    private static func harmonicCoefficients(profile: [Double], cycles: Double) -> [Double] {
        var output: [Double] = []
        for harmonic in 1...3 {
            var sinNumerator = 0.0, cosNumerator = 0.0, sinDenominator = 0.0, cosDenominator = 0.0
            for index in profile.indices where profile[index].isFinite {
                let angle = 2 * Double.pi * cycles * Double(index) / Double(profile.count)
                    * Double(harmonic)
                let sine = sin(angle), cosine = cos(angle)
                sinNumerator += profile[index] * sine
                cosNumerator += profile[index] * cosine
                sinDenominator += sine * sine
                cosDenominator += cosine * cosine
            }
            output.append(sinNumerator / max(sinDenominator, 0.000_001))
            output.append(cosNumerator / max(cosDenominator, 0.000_001))
        }
        return output.map { min(2, max(-2, $0)) }
    }

    /// 상수·선형 경향과 세 harmonic의 sin/cos를 한 번에 적합한다. 부분 피벗으로 작은 축을 건너뛴다.
    private static func jointlyFittedHarmonics(profile: [Double], cycles: Double) -> [Double] {
        let columnCount = 8
        var normal = Array(repeating: Array(repeating: 0.0, count: columnCount + 1), count: columnCount)
        let denominator = Double(max(1, profile.count - 1))
        for index in profile.indices where profile[index].isFinite {
            let position = Double(index) / denominator
            let angle = 2 * Double.pi * cycles * Double(index) / Double(profile.count)
            let row = [1, position,
                       sin(angle), cos(angle), sin(2 * angle), cos(2 * angle),
                       sin(3 * angle), cos(3 * angle)]
            for i in 0..<columnCount {
                for j in i..<columnCount { normal[i][j] += row[i] * row[j] }
                normal[i][columnCount] += row[i] * profile[index]
            }
        }
        for i in 0..<columnCount {
            for j in 0..<i { normal[i][j] = normal[j][i] }
        }
        guard let solution = solvePivoted(normal) else { return Array(repeating: 0, count: 6) }
        return Array(solution[2...7]).map { min(2, max(-2, $0)) }
    }

    private static func solvePivoted(_ augmented: [[Double]]) -> [Double]? {
        var matrix = augmented
        let count = matrix.count
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(matrix[$0][column]) < abs(matrix[$1][column])
            }), abs(matrix[pivot][column]) > 1e-10 else { return nil }
            if pivot != column { matrix.swapAt(pivot, column) }
            let divisor = matrix[column][column]
            for value in column...count { matrix[column][value] /= divisor }
            for row in 0..<count where row != column {
                let factor = matrix[row][column]
                guard factor != 0 else { continue }
                for value in column...count { matrix[row][value] -= factor * matrix[column][value] }
            }
        }
        let result = matrix.map { $0[count] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }

    private static func trimmedMean(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let trim = sorted.count >= 10 ? sorted.count / 10 : 0
        let kept = sorted[trim..<(sorted.count - trim)]
        return kept.reduce(0, +) / Double(kept.count)
    }
}
