import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Lightroom 캘리브레이션: 그림자 틴트와 빨강·초록·파랑 원색의 색조·채도. 모두 -1…1, 0이 중립이다.
public struct CalibrationSettings: Codable, Equatable, Sendable {
    public var shadowTint: Double
    public var redHue: Double
    public var redSaturation: Double
    public var greenHue: Double
    public var greenSaturation: Double
    public var blueHue: Double
    public var blueSaturation: Double

    public init(shadowTint: Double = 0, redHue: Double = 0, redSaturation: Double = 0, greenHue: Double = 0,
                greenSaturation: Double = 0, blueHue: Double = 0, blueSaturation: Double = 0) {
        self.shadowTint = shadowTint
        self.redHue = redHue
        self.redSaturation = redSaturation
        self.greenHue = greenHue
        self.greenSaturation = greenSaturation
        self.blueHue = blueHue
        self.blueSaturation = blueSaturation
    }

    public static let neutral = CalibrationSettings()
    public var isNeutral: Bool { self == .neutral }

    var values: [Double] { [shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation] }

    private enum CodingKeys: String, CodingKey {
        case shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double {
            container.contains(key) ? try container.decode(Double.self, forKey: key) : 0
        }
        self.init(shadowTint: try value(.shadowTint), redHue: try value(.redHue), redSaturation: try value(.redSaturation),
                  greenHue: try value(.greenHue), greenSaturation: try value(.greenSaturation),
                  blueHue: try value(.blueHue), blueSaturation: try value(.blueSaturation))
        guard values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Calibration values must be within -1…1"))
        }
    }
}

/// 계약: docs/camera-profiles-calibration-contract.md
enum CalibrationProcessor {
    static let luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// 선형 RGB에 곱하는 행렬(행 우선). 원색의 채도 벡터를 회색 축 둘레로 돌리고 늘인 뒤 흰색이 흰색으로 남게 고친다.
    static func matrix(_ settings: CalibrationSettings) -> Matrix3 {
        let adjustments = [(settings.redHue, settings.redSaturation), (settings.greenHue, settings.greenSaturation),
                           (settings.blueHue, settings.blueSaturation)]
        let axis = SIMD3<Double>(repeating: 1 / 3.0.squareRoot())
        var columns: [SIMD3<Double>] = []
        for (index, (hue, saturation)) in adjustments.enumerated() {
            var primary = SIMD3<Double>(repeating: 0)
            primary[index] = 1
            let chroma = primary - SIMD3(repeating: 1.0 / 3)
            let angle = min(1, max(-1, hue)) * 30 * .pi / 180
            let cross = SIMD3(axis.y * chroma.z - axis.z * chroma.y, axis.z * chroma.x - axis.x * chroma.z,
                              axis.x * chroma.y - axis.y * chroma.x)
            let rotated = chroma * cos(angle) + cross * sin(angle)
            columns.append(SIMD3(repeating: 1.0 / 3) + rotated * (1 + 0.5 * min(1, max(-1, saturation))))
        }
        let white = columns[0] + columns[1] + columns[2]
        let error = SIMD3<Double>(repeating: 1) - white
        for index in 0..<3 { columns[index] += error * luma[index] }
        return Matrix3(values: [columns[0].x, columns[1].x, columns[2].x,
                                columns[0].y, columns[1].y, columns[2].y,
                                columns[0].z, columns[1].z, columns[2].z])
    }

    static func apply(_ settings: CalibrationSettings, to image: CIImage) -> CIImage {
        guard !settings.isNeutral, settings.values.allSatisfy(\.isFinite) else { return image }
        var result = image
        if settings.redHue != 0 || settings.redSaturation != 0 || settings.greenHue != 0
            || settings.greenSaturation != 0 || settings.blueHue != 0 || settings.blueSaturation != 0 {
            let m = matrix(settings).values
            let filter = CIFilter.colorMatrix()
            filter.inputImage = result
            filter.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
            filter.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
            filter.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            result = filter.outputImage ?? result
        }
        if settings.shadowTint != 0, let kernel = CoreImageKernels.shadowTint,
           let tinted = kernel.apply(extent: result.extent,
                                     arguments: [result, Float(min(1, max(-1, settings.shadowTint)))]) {
            result = tinted
        }
        return result
    }
}
