import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum RetouchProcessingError: LocalizedError, Equatable, Sendable {
    case invalidStroke
    case missingCloneSource
    case noHealingSource
    case processingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidStroke:
            "복구 브러시 좌표가 올바르지 않습니다."
        case .missingCloneSource:
            "복제할 원본 위치를 먼저 선택해 주세요."
        case .noHealingSource:
            "주변에서 사용할 패치를 찾지 못했습니다. 브러시 크기를 줄여 주세요."
        case .processingFailed:
            "복구 효과를 처리할 수 없습니다."
        }
    }
}

enum RetouchProcessor {
    private static let correctionKernel = CIColorKernel(source: """
        kernel vec4 healCorrection(__sample source, __sample lowTarget, __sample lowSource) {
            return vec4(clamp(source.rgb + lowTarget.rgb - lowSource.rgb, 0.0, 1.0), source.a);
        }
        """)

    static func apply(to source: CIImage, strokes: [RetouchStroke],
                      context: CIContext, colorSpace: CGColorSpace) throws -> CIImage {
        guard !strokes.isEmpty else { return source }
        let bounds = source.extent
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw RetouchProcessingError.processingFailed
        }
        var image = source
        for stroke in strokes where stroke.isEnabled && !stroke.points.isEmpty {
            image = try apply(stroke, to: image, context: context, colorSpace: colorSpace)
        }
        return image
    }

    private static func apply(_ stroke: RetouchStroke, to image: CIImage,
                              context: CIContext, colorSpace: CGColorSpace) throws -> CIImage {
        guard stroke.radius.isFinite,
              stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw RetouchProcessingError.invalidStroke
        }
        let radiusFraction = min(0.15, max(0.002, stroke.radius))
        let radius = radiusFraction * min(image.extent.width, image.extent.height)
        let offset: MaskPoint
        switch stroke.mode {
        case .clone:
            guard let requested = stroke.sourceOffset,
                  requested.x.isFinite, requested.y.isFinite else {
                throw RetouchProcessingError.missingCloneSource
            }
            offset = requested
        case .heal:
            offset = try healingOffset(for: stroke, radius: radius,
                                       image: image, context: context, colorSpace: colorSpace)
        }

        let translation = CGAffineTransform(
            translationX: -offset.x * image.extent.width,
            y: offset.y * image.extent.height
        )
        let translated = image.transformed(by: translation)
        let shiftedSupport = CIImage(color: CIColor.white)
            .cropped(to: image.extent)
            .transformed(by: translation)
            .cropped(to: image.extent)
        let blackCanvas = CIImage(color: CIColor.black).cropped(to: image.extent)
        let flattenSupport = CIFilter.sourceOverCompositing()
        flattenSupport.inputImage = shiftedSupport
        flattenSupport.backgroundImage = blackCanvas
        guard let support = flattenSupport.outputImage?.cropped(to: image.extent) else {
            throw RetouchProcessingError.processingFailed
        }
        var patch = translated
        if stroke.mode == .heal {
            guard let kernel = correctionKernel else {
                throw RetouchProcessingError.processingFailed
            }
            let sigma = radius * 0.6
            let lowTarget = blurred(image, radius: sigma)
            let lowSource = lowTarget.transformed(by: translation)
            guard let corrected = kernel.apply(
                extent: image.extent,
                arguments: [translated, lowTarget, lowSource]
            ) else {
                throw RetouchProcessingError.processingFailed
            }
            patch = corrected
        }

        var mask = try strokeMask(stroke, width: Int(image.extent.width.rounded(.up)),
                                  height: Int(image.extent.height.rounded(.up)),
                                  radius: radius)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = mask.clampedToExtent()
        blur.radius = Float(max(0.5, radius * 0.25))
        if let softened = blur.outputImage { mask = softened.cropped(to: image.extent) }
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = mask
        multiply.backgroundImage = support
        guard let supportedMask = multiply.outputImage?.cropped(to: image.extent) else {
            throw RetouchProcessingError.processingFailed
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = patch
        blend.backgroundImage = image
        blend.maskImage = supportedMask
        guard let output = blend.outputImage else { throw RetouchProcessingError.processingFailed }
        return output.cropped(to: image.extent)
    }

    private static func blurred(_ image: CIImage, radius: CGFloat) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(radius)
        return (blur.outputImage ?? image).cropped(to: image.extent)
    }

    private static func strokeMask(_ stroke: RetouchStroke, width: Int,
                                   height: Int, radius: CGFloat) throws -> CIImage {
        guard width > 0, height > 0,
              let bitmap = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.linearGray)!,
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw RetouchProcessingError.processingFailed
        }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.translateBy(x: 0, y: CGFloat(height))
        bitmap.scaleBy(x: 1, y: -1)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.setStrokeColor(gray: 1, alpha: 1)
        bitmap.setLineWidth(radius * 2)
        bitmap.setLineCap(.round)
        bitmap.setLineJoin(.round)
        let positions = stroke.points.map {
            CGPoint(x: $0.x * Double(width), y: $0.y * Double(height))
        }
        guard let first = positions.first else { throw RetouchProcessingError.invalidStroke }
        bitmap.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                      width: radius * 2, height: radius * 2))
        if positions.count > 1 {
            bitmap.beginPath()
            bitmap.move(to: first)
            for point in positions.dropFirst() { bitmap.addLine(to: point) }
            bitmap.strokePath()
        }
        guard let image = bitmap.makeImage() else { throw RetouchProcessingError.processingFailed }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    private static func healingOffset(for stroke: RetouchStroke, radius: CGFloat,
                                      image: CIImage, context: CIContext,
                                      colorSpace: CGColorSpace) throws -> MaskPoint {
        guard let first = stroke.points.first else { throw RetouchProcessingError.invalidStroke }
        let width = image.extent.width
        let height = image.extent.height
        let directions: [(Double, Double)] = [
            (1, 0), (0, 1), (-1, 0), (0, -1),
            (0.70710678, 0.70710678), (-0.70710678, 0.70710678),
            (-0.70710678, -0.70710678), (0.70710678, -0.70710678)
        ]
        let analysis = try analysisPixels(image: image, context: context, colorSpace: colorSpace)
        var best: (error: Double, offset: MaskPoint)?
        for distance in [3.0, 5.0] {
            for direction in directions {
                let dx = direction.0 * distance * Double(radius)
                let dy = direction.1 * distance * Double(radius)
                let offset = MaskPoint(x: dx / width, y: dy / height)
                guard pathIsInside(stroke.points, offset: offset,
                                   radius: Double(radius), width: width, height: height) else { continue }
                let error = boundaryError(center: first, offset: offset,
                                          radius: Double(radius), imageWidth: width,
                                          imageHeight: height, pixels: analysis)
                if best == nil || error < best!.error {
                    best = (error, offset)
                }
            }
        }
        guard let best else { throw RetouchProcessingError.noHealingSource }
        return best.offset
    }

    private static func pathIsInside(_ points: [MaskPoint], offset: MaskPoint,
                                     radius: Double, width: CGFloat, height: CGFloat) -> Bool {
        let marginX = radius / width
        let marginY = radius / height
        guard points.allSatisfy({ point in
            let sourceX = point.x + offset.x
            let sourceY = point.y + offset.y
            return sourceX >= marginX && sourceX <= 1 - marginX &&
                sourceY >= marginY && sourceY <= 1 - marginY
        }) else { return false }
        let destination = pathBounds(points, radius: radius, width: width, height: height)
        let source = destination.offsetBy(dx: offset.x * width, dy: offset.y * height)
        return !destination.intersects(source)
    }

    private static func pathBounds(_ points: [MaskPoint], radius: Double,
                                   width: CGFloat, height: CGFloat) -> CGRect {
        let xs = points.map { $0.x * width }
        let ys = points.map { $0.y * height }
        return CGRect(x: xs.min()! - radius, y: ys.min()! - radius,
                      width: xs.max()! - xs.min()! + radius * 2,
                      height: ys.max()! - ys.min()! + radius * 2)
    }

    private struct AnalysisPixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let rowBytes: Int

        func rgb(x: Double, y: Double) -> SIMD3<Double> {
            let pixelX = min(width - 1, max(0, Int((x * Double(width)).rounded(.down))))
            let pixelY = min(height - 1, max(0, Int((y * Double(height)).rounded(.down))))
            let ciRow = height - 1 - pixelY
            let index = ciRow * rowBytes + pixelX * 4
            return SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2])) / 255
        }
    }

    private static func analysisPixels(image: CIImage, context: CIContext,
                                       colorSpace: CGColorSpace) throws -> AnalysisPixels {
        let scale = min(1, 256 / max(image.extent.width, image.extent.height))
        let width = max(1, Int((image.extent.width * scale).rounded()))
        let height = max(1, Int((image.extent.height * scale).rounded()))
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(scaled, toBitmap: &bytes, rowBytes: rowBytes,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: colorSpace)
        return AnalysisPixels(bytes: bytes, width: width, height: height, rowBytes: rowBytes)
    }

    private static func boundaryError(center: MaskPoint, offset: MaskPoint,
                                      radius: Double, imageWidth: CGFloat,
                                      imageHeight: CGFloat, pixels: AnalysisPixels) -> Double {
        var error = 0.0
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let dx = cos(angle) * radius * 1.2 / imageWidth
            let dy = sin(angle) * radius * 1.2 / imageHeight
            let target = pixels.rgb(x: center.x + dx, y: center.y + dy)
            let candidate = pixels.rgb(x: center.x + offset.x + dx,
                                       y: center.y + offset.y + dy)
            let difference = target - candidate
            error += Double(difference.x * difference.x + difference.y * difference.y + difference.z * difference.z)
        }
        return error / 8
    }
}
