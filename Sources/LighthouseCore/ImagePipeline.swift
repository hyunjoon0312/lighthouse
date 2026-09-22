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

    let context: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lutStore: LUTStore

    public init(lutDirectory: URL = LUTStore.defaultDirectory) {
        context = CIContext(options: [.cacheIntermediates: false])
        lutStore = LUTStore(directory: lutDirectory)
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
            capturedAt: dateString.flatMap { formatter.date(from: $0) }
        )
    }

    public func thumbnail(for url: URL, maxPixel: Int = 360) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
              ] as CFDictionary) else { throw ImagePipelineError.unreadable(url) }
        return image
    }

    public func render(url: URL, edits: EditSettings, maxPixel: Int? = 2200) throws -> CGImage {
        var image: CIImage
        if Self.isRAW(url) {
            guard let raw = CIRAWFilter(imageURL: url) else { throw ImagePipelineError.unreadable(url) }
            let originalExposure = raw.exposure
            let originalTemperature = raw.neutralTemperature
            let originalTint = raw.neutralTint
            raw.exposure = originalExposure + Float(edits.exposure)
            raw.neutralTemperature = min(50_000, max(2_000, originalTemperature + Float(edits.temperatureShift)))
            raw.neutralTint = min(150, max(-150, originalTint + Float(edits.tintShift)))
            guard let output = raw.outputImage else { throw ImagePipelineError.renderFailed(url) }
            image = output
        } else {
            guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw ImagePipelineError.unreadable(url)
            }
            image = source
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
                filter.targetNeutral = CIVector(x: 6500 + edits.temperatureShift, y: edits.tintShift)
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
        if edits.sharpness != 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(edits.sharpness)
            image = filter.outputImage ?? image
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        image = try RetouchProcessor.apply(to: image, strokes: edits.retouchStrokes,
                                           context: context, colorSpace: colorSpace)
        image = try AdvancedColorProcessor.applyColor(to: image, curves: edits.curves,
                                                      ranges: edits.colorRanges)
        for adjustment in edits.localAdjustments where adjustment.isEnabled &&
            (adjustment.baseMask != nil || adjustment.isInverted || !adjustment.strokes.isEmpty) {
            if let baseMask = adjustment.baseMask { _ = try decodedMask(baseMask) }
            guard adjustment.exposure.isFinite, adjustment.contrast.isFinite,
                  adjustment.exposure != 0 || adjustment.contrast != 1 else { continue }
            let mask = try maskImage(for: adjustment, width: Int(image.extent.width),
                                     height: Int(image.extent.height), scale: 1)
            var adjusted = image
            if adjustment.exposure != 0 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = adjusted
                filter.ev = Float(adjustment.exposure)
                adjusted = filter.outputImage ?? adjusted
            }
            if adjustment.contrast != 1 {
                let filter = CIFilter.colorControls()
                filter.inputImage = adjusted
                filter.contrast = Float(adjustment.contrast)
                adjusted = filter.outputImage ?? adjusted
            }
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
        let rect = CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height))
        guard rect.width > 0, rect.height > 0,
              let result = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
            throw ImagePipelineError.renderFailed(url)
        }
        return result
    }

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
        let geometry = PhotoGeometry(sourceWidth: Double(sourceWidth),
                                     sourceHeight: Double(sourceHeight), edits: edits)
        let scale = min(1, Double(max(1, maxPixel)) /
            max(geometry.outputSize.width, geometry.outputSize.height))
        let mask = try maskImage(for: adjustment, width: sourceWidth, height: sourceHeight, scale: 1)
        let renderLimit = max(1, Int((max(geometry.outputSize.width,
                                         geometry.outputSize.height) * scale).rounded(.down)))
        let output = transformedForDisplay(mask, edits: edits, maxPixel: renderLimit)
        let rect = CGRect(x: 0, y: 0, width: floor(output.extent.width), height: floor(output.extent.height))
        let gray = CGColorSpace(name: CGColorSpace.linearGray)!
        guard rect.width > 0, rect.height > 0,
              let image = context.createCGImage(output, from: rect, format: .L8, colorSpace: gray) else {
            throw ImagePipelineError.invalidMaskGeometry
        }
        return image
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

    private func transformedForDisplay(_ source: CIImage, edits: EditSettings, maxPixel: Int?) -> CIImage {
        let geometry = PhotoGeometry(sourceWidth: source.extent.width,
                                     sourceHeight: source.extent.height, edits: edits)
        var image = source.clampedToExtent()
            .transformed(by: geometry.ciTransform)
            .cropped(to: geometry.ciCropBounds)
        image = image.transformed(by: CGAffineTransform(translationX: -geometry.ciCropBounds.minX,
                                                        y: -geometry.ciCropBounds.minY))
        if let limit = maxPixel, limit > 0 {
            let scale = min(1, CGFloat(limit) / max(image.extent.width, image.extent.height))
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        return image
    }

    public func exportJPEG(url: URL, edits: EditSettings, to directory: URL,
                           maxPixel: Int?, quality: Double) throws -> URL {
        let preview = try prepareJPEG(url: url, edits: edits, maxPixel: maxPixel, quality: quality)
        return try writeJPEG(preview.data, sourceURL: url, to: directory)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
