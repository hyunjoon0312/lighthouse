import CoreGraphics
import CoreText
import Foundation

public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft, center
}

/// 출력 사진 위에 쓰는 글자. 크기는 출력 짧은 변에 대한 비율이라 긴 변 설정이 달라도 같은 비율로 보인다.
public struct Watermark: Codable, Equatable, Sendable {
    public var text: String
    public var position: WatermarkPosition
    public var size: Double
    public var opacity: Double

    public init(text: String, position: WatermarkPosition = .bottomRight, size: Double = 0.035,
                opacity: Double = 0.8) {
        self.text = text
        self.position = position
        self.size = size
        self.opacity = opacity
    }

    public func applied(to image: CGImage) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return image }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let shortSide = CGFloat(min(width, height))
        let fontSize = max(6, shortSide * CGFloat(min(0.2, max(0.01, size))))
        let alpha = CGFloat(min(1, max(0, opacity)))
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: trimmed, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, context)
        let margin = shortSide * 0.03
        let x: CGFloat, y: CGFloat
        switch position {
        case .bottomRight: x = CGFloat(width) - margin - bounds.maxX; y = margin - bounds.minY
        case .bottomLeft: x = margin - bounds.minX; y = margin - bounds.minY
        case .topRight: x = CGFloat(width) - margin - bounds.maxX; y = CGFloat(height) - margin - bounds.maxY
        case .topLeft: x = margin - bounds.minX; y = CGFloat(height) - margin - bounds.maxY
        case .center: x = (CGFloat(width) - bounds.width) / 2 - bounds.minX
            y = (CGFloat(height) - bounds.height) / 2 - bounds.minY
        }
        context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.15,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: alpha * 0.6))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}

public struct ExportOptions: Codable, Equatable, Sendable {
    public static let defaultFilenameTemplate = "{원본}-edited"

    public var maxPixel: Int?
    public var quality: Double
    public var includeLocation: Bool
    public var filenameTemplate: String
    public var watermark: Watermark?

    public init(maxPixel: Int? = nil, quality: Double = 0.85, includeLocation: Bool = false,
                filenameTemplate: String = ExportOptions.defaultFilenameTemplate, watermark: Watermark? = nil) {
        self.maxPixel = maxPixel
        self.quality = quality
        self.includeLocation = includeLocation
        self.filenameTemplate = filenameTemplate
        self.watermark = watermark
    }

    /// `{원본}` 원본 파일 이름, `{날짜}` 촬영일(yyyy-MM-dd), `{시간}` 촬영 시각(HHmmss), `{번호}` 이번 내보내기의 순번(001부터).
    /// 파일 이름에 쓸 수 없는 `/`와 `:`는 `-`로 바꾸고, 결과가 비면 원본 이름을 쓴다.
    public static func baseName(template: String, sourceURL: URL, capturedAt: Date?, sequence: Int,
                                calendar: Calendar = .current) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date: String, time: String
        if let capturedAt {
            formatter.dateFormat = "yyyy-MM-dd"
            date = formatter.string(from: capturedAt)
            formatter.dateFormat = "HHmmss"
            time = formatter.string(from: capturedAt)
        } else {
            date = "날짜없음"
            time = "시간없음"
        }
        let name = template
            .replacingOccurrences(of: "{원본}", with: stem)
            .replacingOccurrences(of: "{날짜}", with: date)
            .replacingOccurrences(of: "{시간}", with: time)
            .replacingOccurrences(of: "{번호}", with: String(format: "%03d", sequence))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return visible.isEmpty ? stem : String(name.prefix(200))
    }
}

public struct ExportPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var options: ExportOptions

    public init(id: UUID = UUID(), name: String, options: ExportOptions) {
        self.id = id
        self.name = name
        self.options = options
    }
}
