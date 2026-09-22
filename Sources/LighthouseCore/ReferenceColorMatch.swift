import CoreGraphics
import Foundation

public enum ReferenceColorMatchError: LocalizedError {
    case invalidSamples
    case noVisiblePixels
    case bitmapFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSamples: "색감 분석에 사용할 RGB 표본이 올바르지 않습니다."
        case .noVisiblePixels: "색감 분석에 사용할 불투명한 이미지 영역이 없습니다."
        case .bitmapFailed: "색감 분석용 이미지를 만들 수 없습니다."
        }
    }
}

public struct ColorMatchTransform: Sendable {
    private let sourceMean: SIMD3<Double>
    private let targetMean: SIMD3<Double>
    private let ratio: SIMD3<Double>

    public init(source: [SIMD3<Double>], reference: [SIMD3<Double>]) throws {
        guard Self.valid(source), Self.valid(reference) else { throw ReferenceColorMatchError.invalidSamples }
        let sourceStats = Self.statistics(source.map(Self.rgbToLab))
        let referenceStats = Self.statistics(reference.map(Self.rgbToLab))
        sourceMean = sourceStats.mean
        let difference = referenceStats.mean - sourceStats.mean
        targetMean = sourceStats.mean + SIMD3<Double>(
            min(30, max(-30, difference.x)),
            min(25, max(-25, difference.y)),
            min(25, max(-25, difference.z))
        )
        let sourceDeviation = sourceStats.deviation
        let referenceDeviation = referenceStats.deviation
        ratio = SIMD3<Double>(
            sourceDeviation.x < 0.001 ? 1 : min(2, max(0.5, referenceDeviation.x / sourceDeviation.x)),
            sourceDeviation.y < 0.001 ? 1 : min(2, max(0.5, referenceDeviation.y / sourceDeviation.y)),
            sourceDeviation.z < 0.001 ? 1 : min(2, max(0.5, referenceDeviation.z / sourceDeviation.z))
        )
    }

    public func map(_ rgb: SIMD3<Double>, strength: Double = 1) -> SIMD3<Double> {
        let amount = strength.isFinite ? min(1, max(0, strength)) : 0
        if amount == 0 { return rgb }
        let safe = SIMD3<Double>(Self.clamp(rgb.x), Self.clamp(rgb.y), Self.clamp(rgb.z))
        let lab = Self.rgbToLab(safe)
        let transferred = (lab - sourceMean) * ratio + targetMean
        let converted = Self.labToRGB(transferred)
        return safe + (converted - safe) * amount
    }

    public func cubeData(title: String, strength: Double = 1) -> Data {
        let safeTitle = String(title.unicodeScalars.filter {
            $0 != "\"" && !CharacterSet.controlCharacters.contains($0) &&
                !CharacterSet.newlines.contains($0)
        })
        let displayedTitle = safeTitle.isEmpty ? "Lighthouse Reference Match" : safeTitle
        var lines = ["TITLE \"\(displayedTitle)\"", "#LUMIXPHOTOSTYLE STD",
                     "# Lighthouse reference color match · Standard base · full range",
                     "LUT_3D_SIZE 33", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
        lines.reserveCapacity(33 * 33 * 33 + 6)
        let locale = Locale(identifier: "en_US_POSIX")
        for blue in 0..<33 {
            for green in 0..<33 {
                for red in 0..<33 {
                    let mapped = map(SIMD3<Double>(Double(red) / 32, Double(green) / 32,
                                                   Double(blue) / 32), strength: strength)
                    lines.append(String(format: "%.8f %.8f %.8f", locale: locale,
                                        mapped.x, mapped.y, mapped.z))
                }
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func valid(_ samples: [SIMD3<Double>]) -> Bool {
        !samples.isEmpty && samples.allSatisfy { rgb in
            [rgb.x, rgb.y, rgb.z].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
    }

    private static func statistics(_ values: [SIMD3<Double>]) -> (mean: SIMD3<Double>, deviation: SIMD3<Double>) {
        var mean = SIMD3<Double>(repeating: 0)
        var m2 = SIMD3<Double>(repeating: 0)
        for (index, value) in values.enumerated() {
            let count = Double(index + 1)
            let delta = value - mean
            mean += delta / count
            m2 += delta * (value - mean)
        }
        let variance = m2 / Double(values.count)
        return (mean, SIMD3<Double>(sqrt(max(0, variance.x)), sqrt(max(0, variance.y)),
                                    sqrt(max(0, variance.z))))
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func inverseSRGB(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func forwardSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func rgbToLab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let r = inverseSRGB(rgb.x), g = inverseSRGB(rgb.y), b = inverseSRGB(rgb.z)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let fx = labFunction(x), fy = labFunction(y), fz = labFunction(z)
        return SIMD3<Double>(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func labToRGB(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let fy = (lab.x + 16) / 116
        let fx = fy + lab.y / 500
        let fz = fy - lab.z / 200
        let x = inverseLabFunction(fx) * 0.95047
        let y = inverseLabFunction(fy)
        let z = inverseLabFunction(fz) * 1.08883
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return SIMD3<Double>(clamp(forwardSRGB(r)), clamp(forwardSRGB(g)), clamp(forwardSRGB(b)))
    }

    private static func labFunction(_ value: Double) -> Double {
        let delta = 6.0 / 29
        return value > delta * delta * delta ? pow(value, 1.0 / 3) : value / (3 * delta * delta) + 4.0 / 29
    }

    private static func inverseLabFunction(_ value: Double) -> Double {
        let delta = 6.0 / 29
        return value > delta ? value * value * value : 3 * delta * delta * (value - 4.0 / 29)
    }
}

public struct ReferenceMatchResult: @unchecked Sendable {
    public let transform: ColorMatchTransform
    public let sourcePreview: CGImage
    public let referencePreview: CGImage

    public init(transform: ColorMatchTransform, sourcePreview: CGImage, referencePreview: CGImage) {
        self.transform = transform
        self.sourcePreview = sourcePreview
        self.referencePreview = referencePreview
    }
}

public final class ReferenceColorMatcher: @unchecked Sendable {
    private let pipeline: ImagePipeline
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(lutDirectory: URL = LUTStore.defaultDirectory) {
        pipeline = ImagePipeline(lutDirectory: lutDirectory)
    }

    public func analyze(source: PhotoAsset, referenceURL: URL) throws -> ReferenceMatchResult {
        var edits = source.edits
        edits.lut = nil
        let sourceImage = try pipeline.render(url: source.url, edits: edits, maxPixel: 800)
        let referenceImage = try pipeline.render(url: referenceURL, edits: .neutral, maxPixel: 800)
        let sourceSamples = try samples(from: sourceImage)
        let referenceSamples = try samples(from: referenceImage)
        let transform = try ColorMatchTransform(source: sourceSamples, reference: referenceSamples)
        return ReferenceMatchResult(transform: transform, sourcePreview: sourceImage,
                                    referencePreview: referenceImage)
    }

    public func preview(result: ReferenceMatchResult, strength: Double) throws -> CGImage {
        let image = result.sourcePreview
        guard image.width > 0, image.height > 0, max(image.width, image.height) <= 800 else {
            throw ReferenceColorMatchError.bitmapFailed
        }
        var pixels = try bitmap(from: image, width: image.width, height: image.height)
        let byteCount = pixels.count
        pixels.withUnsafeMutableBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in stride(from: 0, to: byteCount, by: 4) {
                let alpha = Double(bytes[index + 3]) / 255
                if alpha <= 0 { continue }
                let original = SIMD3<Double>(Double(bytes[index]) / 255 / alpha,
                                             Double(bytes[index + 1]) / 255 / alpha,
                                             Double(bytes[index + 2]) / 255 / alpha)
                let mapped = result.transform.map(original, strength: strength)
                bytes[index] = UInt8((min(1, max(0, mapped.x)) * alpha * 255).rounded())
                bytes[index + 1] = UInt8((min(1, max(0, mapped.y)) * alpha * 255).rounded())
                bytes[index + 2] = UInt8((min(1, max(0, mapped.z)) * alpha * 255).rounded())
            }
        }
        return try makeImage(pixels: pixels, width: image.width, height: image.height)
    }

    private func samples(from image: CGImage) throws -> [SIMD3<Double>] {
        guard image.width > 0, image.height > 0 else { throw ReferenceColorMatchError.bitmapFailed }
        let scale = min(1, 256.0 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let pixels = try bitmap(from: image, width: width, height: height)
        var samples: [SIMD3<Double>] = []
        samples.reserveCapacity(width * height)
        pixels.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Double(bytes[index + 3]) / 255
                if alpha < 0.05 { continue }
                samples.append(SIMD3<Double>(
                    min(1, Double(bytes[index]) / 255 / alpha),
                    min(1, Double(bytes[index + 1]) / 255 / alpha),
                    min(1, Double(bytes[index + 2]) / 255 / alpha)
                ))
            }
        }
        guard !samples.isEmpty else { throw ReferenceColorMatchError.noVisiblePixels }
        return samples
    }

    private func bitmap(from image: CGImage, width: Int, height: Int) throws -> Data {
        var data = Data(count: width * height * 4)
        let success = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw ReferenceColorMatchError.bitmapFailed }
        return data
    }

    private func makeImage(pixels: Data, width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                      CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw ReferenceColorMatchError.bitmapFailed }
        return image
    }
}
