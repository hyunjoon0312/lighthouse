import Foundation

public struct LocalMaskGeometry: Sendable {
    public let displayAspect: Double

    private let turns: Int
    private let sourceShortSide: Double
    private let croppedShortSide: Double
    private let cropX: Double
    private let cropY: Double
    private let cropWidth: Double
    private let cropHeight: Double

    public init(sourceWidth: Double, sourceHeight: Double, rotationQuarterTurns: Int, cropAspect: Double?) {
        let width = sourceWidth.isFinite && sourceWidth > 0 ? sourceWidth : 1
        let height = sourceHeight.isFinite && sourceHeight > 0 ? sourceHeight : 1
        turns = ((rotationQuarterTurns % 4) + 4) % 4
        sourceShortSide = min(width, height)
        let rotatedWidth = turns.isMultiple(of: 2) ? width : height
        let rotatedHeight = turns.isMultiple(of: 2) ? height : width
        let widthAfterCrop: Double
        let heightAfterCrop: Double
        if let aspect = cropAspect, aspect.isFinite, aspect > 0,
           min(rotatedWidth, rotatedHeight * aspect) > 0,
           (min(rotatedWidth, rotatedHeight * aspect) / aspect) > 0 {
            widthAfterCrop = min(rotatedWidth, rotatedHeight * aspect)
            heightAfterCrop = widthAfterCrop / aspect
        } else {
            widthAfterCrop = rotatedWidth
            heightAfterCrop = rotatedHeight
        }
        cropX = (rotatedWidth - widthAfterCrop) / (2 * rotatedWidth)
        cropY = (rotatedHeight - heightAfterCrop) / (2 * rotatedHeight)
        cropWidth = widthAfterCrop / rotatedWidth
        cropHeight = heightAfterCrop / rotatedHeight
        croppedShortSide = min(widthAfterCrop, heightAfterCrop)
        displayAspect = widthAfterCrop / heightAfterCrop
    }

    public func sourcePoint(fromDisplay point: MaskPoint) -> MaskPoint {
        let x = cropX + point.x * cropWidth
        let y = cropY + point.y * cropHeight
        switch turns {
        case 1: return MaskPoint(x: y, y: 1 - x)
        case 2: return MaskPoint(x: 1 - x, y: 1 - y)
        case 3: return MaskPoint(x: 1 - y, y: x)
        default: return MaskPoint(x: x, y: y)
        }
    }

    public func displayPoint(fromSource point: MaskPoint) -> MaskPoint {
        let rotated: MaskPoint
        switch turns {
        case 1: rotated = MaskPoint(x: 1 - point.y, y: point.x)
        case 2: rotated = MaskPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: rotated = MaskPoint(x: point.y, y: 1 - point.x)
        default: rotated = point
        }
        return MaskPoint(x: (rotated.x - cropX) / cropWidth,
                         y: (rotated.y - cropY) / cropHeight)
    }

    public func displayRadius(fromSource radius: Double) -> Double {
        radius * sourceShortSide / croppedShortSide
    }
}
