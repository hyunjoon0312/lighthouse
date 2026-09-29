import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public extension ImagePipeline {
    func rangeMask(url: URL, selection: RangeSelection) throws -> RasterMask {
        guard selection.isValid else {
            throw ImagePipelineError.rangeMaskFailed("선택 값이 유한한 허용 범위를 벗어났습니다.")
        }
        let image = try render(url: url, edits: .neutral, maxPixel: 1_536)
        let width = image.width
        let height = image.height
        let rowBytes = width * 4
        guard let bitmap = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sourceBase = bitmap.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ImagePipelineError.rangeMaskFailed("이미지 픽셀을 읽을 수 없습니다.")
        }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var maskBytes = Data(count: width * height)
        maskBytes.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<(width * height) {
                let alpha = Double(sourceBase[index * 4 + 3]) / 255
                guard alpha > 0 else { destinationBase[index] = 0; continue }
                let red = min(1, Double(sourceBase[index * 4]) / 255 / alpha)
                let green = min(1, Double(sourceBase[index * 4 + 1]) / 255 / alpha)
                let blue = min(1, Double(sourceBase[index * 4 + 2]) / 255 / alpha)
                let value: Double
                switch selection.kind {
                case .luminance:
                    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    value = Self.rangeWeight(luminance, lower: selection.lower,
                                             upper: selection.upper, softness: selection.softness)
                case .color:
                    let distance = sqrt(pow(red - selection.red, 2) + pow(green - selection.green, 2)
                                        + pow(blue - selection.blue, 2)) / sqrt(3)
                    value = Self.colorWeight(distance, tolerance: selection.tolerance,
                                             softness: selection.softness)
                }
                destinationBase[index] = UInt8((min(1, max(0, value)) * 255).rounded())
            }
        }
        guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width, space: CGColorSpace(name: CGColorSpace.linearGray)!,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue), let grayData = gray.data else {
            throw ImagePipelineError.rangeMaskFailed("마스크 이미지를 만들 수 없습니다.")
        }
        maskBytes.copyBytes(to: grayData.assumingMemoryBound(to: UInt8.self), count: maskBytes.count)
        guard
              let maskImage = gray.makeImage() else {
            throw ImagePipelineError.rangeMaskFailed("마스크 이미지를 만들 수 없습니다.")
        }
        return try encodedRasterMask(maskImage)
    }
}

extension ImagePipeline {
    func encodedRasterMask(_ mask: CGImage) throws -> RasterMask {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ImagePipelineError.invalidMaskData("PNG 인코더 생성 실패")
        }
        CGImageDestinationAddImage(destination, mask, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagePipelineError.invalidMaskData("PNG 인코딩 실패")
        }
        let data = encoded as Data
        guard data.count <= Self.maximumMaskBytes else {
            throw ImagePipelineError.invalidMaskData("마스크 데이터가 8 MiB를 초과합니다")
        }
        return RasterMask(width: mask.width, height: mask.height, pngData: data)
    }

    private static func rangeWeight(_ value: Double, lower: Double, upper: Double, softness: Double) -> Double {
        if value >= lower && value <= upper { return 1 }
        guard softness > 0 else { return 0 }
        if value < lower { return smoothStep((value - (lower - softness)) / softness) }
        return smoothStep(((upper + softness) - value) / softness)
    }

    private static func colorWeight(_ distance: Double, tolerance: Double, softness: Double) -> Double {
        if distance <= tolerance { return 1 }
        guard softness > 0 else { return 0 }
        return smoothStep((tolerance + softness - distance) / softness)
    }

    private static func smoothStep(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }
}
