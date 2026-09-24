import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

public enum ImagePipelineError: LocalizedError {
    case unreadable(URL)
    case renderFailed(URL)
    case invalidDirectory(URL)
    case exportFailed(URL)
    case invalidMaskGeometry
    case invalidMaskData(String)
    case subjectNotFound
    case subjectMaskFailed(String)
    case invalidJPEGQuality
    case invalidJPEGData
    case lutFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "이미지를 읽을 수 없습니다: \(url.lastPathComponent)"
        case .renderFailed(let url): "이미지를 현상할 수 없습니다: \(url.lastPathComponent)"
        case .invalidDirectory(let url): "내보내기 폴더를 사용할 수 없습니다: \(url.path)"
        case .exportFailed(let url): "JPEG 파일을 저장할 수 없습니다: \(url.path)"
        case .invalidMaskGeometry: "영역 마스크의 이미지 크기가 올바르지 않습니다."
        case .invalidMaskData(let reason): "저장된 영역 마스크가 올바르지 않습니다: \(reason)"
        case .subjectNotFound: "자동으로 선택할 피사체를 찾지 못했습니다."
        case .subjectMaskFailed(let reason): "자동 피사체 마스크를 만들 수 없습니다: \(reason)"
        case .invalidJPEGQuality: "JPEG 품질은 유한한 값이어야 합니다."
        case .invalidJPEGData: "JPEG 데이터가 올바르지 않습니다."
        case .lutFailed(let reason): "LUT를 적용할 수 없습니다: \(reason)"
        }
    }
}

public final class ImagePipeline: @unchecked Sendable {
    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "rw2", "dng", "arw",
        "nef", "cr2", "cr3", "orf", "raf", "pef"
    ]
    private static let rawExtensions: Set<String> = ["rw2", "dng", "arw", "nef", "cr2", "cr3", "orf", "raf", "pef"]
    public static func isRAW(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
    public static var supportedCameraModels: [String] { CIRAWFilter.supportedCameraModels }

    static let maximumMaskBytes = 8 * 1_024 * 1_024
    private static let clarityKernel = CIColorKernel(source: """
        kernel vec4 clarity(__sample image, __sample fine, __sample coarse, float amount) {
            float luma = dot(image.rgb, vec3(0.2126, 0.7152, 0.0722));
            float tone = pow(clamp(luma, 0.0, 1.0), 0.4545);
            float midtones = clamp(4.0 * tone * (1.0 - tone), 0.0, 1.0);
            return vec4(image.rgb + amount * midtones * (fine.rgb - coarse.rgb), image.a);
        }
        """)

    let context: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lutStore: LUTStore
    private let cachesDevelopment: Bool
    private let developmentLock = NSLock()
    private var developedSources: [DevelopedSource] = []

    private struct DevelopedSource {
        let key: String
        /// 같은 파일·RAW 현상 설정이면 같다. 노출·색온도·틴트만 다른 결과를 근사에 쓸 수 있다.
        let base: String
        let exposure: Double
        let temperature: Double
        let tint: Double
        /// 이 결과를 현상할 때 쓴 RAW 중립 색온도(K).
        let neutralTemperature: Double?
        let image: CIImage
    }

    /// 근사 미리보기에서 RAW 현상 대신 덧씌운 노출·색온도·틴트 차이.
    private struct DevelopmentDelta {
        let exposure: Double
        let temperature: Double
        let tint: Double
        let neutralTemperature: Double?
    }
    private let maskLock = NSLock()
    private var cachedMasks: [(definition: LocalMaskDefinition, width: Int, height: Int, image: CIImage)] = []

    /// `cachesDevelopment`는 편집 미리보기용이다. 최근 현상 결과(최대 2장)와 중간 계산을 재사용해
    /// RAW 현상 값(노출·색온도·틴트)이 같은 동안 다른 슬라이더를 다시 현상하지 않고 그린다.
    public init(lutDirectory: URL = LUTStore.defaultDirectory, cachesDevelopment: Bool = false) {
        context = CIContext(options: [.cacheIntermediates: cachesDevelopment])
        lutStore = LUTStore(directory: lutDirectory)
        self.cachesDevelopment = cachesDevelopment
    }

    public func metadata(for url: URL) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw ImagePipelineError.unreadable(url)
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let rawWidth = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let rawHeight = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let rotated = [5, 6, 7, 8].contains(orientation)
        let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let make = tiff[kCGImagePropertyTIFFMake as String] as? String
        let model = tiff[kCGImagePropertyTIFFModel as String] as? String
        return PhotoMetadata(
            width: rotated ? rawHeight : rawWidth, height: rotated ? rawWidth : rawHeight,
            camera: [make, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
            lens: exif[kCGImagePropertyExifLensModel as String] as? String,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue,
            aperture: (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue,
            shutter: (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
            capturedAt: dateString.flatMap { formatter.date(from: $0) }.map { date in
                // 1초 미만 촬영 시각("107" → 0.107초)이 있으면 더해 같은 초의 연속 촬영 순서를 지킨다.
                let digits = (exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy(\.isASCII),
                      digits.allSatisfy(\.isNumber), let fraction = Double("0." + digits) else { return date }
                return date.addingTimeInterval(fraction)
            }
        )
    }

    public func rawCapabilities(for url: URL) -> RAWCapabilities? {
        guard Self.isRAW(url), let raw = CIRAWFilter(imageURL: url) else { return nil }
        return RAWCapabilities(
            luminanceNoiseReduction: raw.isLuminanceNoiseReductionSupported
                ? Double(raw.luminanceNoiseReductionAmount) : nil,
            colorNoiseReduction: raw.isColorNoiseReductionSupported ? Double(raw.colorNoiseReductionAmount) : nil,
            lensCorrection: raw.isLensCorrectionSupported ? raw.isLensCorrectionEnabled : nil,
            highlightRecovery: Self.highlightRecovery(of: raw)
        )
    }

    private static func highlightRecovery(of raw: CIRAWFilter) -> Bool? {
        guard #available(macOS 26.0, *), raw.isHighlightRecoverySupported else { return nil }
        return raw.isHighlightRecoveryEnabled
    }

    public func thumbnail(for url: URL, maxPixel: Int = 360) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImagePipelineError.unreadable(url)
        }
        let size = max(1, maxPixel)
        func thumbnail(fromImageAlways: Bool) -> CGImage? {
            let mode = fromImageAlways ? kCGImageSourceCreateThumbnailFromImageAlways
                : kCGImageSourceCreateThumbnailFromImageIfAbsent
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                mode: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
            ] as CFDictionary)
        }
        // RAW 파일에 든 큰 JPEG 미리보기를 쓰면 센서 데이터 전체를 디코딩하지 않는다.
        if let embedded = thumbnail(fromImageAlways: false),
           Self.embeddedThumbnail(embedded, isUsableFor: source, maxPixel: size) {
            return embedded
        }
        guard let image = thumbnail(fromImageAlways: true) else { throw ImagePipelineError.unreadable(url) }
        return image
    }

    /// RAW 파일에 든 카메라 미리보기만 읽는다. RAW가 아니거나 미리보기가 1024px보다 작거나 비율이 다르면 nil이다.
    public func embeddedPreview(for url: URL, maxPixel: Int) -> CGImage? {
        guard Self.isRAW(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
              ] as CFDictionary),
              Self.embeddedThumbnail(image, isUsableFor: source, maxPixel: min(maxPixel, 1024)) else { return nil }
        return image
    }

    private static func embeddedThumbnail(_ image: CGImage, isUsableFor source: CGImageSource,
                                          maxPixel: Int) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0, image.width > 0, image.height > 0 else { return false }
        let neededSide = min(maxPixel, max(width, height))
        guard max(image.width, image.height) >= neededSide - 1 else { return false }
        let sourceRatio = Double(min(width, height)) / Double(max(width, height))
        let imageRatio = Double(min(image.width, image.height)) / Double(max(image.width, image.height))
        return abs(sourceRatio - imageRatio) <= 0.02
    }

    public func render(url: URL, edits: EditSettings, maxPixel: Int? = 2200) throws -> CGImage {
        try render(url: url, edits: edits, maxPixel: maxPixel, allowApproximation: false).image
    }

    /// 편집 미리보기용. `allowApproximation`이면 RAW 노출·색온도·틴트만 바뀐 경우 최근 현상 결과에 차이를 덧씌워
    /// RAW를 다시 현상하지 않고 그린다(슬라이더를 끄는 동안). 근사 결과인지 함께 돌려주므로 끝난 뒤 정확히 다시 그린다.
    public func renderPreview(url: URL, edits: EditSettings, maxPixel: Int?,
                              allowApproximation: Bool) throws -> (image: CGImage, isApproximate: Bool) {
        try render(url: url, edits: edits, maxPixel: maxPixel, allowApproximation: allowApproximation)
    }

    private func render(url: URL, edits: EditSettings, maxPixel: Int?,
                        allowApproximation: Bool) throws -> (image: CGImage, isApproximate: Bool) {
        let development = try developed(url: url, edits: edits, allowApproximation: allowApproximation)
        var image = development.image
        image = try RetouchProcessor.apply(to: image, strokes: edits.retouchStrokes,
                                           context: context, colorSpace: colorSpace)
        image = try AdvancedColorProcessor.applyColor(to: image, curves: edits.curves,
                                                      ranges: edits.colorRanges)
        let maskScale = Self.maskScale(sourceWidth: image.extent.width, sourceHeight: image.extent.height,
                                       edits: edits, maxPixel: maxPixel)
        for adjustment in edits.localAdjustments where adjustment.isEnabled && adjustment.hasMask {
            if let baseMask = adjustment.baseMask { _ = try decodedMask(baseMask) }
            guard [adjustment.exposure, adjustment.contrast, adjustment.temperature, adjustment.saturation,
                   adjustment.clarity].allSatisfy(\.isFinite), adjustment.hasEffect else { continue }
            let mask = try fittedMask(for: adjustment, extent: image.extent, scale: maskScale)
            var adjusted = image
            if adjustment.exposure != 0 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = adjusted
                filter.ev = Float(adjustment.exposure)
                adjusted = filter.outputImage ?? adjusted
            }
            if adjustment.temperature != 0 {
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = adjusted
                filter.neutral = CIVector(x: 6500, y: 0)
                // 목표 기준색이 낮을수록 따뜻해진다. +가 RAW 색온도처럼 따뜻한 쪽이다.
                filter.targetNeutral = CIVector(x: 6500 - min(1, max(-1, adjustment.temperature)) * 2000, y: 0)
                adjusted = filter.outputImage ?? adjusted
            }
            if adjustment.contrast != 1 || adjustment.saturation != 0 {
                let filter = CIFilter.colorControls()
                filter.inputImage = adjusted
                filter.contrast = Float(adjustment.contrast)
                filter.saturation = Float(1 + min(1, max(-1, adjustment.saturation)))
                adjusted = filter.outputImage ?? adjusted
            }
            adjusted = applyClarity(adjustment.clarity, to: adjusted)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = image
            blend.maskImage = mask
            image = (blend.outputImage ?? image).cropped(to: image.extent)
        }
        if let lut = edits.lut, lut.isEnabled {
            guard lut.intensity.isFinite else { throw ImagePipelineError.lutFailed("강도가 유한한 값이 아닙니다") }
            if lut.intensity > 0 {
                image = try applyLUT(lut, to: image)
            }
        }
        image = try AdvancedColorProcessor.applyGrain(to: image, settings: edits.grain)
        image = transformedForDisplay(image, edits: edits, maxPixel: maxPixel)
        image = applyVignette(edits.vignette, to: image)
        let rect = CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height))
        guard rect.width > 0, rect.height > 0,
              let result = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
            throw ImagePipelineError.renderFailed(url)
        }
        return (result, development.isApproximate)
    }

    /// 새 스팟 복구의 패치 위치를 한 번 찾는다. 결과를 stroke에 저장하면 렌더마다 다시 찾지 않는다.
    public func healingSourceOffset(url: URL, edits: EditSettings, stroke: RetouchStroke) throws -> MaskPoint {
        let base = try developed(url: url, edits: edits, allowApproximation: false).image
        let retouched = try RetouchProcessor.apply(to: base, strokes: edits.retouchStrokes,
                                                   context: context, colorSpace: colorSpace)
        return try RetouchProcessor.healingSourceOffset(for: stroke, in: retouched,
                                                        context: context, colorSpace: colorSpace)
    }

    /// 원본 짧은 변의 0.15%~1.5% 크기 대비(중간 주파수)를 중간 톤 위주로 더하거나 빼서 잔 디테일은 남긴다.
    /// 반경을 원본 크기에 맞추므로 미리보기와 내보내기가 같다.
    private func applyClarity(_ amount: Double, to image: CIImage) -> CIImage {
        guard amount != 0, amount.isFinite, let kernel = Self.clarityKernel else { return image }
        let shortSide = min(image.extent.width, image.extent.height)
        let small = CIFilter.gaussianBlur()
        small.inputImage = image.clampedToExtent()
        small.radius = Float(shortSide * 0.0015)
        let large = CIFilter.gaussianBlur()
        large.inputImage = image.clampedToExtent()
        large.radius = Float(shortSide * 0.015)
        guard let fine = small.outputImage, let coarse = large.outputImage,
              let output = kernel.apply(extent: image.extent,
                                        arguments: [image, fine, coarse, Float(min(1, max(-1, amount)) * 0.5)]) else {
            return image
        }
        return output
    }

    private func developedSource(url: URL, edits: EditSettings,
                                 allowApproximation: Bool) throws -> (image: CIImage, delta: DevelopmentDelta?) {
        guard cachesDevelopment else { return (try makeDevelopedSource(url: url, edits: edits).image, nil) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        var base = "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        var key = base
        if Self.isRAW(url) {
            base += "|\(edits.rawDevelop)"
            key = base + "|\(edits.exposure)|\(edits.temperatureShift)|\(edits.tintShift)"
        }
        developmentLock.lock()
        if let index = developedSources.firstIndex(where: { $0.key == key }) {
            let hit = developedSources.remove(at: index)
            developedSources.append(hit)
            developmentLock.unlock()
            return (hit.image, nil)
        }
        if allowApproximation, Self.isRAW(url), let near = developedSources.last(where: { $0.base == base }) {
            developmentLock.unlock()
            return (near.image, DevelopmentDelta(exposure: edits.exposure - near.exposure,
                                                 temperature: edits.temperatureShift - near.temperature,
                                                 tint: edits.tintShift - near.tint,
                                                 neutralTemperature: near.neutralTemperature))
        }
        developmentLock.unlock()
        let (image, neutralTemperature) = try makeDevelopedSource(url: url, edits: edits)
        developmentLock.lock()
        developedSources.removeAll { $0.key == key }
        developedSources.append(DevelopedSource(key: key, base: base, exposure: edits.exposure,
                                                temperature: edits.temperatureShift, tint: edits.tintShift,
                                                neutralTemperature: neutralTemperature, image: image))
        let evicted = developedSources.count > 2
        if evicted { developedSources.removeFirst(developedSources.count - 2) }
        developmentLock.unlock()
        if evicted { context.clearCaches() }
        return (image, nil)
    }

    private func makeDevelopedSource(url: URL, edits: EditSettings) throws -> (image: CIImage, neutralTemperature: Double?) {
        if Self.isRAW(url) {
            guard let raw = CIRAWFilter(imageURL: url) else { throw ImagePipelineError.unreadable(url) }
            let originalExposure = raw.exposure
            let originalTemperature = raw.neutralTemperature
            let originalTint = raw.neutralTint
            raw.exposure = originalExposure + Float(edits.exposure)
            raw.neutralTemperature = min(50_000, max(2_000, originalTemperature + Float(edits.temperatureShift)))
            raw.neutralTint = min(150, max(-150, originalTint + Float(edits.tintShift)))
            let develop = edits.rawDevelop
            if raw.isLuminanceNoiseReductionSupported, let amount = develop.luminanceNoiseReduction, amount.isFinite {
                raw.luminanceNoiseReductionAmount = Float(min(1, max(0, amount)))
            }
            if raw.isColorNoiseReductionSupported, let amount = develop.colorNoiseReduction, amount.isFinite {
                raw.colorNoiseReductionAmount = Float(min(1, max(0, amount)))
            }
            if raw.isLensCorrectionSupported, let enabled = develop.lensCorrection {
                raw.isLensCorrectionEnabled = enabled
            }
            if #available(macOS 26.0, *), raw.isHighlightRecoverySupported, let enabled = develop.highlightRecovery {
                raw.isHighlightRecoveryEnabled = enabled
            }
            guard let output = raw.outputImage else { throw ImagePipelineError.renderFailed(url) }
            return (output, Double(raw.neutralTemperature))
        }
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImagePipelineError.unreadable(url)
        }
        return (source, nil)
    }

    private func developed(url: URL, edits: EditSettings,
                           allowApproximation: Bool) throws -> (image: CIImage, isApproximate: Bool) {
        let source = try developedSource(url: url, edits: edits, allowApproximation: allowApproximation)
        var image = source.image
        if let delta = source.delta {
            image = Self.approximated(image, by: delta)
        }
        if !Self.isRAW(url) {
            if edits.exposure != 0 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = image
                filter.ev = Float(edits.exposure)
                image = filter.outputImage ?? image
            }
            if edits.temperatureShift != 0 || edits.tintShift != 0 {
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = image
                filter.neutral = CIVector(x: 6500, y: 0)
                // RAW의 neutralTemperature/neutralTint 이동과 같은 방향(+는 따뜻하게·마젠타)이 되도록 목표를 반대로 옮긴다.
                filter.targetNeutral = CIVector(x: 6500 - edits.temperatureShift, y: -edits.tintShift)
                image = filter.outputImage ?? image
            }
        }

        if edits.contrast != 1 || edits.saturation != 1 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = Float(edits.contrast)
            filter.saturation = Float(edits.saturation)
            image = filter.outputImage ?? image
        }
        if edits.highlights != 1 || edits.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(edits.highlights)
            filter.shadowAmount = Float(edits.shadows)
            image = filter.outputImage ?? image
        }
        if edits.vibrance != 0, edits.vibrance.isFinite {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(min(1, max(-1, edits.vibrance)))
            image = filter.outputImage ?? image
        }
        image = applyClarity(edits.clarity, to: image)
        if edits.sharpness != 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(edits.sharpness)
            image = filter.outputImage ?? image
        }
        return (image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
                source.delta != nil)
    }

    /// RAW 현상 결과에 노출·색온도·틴트 차이를 덧씌운 근사. 색온도는 켈빈이 아니라 미레드(1/K) 차이로 옮긴다.
    /// RAW 중립 색온도를 T에서 T+Δ로 바꾸는 것과 같은 미레드만큼 6500K 기준 필터를 움직인다.
    private static func approximated(_ image: CIImage, by delta: DevelopmentDelta) -> CIImage {
        var result = image
        if delta.exposure != 0, delta.exposure.isFinite {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = Float(delta.exposure)
            result = filter.outputImage ?? result
        }
        if (delta.temperature != 0 || delta.tint != 0), delta.temperature.isFinite, delta.tint.isFinite {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = CIVector(x: 6500, y: 0)
            var target = 6500.0
            if let used = delta.neutralTemperature, used > 0, delta.temperature != 0 {
                let moved = min(50_000, max(2_000, used + delta.temperature))
                let mired = 1_000_000 / used - 1_000_000 / moved
                target = 1_000_000 / max(20, 1_000_000 / 6500 + mired * approximateMiredGain)
            }
            filter.targetNeutral = CIVector(x: target, y: -delta.tint * approximateTintGain)
            result = filter.outputImage ?? result
        }
        return result
    }

    /// S9 표본에서 RAW 현상은 같은 미레드·틴트 변화의 일반 필터보다 색이 약 1.35배·1.4배 더 움직였다.
    static let approximateMiredGain = 1.35
    static let approximateTintGain = 1.4

    private func applyLUT(_ adjustment: LUTAdjustment, to image: CIImage) throws -> CIImage {
        let cube = try lutStore.load(id: adjustment.id)
        guard let encoded = image.matchedFromWorkingSpace(to: colorSpace) else {
            throw ImagePipelineError.lutFailed("sRGB 입력 변환 실패")
        }
        let scale = SIMD3<Float>(repeating: 1) / (cube.domainMax - cube.domainMin)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = encoded
        matrix.rVector = CIVector(x: CGFloat(scale.x), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(scale.y), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(scale.z), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: CGFloat(-cube.domainMin.x * scale.x),
                                     y: CGFloat(-cube.domainMin.y * scale.y),
                                     z: CGFloat(-cube.domainMin.z * scale.z), w: 0)
        guard let normalized = matrix.outputImage else { throw ImagePipelineError.lutFailed("입력 범위 변환 실패") }
        let filter = CIFilter.colorCube()
        filter.inputImage = normalized
        filter.cubeDimension = Float(cube.dimension)
        filter.cubeData = cube.cubeData
        guard let changed = filter.outputImage else { throw ImagePipelineError.lutFailed("3D 색상 변환 실패") }
        guard let restoredImage = changed.matchedToWorkingSpace(from: colorSpace) else {
            throw ImagePipelineError.lutFailed("작업 색공간 복귀 실패")
        }
        let restored = restoredImage.cropped(to: image.extent)
        let strength = min(1, max(0, adjustment.intensity))
        if strength == 1 { return restored }
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = image
        blend.targetImage = restored
        blend.time = Float(strength)
        guard let mixed = blend.outputImage else { throw ImagePipelineError.lutFailed("강도 합성 실패") }
        return mixed.cropped(to: image.extent)
    }

    public func renderMask(adjustment: LocalAdjustment, sourceWidth: Int, sourceHeight: Int,
                           edits: EditSettings, maxPixel: Int = 1600) throws -> CGImage {
        guard sourceWidth > 0, sourceHeight > 0 else { throw ImagePipelineError.invalidMaskGeometry }
        let scale = Self.maskScale(sourceWidth: CGFloat(sourceWidth), sourceHeight: CGFloat(sourceHeight),
                                   edits: edits, maxPixel: maxPixel)
        let mask = try cachedMask(for: adjustment, width: sourceWidth, height: sourceHeight, scale: scale)
        let output = transformedForDisplay(mask, edits: edits, maxPixel: maxPixel)
        let rect = CGRect(x: 0, y: 0, width: floor(output.extent.width), height: floor(output.extent.height))
        let gray = CGColorSpace(name: CGColorSpace.linearGray)!
        guard rect.width > 0, rect.height > 0,
              let image = context.createCGImage(output, from: rect, format: .L8, colorSpace: gray) else {
            throw ImagePipelineError.invalidMaskGeometry
        }
        return image
    }

    /// 출력의 긴 변이 `maxPixel`이면 마스크도 그만큼만 그리면 된다. 원본 해상도 출력은 1이다.
    static func maskScale(sourceWidth: CGFloat, sourceHeight: CGFloat, edits: EditSettings, maxPixel: Int?) -> Double {
        guard let maxPixel, maxPixel > 0 else { return 1 }
        let geometry = PhotoGeometry(sourceWidth: sourceWidth, sourceHeight: sourceHeight, edits: edits)
        let longest = max(geometry.outputSize.width, geometry.outputSize.height)
        guard longest.isFinite, longest > 0 else { return 1 }
        return min(1, Double(maxPixel) / Double(longest))
    }

    /// `scale` 해상도로 만든 마스크를 `extent` 크기로 늘린다. 가장자리는 늘리기 전에 연장해 테두리가 옅어지지 않게 한다.
    private func fittedMask(for adjustment: LocalAdjustment, extent: CGRect, scale: Double) throws -> CIImage {
        let width = Int(extent.width), height = Int(extent.height)
        let mask = try cachedMask(for: adjustment, width: width, height: height, scale: scale)
        guard mask.extent.width != CGFloat(width) || mask.extent.height != CGFloat(height) else { return mask }
        let stretch = CGAffineTransform(scaleX: CGFloat(width) / mask.extent.width,
                                        y: CGFloat(height) / mask.extent.height)
        return mask.clampedToExtent().samplingLinear().transformed(by: stretch)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// 편집 미리보기 파이프라인은 같은 모양의 마스크를 최근 8개까지 기억한다. 효과 값만 바꾸는 동안에는 다시 그리지 않는다.
    private func cachedMask(for adjustment: LocalAdjustment, width: Int, height: Int, scale: Double) throws -> CIImage {
        let definition = adjustment.maskDefinition
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        if cachesDevelopment {
            maskLock.lock()
            let hit = cachedMasks.first { $0.width == scaledWidth && $0.height == scaledHeight && $0.definition == definition }
            maskLock.unlock()
            if let hit { return hit.image }
        }
        var mask = try maskImage(for: adjustment, width: width, height: height, scale: scale)
        guard cachesDevelopment else { return mask }
        if adjustment.feather > 0, let flattened = context.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: nil) {
            mask = CIImage(cgImage: flattened, options: [.colorSpace: NSNull()])
        }
        maskLock.lock()
        cachedMasks.append((definition, scaledWidth, scaledHeight, mask))
        if cachedMasks.count > 8 { cachedMasks.removeFirst(cachedMasks.count - 8) }
        maskLock.unlock()
        return mask
    }

    private func maskImage(for adjustment: LocalAdjustment, width: Int, height: Int,
                           scale: Double) throws -> CIImage {
        guard width > 0, height > 0, scale.isFinite, scale > 0,
              Double(width) * scale < Double(Int.max), Double(height) * scale < Double(Int.max) else {
            throw ImagePipelineError.invalidMaskGeometry
        }
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        guard let bitmap = CGContext(data: nil, width: scaledWidth, height: scaledHeight,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.linearGray)!,
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ImagePipelineError.invalidMaskGeometry
        }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        if let baseMask = adjustment.baseMask {
            let decoded = try decodedMask(baseMask)
            bitmap.interpolationQuality = .high
            bitmap.draw(decoded, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        }
        if let gradient = adjustment.gradient {
            Self.draw(gradient, in: bitmap, width: Double(scaledWidth), height: Double(scaledHeight))
        }
        if adjustment.isInverted, let data = bitmap.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: bitmap.bytesPerRow * scaledHeight)
            for row in 0..<scaledHeight {
                for column in 0..<scaledWidth {
                    let index = row * bitmap.bytesPerRow + column
                    bytes[index] = 255 &- bytes[index]
                }
            }
        }
        bitmap.translateBy(x: 0, y: CGFloat(scaledHeight))
        bitmap.scaleBy(x: 1, y: -1)
        for stroke in adjustment.strokes {
            guard stroke.radius.isFinite, stroke.radius > 0 else { continue }
            let points = stroke.points.filter { $0.x.isFinite && $0.y.isFinite }
            guard let first = points.first else { continue }
            let radius = min(Double(max(scaledWidth, scaledHeight)),
                             stroke.radius * Double(min(scaledWidth, scaledHeight)))
            guard radius.isFinite, radius > 0 else { continue }
            let gray: CGFloat = stroke.isErasing ? 0 : 1
            bitmap.setFillColor(gray: gray, alpha: 1)
            bitmap.setStrokeColor(gray: gray, alpha: 1)
            bitmap.setLineWidth(CGFloat(radius * 2))
            bitmap.setLineCap(.round)
            bitmap.setLineJoin(.round)
            let firstPosition = CGPoint(x: first.x * Double(scaledWidth), y: first.y * Double(scaledHeight))
            bitmap.fillEllipse(in: CGRect(x: firstPosition.x - radius, y: firstPosition.y - radius,
                                          width: radius * 2, height: radius * 2))
            if points.count > 1 {
                bitmap.beginPath()
                bitmap.move(to: firstPosition)
                for point in points.dropFirst() {
                    bitmap.addLine(to: CGPoint(x: point.x * Double(scaledWidth),
                                               y: point.y * Double(scaledHeight)))
                }
                bitmap.strokePath()
            }
        }
        guard let cgImage = bitmap.makeImage() else { throw ImagePipelineError.invalidMaskGeometry }
        var mask = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
        let feather = adjustment.feather.isFinite ? max(0, adjustment.feather) : 0
        if feather > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = mask.clampedToExtent()
            blur.radius = Float(min(0.05, feather) * Double(min(scaledWidth, scaledHeight)))
            mask = (blur.outputImage ?? mask).cropped(to: mask.extent)
        }
        return mask
    }

    /// 원본 좌상단 기준 좌표로 그라데이션을 그린다. 이미 그린 마스크와는 밝은 쪽을 남겨 합친다.
    private static func draw(_ gradient: MaskGradient, in bitmap: CGContext, width: Double, height: Double) {
        let gray = CGColorSpace(name: CGColorSpace.linearGray)!
        bitmap.saveGState()
        defer { bitmap.restoreGState() }
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.setBlendMode(.lighten)
        switch gradient {
        case .linear(let start, let end):
            guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite),
                  hypot((end.x - start.x) * width, (end.y - start.y) * height) >= 1,
                  let ramp = CGGradient(colorSpace: gray, colorComponents: [1, 1, 0, 1], locations: [0, 1], count: 2)
            else { return }
            bitmap.drawLinearGradient(ramp, start: CGPoint(x: start.x * width, y: start.y * height),
                                      end: CGPoint(x: end.x * width, y: end.y * height),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial(let center, let radiusX, let radiusY, let softness):
            guard [center.x, center.y, radiusX, radiusY, softness].allSatisfy(\.isFinite),
                  radiusX > 0, radiusY > 0 else { return }
            let inner = CGFloat(1 - min(1, max(0, softness)))
            guard let ramp = CGGradient(colorSpace: gray, colorComponents: [1, 1, 1, 1, 0, 1],
                                        locations: [0, min(0.999, inner), 1], count: 3) else { return }
            bitmap.translateBy(x: center.x * width, y: center.y * height)
            bitmap.scaleBy(x: radiusX * width, y: radiusY * height)
            bitmap.drawRadialGradient(ramp, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                                      options: [])
        }
    }

    private func decodedMask(_ mask: RasterMask) throws -> CGImage {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard mask.width > 0, mask.height > 0,
              max(mask.width, mask.height) <= 1_536,
              mask.pngData.count <= Self.maximumMaskBytes,
              mask.pngData.count >= signature.count,
              Array(mask.pngData.prefix(signature.count)) == signature,
              let source = CGImageSourceCreateWithData(mask.pngData as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue == mask.width, height.intValue == mask.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagePipelineError.invalidMaskData("PNG 서명, 크기 또는 선언된 치수가 일치하지 않습니다")
        }
        return image
    }

    /// 크롭한 뒤의 화면 기준 비네팅. 원형 마스크로 가장자리 노출만 바꾼다. 음수는 어둡게, 양수는 밝게 한다.
    private func applyVignette(_ amount: Double, to image: CIImage) -> CIImage {
        guard amount != 0, amount.isFinite, image.extent.width > 0, image.extent.height > 0 else { return image }
        let extent = image.extent
        let halfDiagonal = hypot(extent.width, extent.height) / 2
        let mask = CIFilter.radialGradient()
        mask.center = CGPoint(x: extent.midX, y: extent.midY)
        mask.radius0 = Float(halfDiagonal * 0.35)
        mask.radius1 = Float(halfDiagonal)
        mask.color0 = CIColor(red: 0, green: 0, blue: 0)
        mask.color1 = CIColor(red: 1, green: 1, blue: 1)
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(min(1, max(-1, amount)) * 2)
        guard let gradient = mask.outputImage, let adjusted = exposure.outputImage else { return image }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjusted
        blend.backgroundImage = image
        blend.maskImage = gradient.cropped(to: extent)
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    private func transformedForDisplay(_ source: CIImage, edits: EditSettings, maxPixel: Int?) -> CIImage {
        let geometry = PhotoGeometry(sourceWidth: source.extent.width,
                                     sourceHeight: source.extent.height, edits: edits)
        let longestSide = max(geometry.outputSize.width, geometry.outputSize.height)
        let scale: CGFloat
        if let limit = maxPixel, limit > 0 {
            scale = min(1, CGFloat(limit) / longestSide)
        } else {
            scale = 1
        }
        let outputBounds = CGRect(
            x: 0,
            y: 0,
            width: floor(geometry.outputSize.width * scale),
            height: floor(geometry.outputSize.height * scale)
        )
        var image = source.clampedToExtent()
            .transformed(by: geometry.ciTransform)
        image = image.transformed(by: CGAffineTransform(translationX: -geometry.ciCropBounds.minX,
                                                        y: -geometry.ciCropBounds.minY))
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return image.cropped(to: outputBounds)
    }

    public func exportJPEG(url: URL, edits: EditSettings, to directory: URL,
                           maxPixel: Int?, quality: Double, includeLocation: Bool = false) throws -> URL {
        let preview = try prepareJPEG(url: url, edits: edits, maxPixel: maxPixel, quality: quality,
                                      includeLocation: includeLocation)
        return try writeJPEG(preview.data, sourceURL: url, to: directory)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
