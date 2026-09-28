import CoreGraphics
import Foundation

enum FaceAlignment {
    enum Error: LocalizedError {
        case invalidPointCount
        case nonfinitePoint
        case degeneratePoints

        var errorDescription: String? {
            switch self {
            case .invalidPointCount: "얼굴 정렬에는 정확히 다섯 개의 특징점이 필요합니다."
            case .nonfinitePoint: "얼굴 특징점 좌표가 올바르지 않습니다."
            case .degeneratePoints: "얼굴 특징점으로 정렬 변환을 계산할 수 없습니다."
            }
        }
    }

    static let canonicalPoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 112 - 51.6963),
        CGPoint(x: 73.5318, y: 112 - 51.5014),
        CGPoint(x: 56.0252, y: 112 - 71.7366),
        CGPoint(x: 41.5493, y: 112 - 92.3655),
        CGPoint(x: 70.7299, y: 112 - 92.2041),
    ]

    static func transform(source: [CGPoint], target: [CGPoint]) throws -> CGAffineTransform {
        guard source.count == 5, target.count == 5 else { throw Error.invalidPointCount }
        guard (source + target).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw Error.nonfinitePoint
        }

        let sourceCenter = center(of: source)
        let targetCenter = center(of: target)
        var denominator: CGFloat = 0
        var aNumerator: CGFloat = 0
        var bNumerator: CGFloat = 0
        for (sourcePoint, targetPoint) in zip(source, target) {
            let sourceX = sourcePoint.x - sourceCenter.x
            let sourceY = sourcePoint.y - sourceCenter.y
            let targetX = targetPoint.x - targetCenter.x
            let targetY = targetPoint.y - targetCenter.y
            denominator += sourceX * sourceX + sourceY * sourceY
            aNumerator += sourceX * targetX + sourceY * targetY
            bNumerator += sourceX * targetY - sourceY * targetX
        }
        guard denominator.isFinite, denominator > 1e-12 else { throw Error.degeneratePoints }

        let a = aNumerator / denominator
        let b = bNumerator / denominator
        let values = [a, b, a * a + b * b]
        guard values.allSatisfy(\.isFinite), let scaleSquared = values.last,
              scaleSquared > 1e-12 else { throw Error.degeneratePoints }
        let translationX = targetCenter.x - a * sourceCenter.x + b * sourceCenter.y
        let translationY = targetCenter.y - b * sourceCenter.x - a * sourceCenter.y
        guard translationX.isFinite, translationY.isFinite else { throw Error.degeneratePoints }
        return CGAffineTransform(
            a: a,
            b: b,
            c: -b,
            d: a,
            tx: translationX,
            ty: translationY
        )
    }

    private static func center(of points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
