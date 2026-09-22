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
    case lutFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "이미지를 읽을 수 없습니다: \(url.lastPathComponent)"
        case .renderFailed(let url): "이미지를 현상할 수 없습니다: \(url.lastPathComponent)"
        case .invalidDirectory(let url): "내보내기 폴더를 사용할 수 없습니다: \(url.path)"
        case .exportFailed(let url): "JPEG 파일을 저장할 수 없습니다: \(url.path)"
        case .invalidMaskGeometry: "영역 마스크의 이미지 크기가 올바르지 않습니다."
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

    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
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
        for adjustment in edits.localAdjustments where adjustment.isEnabled && !adjustment.strokes.isEmpty {
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
        let turns = ((edits.rotationQuarterTurns % 4) + 4) % 4
        let rotatedWidth = Double(turns.isMultiple(of: 2) ? sourceWidth : sourceHeight)
        let rotatedHeight = Double(turns.isMultiple(of: 2) ? sourceHeight : sourceWidth)
        let aspect = edits.cropAspect.flatMap {
            $0.isFinite && $0 > 0 && min(rotatedWidth, rotatedHeight * $0) > 0 &&
                min(rotatedWidth, rotatedHeight * $0) / $0 > 0 ? $0 : nil
        }
        let displayedWidth = aspect.map { min(rotatedWidth, rotatedHeight * $0) } ?? rotatedWidth
        let displayedHeight = aspect.map { displayedWidth / $0 } ?? rotatedHeight
        let scale = min(1, Double(max(1, maxPixel)) / max(displayedWidth, displayedHeight))
        let mask = try maskImage(for: adjustment, width: sourceWidth, height: sourceHeight, scale: scale)
        let output = transformedForDisplay(mask, edits: edits, maxPixel: maxPixel)
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
                                     space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ImagePipelineError.invalidMaskGeometry
        }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
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

    private func transformedForDisplay(_ source: CIImage, edits: EditSettings, maxPixel: Int?) -> CIImage {
        var image = source
        let turns = ((edits.rotationQuarterTurns % 4) + 4) % 4
        if turns != 0 { image = image.oriented(CGImagePropertyOrientation(rawValue: UInt32([1, 6, 3, 8][turns]))!) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let aspect = edits.cropAspect, aspect > 0, aspect.isFinite,
           min(image.extent.width, image.extent.height * aspect) > 0,
           min(image.extent.width, image.extent.height * aspect) / aspect > 0 {
            let bounds = image.extent
            let cropWidth = min(bounds.width, bounds.height * aspect)
            let cropHeight = cropWidth / aspect
            image = image.cropped(to: CGRect(x: (bounds.width - cropWidth) / 2,
                                            y: (bounds.height - cropHeight) / 2,
                                            width: cropWidth, height: cropHeight))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if let limit = maxPixel, limit > 0 {
            let scale = min(1, CGFloat(limit) / max(image.extent.width, image.extent.height))
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        return image
    }

    public func exportJPEG(url: URL, edits: EditSettings, to directory: URL,
                           maxPixel: Int?, quality: Double) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImagePipelineError.invalidDirectory(directory)
        }
        let image = try render(url: url, edits: edits, maxPixel: maxPixel)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePipelineError.exportFailed(directory)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePipelineError.exportFailed(directory) }
        let base = url.deletingPathExtension().lastPathComponent + "-edited"
        for number in 1...10_000 {
            let suffix = number == 1 ? "" : "-\(number)"
            let output = directory.appendingPathComponent(base + suffix + ".jpg")
            let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw ImagePipelineError.exportFailed(output)
            }
            do {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: encoded as Data)
                try handle.close()
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw ImagePipelineError.exportFailed(output)
            }
        }
        throw ImagePipelineError.exportFailed(directory)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
