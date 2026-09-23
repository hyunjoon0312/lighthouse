import Foundation

public struct LocalMaskGeometry: Sendable {
    public var displayAspect: Double { geometry.displayAspect }

    private let geometry: PhotoGeometry

    public init(sourceWidth: Double, sourceHeight: Double, rotationQuarterTurns: Int,
                cropAspect: Double?, straightenDegrees: Double = 0,
                cropRect: NormalizedCrop? = nil) {
        geometry = PhotoGeometry(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            edits: EditSettings(rotationQuarterTurns: rotationQuarterTurns,
                                cropAspect: cropAspect,
                                straightenDegrees: straightenDegrees,
                                cropRect: cropRect)
        )
    }

    public init(sourceWidth: Double, sourceHeight: Double, edits: EditSettings) {
        geometry = PhotoGeometry(sourceWidth: sourceWidth, sourceHeight: sourceHeight, edits: edits)
    }

    public func sourcePoint(fromDisplay point: MaskPoint) -> MaskPoint {
        geometry.sourcePoint(fromDisplay: point)
    }

    public func displayPoint(fromSource point: MaskPoint) -> MaskPoint {
        geometry.displayPoint(fromSource: point)
    }

    public func displayRadius(fromSource radius: Double) -> Double {
        geometry.displayRadius(fromSource: radius)
    }
}
