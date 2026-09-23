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
        return evaluateCurve(min(1, max(0, value)), points: points)
    }

    public static func transformRGB(_ rgb: SIMD3<Double>, curves: ToneCurves,
                                    ranges: [ColorRangeAdjustment]) throws -> SIMD3<Double> {
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else {
            throw AdvancedColorProcessingError.invalidRGB
        }
        try validate(curves: curves, ranges: ranges)
        if isNeutral(curves: curves, ranges: ranges) { return rgb }
        return transformValidated(rgb, curves: curves, ranges: ranges)
    }

    public static func applyColor(to image: CIImage, curves: ToneCurves,
                                  ranges: [ColorRangeAdjustment]) throws -> CIImage {
        try validate(curves: curves, ranges: ranges)
        if isNeutral(curves: curves, ranges: ranges) { return image }

        let cubeData = cubeCache.data(curves: curves, ranges: ranges) {
            makeCubeData(curves: curves, ranges: ranges)
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
              settings.size.isFinite, (0.5...8).contains(settings.size) else {
            throw AdvancedColorProcessingError.invalidGrainSettings
        }
        if settings.amount == 0 { return image }
        guard let encoded = image.matchedFromWorkingSpace(to: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        guard let kernel = GrainKernel.shared.kernel else {
            throw AdvancedColorProcessingError.grainKernelFailed
        }
        let seedPhase = Double(settings.seed & 0xffff) * 0.001
            + Double(settings.seed >> 16) * 0.173
        guard let changed = kernel.apply(
            extent: encoded.extent,
            arguments: [encoded, Float(settings.size), Float(settings.amount), Float(seedPhase)]
        ) else {
            throw AdvancedColorProcessingError.grainKernelFailed
        }
        guard let restored = changed.matchedToWorkingSpace(from: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        return restored.cropped(to: image.extent)
    }

    private static func validate(curves: ToneCurves,
                                 ranges: [ColorRangeAdjustment]) throws {
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

    private static func isNeutral(curves: ToneCurves,
                                  ranges: [ColorRangeAdjustment]) -> Bool {
        curves.isIdentity && ranges.allSatisfy {
            $0.hue == 0 && $0.saturation == 0 && $0.lightness == 0
        }
    }

    private static func makeCubeData(curves: ToneCurves,
                                     ranges: [ColorRangeAdjustment]) -> Data {
        let maximum = Double(cubeDimension - 1)
        var values = [Float]()
        values.reserveCapacity(cubeDimension * cubeDimension * cubeDimension * 4)
        for blue in 0..<cubeDimension {
            for green in 0..<cubeDimension {
                for red in 0..<cubeDimension {
                    let transformed = transformValidated(
                        SIMD3(Double(red) / maximum, Double(green) / maximum, Double(blue) / maximum),
                        curves: curves,
                        ranges: ranges
                    )
                    values.append(Float(transformed.x))
                    values.append(Float(transformed.y))
                    values.append(Float(transformed.z))
                    values.append(1)
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    private static func transformValidated(_ rgb: SIMD3<Double>, curves: ToneCurves,
                                           ranges: [ColorRangeAdjustment]) -> SIMD3<Double> {
        let clamped = SIMD3(
            min(1, max(0, rgb.x)),
            min(1, max(0, rgb.y)),
            min(1, max(0, rgb.z))
        )
        let mastered = SIMD3(
            evaluateCurve(clamped.x, points: curves.master),
            evaluateCurve(clamped.y, points: curves.master),
            evaluateCurve(clamped.z, points: curves.master)
        )
        let curved = SIMD3(
            evaluateCurve(mastered.x, points: curves.red),
            evaluateCurve(mastered.y, points: curves.green),
            evaluateCurve(mastered.z, points: curves.blue)
        )
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

    private static func evaluateCurve(_ value: Double, points: [CurvePoint]) -> Double {
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
        let slopes = (0..<(points.count - 1)).map {
            (points[$0 + 1].y - points[$0].y) / (points[$0 + 1].x - points[$0].x)
        }
        let leftTangent = tangent(at: segment, slopes: slopes)
        let rightTangent = tangent(at: segment + 1, slopes: slopes)
        let t2 = t * t
        let t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * left.y
            + (t3 - 2 * t2 + t) * width * leftTangent
            + (-2 * t3 + 3 * t2) * right.y
            + (t3 - t2) * width * rightTangent
        return min(max(left.y, right.y), max(min(left.y, right.y), value))
    }

    private static func tangent(at index: Int, slopes: [Double]) -> Double {
        if index == 0 { return slopes[0] }
        if index == slopes.count { return slopes[slopes.count - 1] }
        let before = slopes[index - 1]
        let after = slopes[index]
        guard before != 0, after != 0, before.sign == after.sign else { return 0 }
        return 2 * before * after / (before + after)
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
        let data: Data
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func data(curves: ToneCurves, ranges: [ColorRangeAdjustment],
              create: () -> Data) -> Data {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.curves == curves && $0.ranges == ranges }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.data
        }
        lock.unlock()

        let result = create()
        lock.lock()
        if let index = entries.firstIndex(where: { $0.curves == curves && $0.ranges == ranges }) {
            let existing = entries.remove(at: index)
            entries.append(existing)
            lock.unlock()
            return existing.data
        }
        entries.append(Entry(curves: curves, ranges: ranges, data: result))
        if entries.count > 4 { entries.removeFirst(entries.count - 4) }
        lock.unlock()
        return result
    }
}

private final class GrainKernel: @unchecked Sendable {
    static let shared = GrainKernel()

    let kernel: CIColorKernel?

    private init() {
        kernel = CIColorKernel(source: """
        kernel vec4 lighthouseGrain(__sample pixel, float grainSize, float amount, float seed) {
            vec2 position = destCoord() / grainSize;
            vec2 cell = floor(position);
            vec2 blend = fract(position);
            blend = blend * blend * (3.0 - 2.0 * blend);
            float n00 = fract(sin(dot(cell, vec2(12.9898, 78.233)) + seed) * 43758.5453);
            float n10 = fract(sin(dot(cell + vec2(1.0, 0.0), vec2(12.9898, 78.233)) + seed) * 43758.5453);
            float n01 = fract(sin(dot(cell + vec2(0.0, 1.0), vec2(12.9898, 78.233)) + seed) * 43758.5453);
            float n11 = fract(sin(dot(cell + vec2(1.0, 1.0), vec2(12.9898, 78.233)) + seed) * 43758.5453);
            float noise = mix(mix(n00, n10, blend.x), mix(n01, n11, blend.x), blend.y);
            vec3 changed = clamp(pixel.rgb + (noise - 0.5) * amount * 0.22, 0.0, 1.0);
            return vec4(changed, pixel.a);
        }
        """)
    }
}
