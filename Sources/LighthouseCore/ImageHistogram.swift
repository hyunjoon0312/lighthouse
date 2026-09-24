import CoreGraphics
import Foundation

/// 화면에 보이는 sRGB 미리보기의 채널별 256단계 히스토그램과 클리핑 비율.
public struct ImageHistogram: Equatable, Sendable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    public let luminance: [Int]
    public let sampleCount: Int
    /// 어느 한 채널이라도 255인 픽셀 비율.
    public let highlightClipped: Double
    /// 세 채널이 모두 1 이하인 픽셀 비율.
    public let shadowClipped: Double

    public static func make(from image: CGImage, maxSide: Int = 1_024) -> ImageHistogram? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let pixels = rgbaPixels(of: image, width: width, height: height) else { return nil }
        var red = [Int](repeating: 0, count: 256), green = red, blue = red, luminance = red
        var highlights = 0, shadows = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            red[r] += 1
            green[g] += 1
            blue[b] += 1
            luminance[min(255, (r * 54 + g * 183 + b * 19 + 128) >> 8)] += 1
            if r == 255 || g == 255 || b == 255 { highlights += 1 }
            if r <= 1 && g <= 1 && b <= 1 { shadows += 1 }
        }
        let count = width * height
        return ImageHistogram(red: red, green: green, blue: blue, luminance: luminance, sampleCount: count,
                              highlightClipped: Double(highlights) / Double(count),
                              shadowClipped: Double(shadows) / Double(count))
    }

    /// 원본 크기와 같은 투명 이미지에 하이라이트 클리핑은 빨강, 섀도 클리핑은 파랑으로 칠한다.
    public static func clippingOverlay(for image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard var pixels = rgbaPixels(of: image, width: width, height: height) else { return nil }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[index], g = pixels[index + 1], b = pixels[index + 2]
            let overlay: (UInt8, UInt8, UInt8, UInt8)
            if r == 255 || g == 255 || b == 255 {
                overlay = (255, 40, 40, 255)
            } else if r <= 1 && g <= 1 && b <= 1 {
                overlay = (40, 110, 255, 255)
            } else {
                overlay = (0, 0, 0, 0)
            }
            pixels[index] = overlay.0
            pixels[index + 1] = overlay.1
            pixels[index + 2] = overlay.2
            pixels[index + 3] = overlay.3
        }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private static func rgbaPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
