import CoreGraphics
import Foundation

public struct PhotoGeometry: Sendable {
    public let canvasSize: CGSize
    public let cropBounds: CGRect
    public let outputSize: CGSize
    public let sourceToCanvas: CGAffineTransform
    public let ciTransform: CGAffineTransform
    public let ciCropBounds: CGRect
    public let displayAspect: Double

    private let sourceSize: CGSize
    private let sourceShortSide: Double

    public init(sourceWidth: Double, sourceHeight: Double, edits: EditSettings) {
        let width = sourceWidth.isFinite && sourceWidth > 0 ? sourceWidth : 1
        let height = sourceHeight.isFinite && sourceHeight > 0 ? sourceHeight : 1
        sourceSize = CGSize(width: width, height: height)
        sourceShortSide = min(width, height)

        let turns = ((edits.rotationQuarterTurns % 4) + 4) % 4
        let rotatedWidth = turns.isMultiple(of: 2) ? width : height
        let rotatedHeight = turns.isMultiple(of: 2) ? height : width
        let quarterTurn = Self.quarterTurnTransform(turns: turns, width: width, height: height)

        let requestedAngle = edits.straightenDegrees.isFinite ? edits.straightenDegrees : 0
        let angleDegrees = min(20, max(-20, requestedAngle))
        let angle = angleDegrees * .pi / 180
        let cosine = cos(abs(angle))
        let sine = sin(abs(angle))
        let scale = min(
            rotatedWidth / (rotatedWidth * cosine + rotatedHeight * sine),
            rotatedHeight / (rotatedWidth * sine + rotatedHeight * cosine)
        )
        let canvasWidth = rotatedWidth * scale
        let canvasHeight = rotatedHeight * scale
        canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

        let rotationCosine = cos(angle)
        let rotationSine = sin(angle)
        let straighten = CGAffineTransform(
            a: rotationCosine,
            b: rotationSine,
            c: -rotationSine,
            d: rotationCosine,
            tx: canvasWidth / 2 - rotationCosine * rotatedWidth / 2 + rotationSine * rotatedHeight / 2,
            ty: canvasHeight / 2 - rotationSine * rotatedWidth / 2 - rotationCosine * rotatedHeight / 2
        )
        sourceToCanvas = Self.applying(quarterTurn, then: straighten)

        if let requestedCrop = edits.cropRect {
            let crop = requestedCrop.clamped
            cropBounds = CGRect(
                x: crop.x * canvasWidth,
                y: crop.y * canvasHeight,
                width: crop.width * canvasWidth,
                height: crop.height * canvasHeight
            )
        } else if let aspect = edits.cropAspect, aspect.isFinite, aspect > 0 {
            let cropWidth = min(canvasWidth, canvasHeight * aspect)
            let cropHeight = cropWidth / aspect
            cropBounds = CGRect(
                x: (canvasWidth - cropWidth) / 2,
                y: (canvasHeight - cropHeight) / 2,
                width: cropWidth,
                height: cropHeight
            )
        } else {
            cropBounds = CGRect(origin: .zero, size: canvasSize)
        }
        outputSize = cropBounds.size
        displayAspect = cropBounds.width / cropBounds.height

        let transform = sourceToCanvas
        ciTransform = CGAffineTransform(
            a: transform.a,
            b: -transform.b,
            c: -transform.c,
            d: transform.d,
            tx: transform.c * height + transform.tx,
            ty: canvasHeight - transform.d * height - transform.ty
        )
        ciCropBounds = CGRect(
            x: cropBounds.minX,
            y: canvasHeight - cropBounds.maxY,
            width: cropBounds.width,
            height: cropBounds.height
        )
    }

    public func sourcePoint(fromDisplay point: MaskPoint) -> MaskPoint {
        let canvasPoint = CGPoint(
            x: cropBounds.minX + point.x * cropBounds.width,
            y: cropBounds.minY + point.y * cropBounds.height
        )
        let sourcePoint = canvasPoint.applying(sourceToCanvas.inverted())
        return MaskPoint(x: sourcePoint.x / sourceSize.width,
                         y: sourcePoint.y / sourceSize.height)
    }

    public func displayPoint(fromSource point: MaskPoint) -> MaskPoint {
        let sourcePoint = CGPoint(x: point.x * sourceSize.width, y: point.y * sourceSize.height)
        let canvasPoint = sourcePoint.applying(sourceToCanvas)
        return MaskPoint(x: (canvasPoint.x - cropBounds.minX) / cropBounds.width,
                         y: (canvasPoint.y - cropBounds.minY) / cropBounds.height)
    }

    public func displayRadius(fromSource radius: Double) -> Double {
        radius * sourceShortSide / min(outputSize.width, outputSize.height)
    }

    private static func quarterTurnTransform(turns: Int, width: Double,
                                             height: Double) -> CGAffineTransform {
        switch turns {
        case 1:
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 2:
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3:
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default:
            .identity
        }
    }

    private static func applying(_ first: CGAffineTransform,
                                 then second: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: second.a * first.a + second.c * first.b,
            b: second.b * first.a + second.d * first.b,
            c: second.a * first.c + second.c * first.d,
            d: second.b * first.c + second.d * first.d,
            tx: second.a * first.tx + second.c * first.ty + second.tx,
            ty: second.b * first.tx + second.d * first.ty + second.ty
        )
    }
}
