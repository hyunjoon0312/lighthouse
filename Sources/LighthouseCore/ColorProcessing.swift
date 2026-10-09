import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum AdvancedColorProcessingError: LocalizedError, Equatable, Sendable {
    case invalidCurve
    case invalidColorRange(ColorBand)
    case duplicateColorRange(ColorBand)
    case invalidRGB
    case invalidGrainSettings
    case colorSpaceConversionFailed
    case colorFilterFailed
    case grainKernelFailed
    case invalidToneSettings
    case toneKernelFailed
    case invalidColorGrading

    public var errorDescription: String? {
        switch self {
        case .invalidCurve:
            "곡선 점은 0…1 범위에서 서로 다른 x 순서로 2…16개여야 합니다."
        case .invalidColorRange(let band):
            "\(band.rawValue) 색상 범위 조절값이 허용 범위를 벗어났습니다."
        case .duplicateColorRange(let band):
            "\(band.rawValue) 색상 범위가 두 번 이상 지정되었습니다."
        case .invalidRGB:
            "RGB 입력은 유한한 값이어야 합니다."
        case .invalidGrainSettings:
            "입자 양은 0…1, 크기는 0.5…8 범위의 유한한 값이어야 합니다."
        case .colorSpaceConversionFailed:
            "sRGB 색 공간으로 변환할 수 없습니다."
        case .colorFilterFailed:
            "곡선과 색상 범위 필터를 적용할 수 없습니다."
        case .grainKernelFailed:
            "필름 입자 커널을 적용할 수 없습니다."
        case .invalidToneSettings:
            "톤 조절값이 허용 범위를 벗어났습니다."
        case .toneKernelFailed:
            "추가 톤 커널을 적용할 수 없습니다."
        case .invalidColorGrading:
            "컬러 그레이딩 조절값이 허용 범위를 벗어났습니다."
        }
    }
}

public enum AdvancedColorProcessor {
    private static let cubeDimension = 64
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let cubeCache = ColorCubeCache()

    public static func curveValue(_ value: Double, points: [CurvePoint]) throws -> Double {
        guard value.isFinite else { throw AdvancedColorProcessingError.invalidCurve }
        try validateCurve(points)
        return Curve(points).value(at: min(1, max(0, value)))
    }

    public static func transformRGB(_ rgb: SIMD3<Double>, curves: ToneCurves,
                                    ranges: [ColorRangeAdjustment],
                                    grading: ColorGrading = .neutral) throws -> SIMD3<Double> {
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else {
            throw AdvancedColorProcessingError.invalidRGB
        }
        try validate(curves: curves, ranges: ranges, grading: grading)
        if isNeutral(curves: curves, ranges: ranges, grading: grading) { return rgb }
        return transformValidated(rgb, curves: curves, ranges: ranges, grading: grading)
    }

    public static func applyColor(to image: CIImage, curves: ToneCurves,
                                  ranges: [ColorRangeAdjustment],
                                  grading: ColorGrading = .neutral) throws -> CIImage {
        try validate(curves: curves, ranges: ranges, grading: grading)
        if isNeutral(curves: curves, ranges: ranges, grading: grading) { return image }

        let cubeData = cubeCache.data(curves: curves, ranges: ranges, grading: grading) {
            makeCubeData(curves: curves, ranges: ranges, grading: grading)
        }
        guard let encoded = image.matchedFromWorkingSpace(to: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        let filter = CIFilter.colorCube()
        filter.inputImage = encoded
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = cubeData
        guard let changed = filter.outputImage else {
            throw AdvancedColorProcessingError.colorFilterFailed
        }
        guard let restored = changed.matchedToWorkingSpace(from: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        return restored.cropped(to: image.extent)
    }

    public static func applyGrain(to image: CIImage, settings: GrainSettings) throws -> CIImage {
        guard settings.amount.isFinite, (0...1).contains(settings.amount),
              settings.size.isFinite, (0.5...8).contains(settings.size),
              settings.roughness.isFinite, (0...1).contains(settings.roughness) else {
            throw AdvancedColorProcessingError.invalidGrainSettings
        }
        if settings.amount == 0 { return image }
        guard let encoded = image.matchedFromWorkingSpace(to: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        guard let kernel = CoreImageKernels.grain else {
            throw AdvancedColorProcessingError.grainKernelFailed
        }
        let seedPhase = Double(settings.seed & 0xffff) * 0.001
            + Double(settings.seed >> 16) * 0.173
        guard let changed = kernel.apply(
            extent: encoded.extent,
            arguments: [encoded, Float(settings.size), Float(settings.amount), Float(seedPhase),
                        Float(settings.roughness)]
        ) else {
            throw AdvancedColorProcessingError.grainKernelFailed
        }
        guard let restored = changed.matchedToWorkingSpace(from: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        return restored.cropped(to: image.extent)
    }

    public static func applyAdditionalTone(to image: CIImage, highlights: Double, shadows: Double,
                                           whites: Double, blacks: Double) throws -> CIImage {
        guard highlights.isFinite, (0...2).contains(highlights),
              shadows.isFinite, (-1...1).contains(shadows),
              whites.isFinite, (-1...1).contains(whites),
              blacks.isFinite, (-1...1).contains(blacks) else {
            throw AdvancedColorProcessingError.invalidToneSettings
        }
        let highlight = max(highlights - 1, 0)
        let shadow = min(shadows, 0)
        guard highlight != 0 || shadow != 0 || whites != 0 || blacks != 0 else { return image }
        guard let encoded = image.matchedFromWorkingSpace(to: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        guard let kernel = CoreImageKernels.additionalTone,
              let changed = kernel.apply(
                extent: encoded.extent,
                arguments: [encoded, Float(highlight), Float(shadow), Float(whites), Float(blacks)]
              ) else {
            throw AdvancedColorProcessingError.toneKernelFailed
        }
        guard let restored = changed.matchedToWorkingSpace(from: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        return restored.cropped(to: image.extent)
    }

    private static func validate(curves: ToneCurves, ranges: [ColorRangeAdjustment],
                                 grading: ColorGrading) throws {
        do {
            try curves.validate()
        } catch {
            throw AdvancedColorProcessingError.invalidCurve
        }
        var bands: [ColorBand] = []
        for range in ranges {
            guard range.hue.isFinite, (-30...30).contains(range.hue),
                  range.saturation.isFinite, (-1...1).contains(range.saturation),
                  range.lightness.isFinite, (-1...1).contains(range.lightness) else {
                throw AdvancedColorProcessingError.invalidColorRange(range.band)
            }
            guard !bands.contains(range.band) else {
                throw AdvancedColorProcessingError.duplicateColorRange(range.band)
            }
            bands.append(range.band)
        }
        guard grading.isValid else { throw AdvancedColorProcessingError.invalidColorGrading }
    }

    private static func validateCurve(_ points: [CurvePoint]) throws {
        guard (2...16).contains(points.count), points.first?.x == 0, points.last?.x == 1 else {
            throw AdvancedColorProcessingError.invalidCurve
        }
        var previousX = -Double.infinity
        for point in points {
            guard point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y),
                  point.x > previousX else {
                throw AdvancedColorProcessingError.invalidCurve
            }
            previousX = point.x
        }
    }

    private static func isNeutral(curves: ToneCurves, ranges: [ColorRangeAdjustment],
                                  grading: ColorGrading) -> Bool {
        curves.isIdentity && grading.isNeutral && ranges.allSatisfy {
            $0.hue == 0 && $0.saturation == 0 && $0.lightness == 0
        }
    }

    private static func makeCubeData(curves: ToneCurves, ranges: [ColorRangeAdjustment],
                                     grading: ColorGrading) -> Data {
        let dimension = cubeDimension
        let maximum = Double(dimension - 1)
        // 곡선 결과는 각 채널의 격자 위치에만 달려 있으므로 채널마다 64칸만 계산해 둔다.
        let master = Curve(curves.master)
        let tables = [curves.red, curves.green, curves.blue].map { points in
            let curve = Curve(points)
            return (0..<dimension).map { curve.value(at: master.value(at: Double($0) / maximum)) }
        }
        let plan = GradingPlan(grading)
        var values = [Float](repeating: 1, count: dimension * dimension * dimension * 4)
        values.withUnsafeMutableBufferPointer { buffer in
            // 파란 칸마다 서로 다른 구간만 쓰므로 여러 스레드가 같은 위치를 쓰지 않는다.
            nonisolated(unsafe) let output = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: dimension) { blue in
                for green in 0..<dimension {
                    for red in 0..<dimension {
                        let transformed = applyingGrading(plan, to: applyingRanges(
                            ranges, to: SIMD3(tables[0][red], tables[1][green], tables[2][blue])
                        ))
                        let index = ((blue * dimension + green) * dimension + red) * 4
                        output[index] = Float(transformed.x)
                        output[index + 1] = Float(transformed.y)
                        output[index + 2] = Float(transformed.z)
                    }
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    private static func transformValidated(_ rgb: SIMD3<Double>, curves: ToneCurves,
                                           ranges: [ColorRangeAdjustment],
                                           grading: ColorGrading) -> SIMD3<Double> {
        let master = Curve(curves.master)
        let curved = SIMD3(
            Curve(curves.red).value(at: master.value(at: min(1, max(0, rgb.x)))),
            Curve(curves.green).value(at: master.value(at: min(1, max(0, rgb.y)))),
            Curve(curves.blue).value(at: master.value(at: min(1, max(0, rgb.z))))
        )
        return applyingGrading(GradingPlan(grading), to: applyingRanges(ranges, to: curved))
    }

    private static func applyingRanges(_ ranges: [ColorRangeAdjustment],
                                       to curved: SIMD3<Double>) -> SIMD3<Double> {
        guard !ranges.isEmpty else { return curved }

        let original = rgbToHSL(curved)
        let achromaticWeight = min(1, original.saturation / 0.15)
        var hueShift = 0.0
        var saturationShift = 0.0
        var lightnessShift = 0.0
        for adjustment in ranges {
            let distance = shortestHueDistance(original.hue, adjustment.band.centerHue)
            guard distance <= 45 else { continue }
            let bandWeight = 0.5 * (1 + cos(.pi * distance / 45))
            let weight = bandWeight * achromaticWeight
            hueShift += adjustment.hue * weight * original.saturation
            saturationShift += adjustment.saturation * weight
            lightnessShift += adjustment.lightness * weight
        }
        let adjusted = HSL(
            hue: wrappedHue(original.hue + hueShift),
            saturation: min(1, max(0, original.saturation + saturationShift)),
            lightness: min(1, max(0, original.lightness + lightnessShift * 0.5))
        )
        return hslToRGB(adjusted)
    }

    /// 밝기로 영역 가중치를 정한 뒤 명도는 세 채널에 같이 더하고, 밝기 0인 색 방향은 0…1을 벗어나지 않는 만큼만 더한다.
    /// 그래서 틴트는 밝기를 바꾸지 않고 순수한 검정·흰색은 그대로 남는다.
    private static func applyingGrading(_ plan: GradingPlan?, to rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard let plan else { return rgb }
        let luma = min(1, max(0, luminance(rgb)))
        let weights = plan.weights(luma)
        var tint = SIMD3<Double>(repeating: 0)
        for (zone, weight) in zip(plan.tints, weights) where weight > 0 {
            tint += weight * zone
        }
        let base = (rgb + SIMD3(repeating: plan.lift(at: luma))).clamped(lowerBound: SIMD3(repeating: 0),
                                                                        upperBound: SIMD3(repeating: 1))
        var scale = 1.0
        for channel in 0..<3 where tint[channel] != 0 {
            let room = tint[channel] < 0 ? base[channel] / -tint[channel] : (1 - base[channel]) / tint[channel]
            scale = min(scale, room)
        }
        return base + max(0, scale) * tint
    }

    /// 그레이딩마다 한 번 계산하는 값. 큐브의 모든 칸이 같은 영역 색과 명도 이동표를 쓴다.
    private struct GradingPlan {
        private static let liftSamples = 1024
        private let exponent: Double
        private let edge: Double
        /// 그림자·중간톤·하이라이트·전체 순서의 `채도 × 0.3 × 밝기 0인 색 방향`.
        let tints: [SIMD3<Double>]
        private let lifts: [Double]

        init?(_ grading: ColorGrading) {
            guard !grading.isNeutral else { return nil }
            let zones = [grading.shadows, grading.midtones, grading.highlights, grading.global]
            exponent = pow(2, -grading.balance)
            edge = 0.05 + 0.45 * grading.blending
            tints = zones.map { zone in
                guard zone.saturation > 0 else { return SIMD3(repeating: 0) }
                let color = hslToRGB(HSL(hue: zone.hue, saturation: 1, lightness: 0.5))
                return zone.saturation * 0.3 * (color - SIMD3(repeating: luminance(color)))
            }
            // 명도 이동 뒤 밝기 L + ΔY(L)를 표로 만들고 누적 최대로 단조화한다.
            // 혼합이 낮으면 영역 가중치가 가팔라져 밝은 입력이 더 어두워지는 계조 반전이 생길 수 있다.
            let (exponent, edge) = (exponent, edge)
            var highest = 0.0
            lifts = (0...Self.liftSamples).map { index in
                let luma = Double(index) / Double(Self.liftSamples)
                let weights = Self.weights(luma, exponent: exponent, edge: edge)
                let shift = zip(zones, weights).reduce(0.0) { $0 + $1.1 * $1.0.luminance * 0.5 * luma * (1 - luma) }
                highest = max(highest, luma + shift)
                return highest - luma
            }
        }

        func weights(_ luma: Double) -> [Double] {
            Self.weights(luma, exponent: exponent, edge: edge)
        }

        /// 표 사이는 선형 보간한다. 단조 표의 선형 보간이므로 결과 밝기도 단조다.
        func lift(at luma: Double) -> Double {
            let position = luma * Double(Self.liftSamples)
            let index = min(Self.liftSamples - 1, max(0, Int(position)))
            let fraction = min(1, max(0, position - Double(index)))
            return lifts[index] * (1 - fraction) + lifts[index + 1] * fraction
        }

        private static func weights(_ luma: Double, exponent: Double, edge: Double) -> [Double] {
            let position = pow(luma, exponent)
            let shadows = 1 - smoothstep(max(0, 1.0 / 3 - edge), 1.0 / 3 + edge, position)
            let highlights = smoothstep(2.0 / 3 - edge, min(1, 2.0 / 3 + edge), position)
            return [shadows, max(0, 1 - shadows - highlights), highlights, 1]
        }
    }

    private static func luminance(_ rgb: SIMD3<Double>) -> Double {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value < edge1 ? 0 : 1 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// 단조 Hermite 곡선. 점마다의 기울기를 한 번만 계산해 두고 값을 여러 번 읽는다.
    private struct Curve {
        let points: [CurvePoint]
        let tangents: [Double]

        init(_ points: [CurvePoint]) {
            self.points = points
            let slopes = (0..<(points.count - 1)).map {
                (points[$0 + 1].y - points[$0].y) / (points[$0 + 1].x - points[$0].x)
            }
            tangents = (0..<points.count).map { index in
                if index == 0 { return slopes[0] }
                if index == slopes.count { return slopes[slopes.count - 1] }
                let before = slopes[index - 1]
                let after = slopes[index]
                guard before != 0, after != 0, before.sign == after.sign else { return 0 }
                return 2 * before * after / (before + after)
            }
        }

        func value(at value: Double) -> Double {
            if value <= points[0].x { return points[0].y }
            if value >= points[points.count - 1].x { return points[points.count - 1].y }

            var segment = 0
            while segment + 1 < points.count && value > points[segment + 1].x {
                segment += 1
            }
            let left = points[segment]
            let right = points[segment + 1]
            let width = right.x - left.x
            let t = (value - left.x) / width
            let t2 = t * t
            let t3 = t2 * t
            let value = (2 * t3 - 3 * t2 + 1) * left.y
                + (t3 - 2 * t2 + t) * width * tangents[segment]
                + (-2 * t3 + 3 * t2) * right.y
                + (t3 - t2) * width * tangents[segment + 1]
            return min(max(left.y, right.y), max(min(left.y, right.y), value))
        }
    }

    private struct HSL {
        var hue: Double
        var saturation: Double
        var lightness: Double
    }

    private static func rgbToHSL(_ rgb: SIMD3<Double>) -> HSL {
        let maximum = max(rgb.x, max(rgb.y, rgb.z))
        let minimum = min(rgb.x, min(rgb.y, rgb.z))
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0 else { return HSL(hue: 0, saturation: 0, lightness: lightness) }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        let sector: Double
        if maximum == rgb.x {
            sector = ((rgb.y - rgb.z) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == rgb.y {
            sector = (rgb.z - rgb.x) / delta + 2
        } else {
            sector = (rgb.x - rgb.y) / delta + 4
        }
        return HSL(hue: wrappedHue(sector * 60), saturation: saturation, lightness: lightness)
    }

    private static func hslToRGB(_ hsl: HSL) -> SIMD3<Double> {
        let chroma = (1 - abs(2 * hsl.lightness - 1)) * hsl.saturation
        let sector = hsl.hue / 60
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base: SIMD3<Double>
        switch sector {
        case 0..<1: base = SIMD3(chroma, secondary, 0)
        case 1..<2: base = SIMD3(secondary, chroma, 0)
        case 2..<3: base = SIMD3(0, chroma, secondary)
        case 3..<4: base = SIMD3(0, secondary, chroma)
        case 4..<5: base = SIMD3(secondary, 0, chroma)
        default: base = SIMD3(chroma, 0, secondary)
        }
        let match = hsl.lightness - chroma / 2
        return SIMD3(base.x + match, base.y + match, base.z + match)
    }

    private static func wrappedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func shortestHueDistance(_ first: Double, _ second: Double) -> Double {
        let direct = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(direct, 360 - direct)
    }
}

private final class ColorCubeCache: @unchecked Sendable {
    private struct Entry {
        let curves: ToneCurves
        let ranges: [ColorRangeAdjustment]
        let grading: ColorGrading
        let data: Data
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func data(curves: ToneCurves, ranges: [ColorRangeAdjustment], grading: ColorGrading,
              create: () -> Data) -> Data {
        func matches(_ entry: Entry) -> Bool {
            entry.curves == curves && entry.ranges == ranges && entry.grading == grading
        }
        lock.lock()
        if let index = entries.firstIndex(where: matches) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.data
        }
        lock.unlock()

        let result = create()
        lock.lock()
        if let index = entries.firstIndex(where: matches) {
            let existing = entries.remove(at: index)
            entries.append(existing)
            lock.unlock()
            return existing.data
        }
        entries.append(Entry(curves: curves, ranges: ranges, grading: grading, data: result))
        if entries.count > 4 { entries.removeFirst(entries.count - 4) }
        lock.unlock()
        return result
    }
}
