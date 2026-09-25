import CoreGraphics
import CoreImage
import CoreText
import Foundation
import UniformTypeIdentifiers

/// 내보내기 파일 형식. JPEG은 8비트, HEIF는 16비트로 그려 10비트로 저장하고, TIFF는 압축하지 않은 16비트 RGB다.
/// (16비트 사진에서 LZW는 오히려 커지고 ZIP은 24MP에 11초가 걸려 압축하지 않는다.)
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, heif, tiff16

    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heif: "HEIF (10비트)"
        case .tiff16: "TIFF (16비트)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heif: "heic"
        case .tiff16: "tif"
        }
    }

    public var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heif: .heic
        case .tiff16: .tiff
        }
    }

    /// 품질 설정을 쓰는 손실 압축인지.
    public var usesQuality: Bool { self != .tiff16 }

    var renderFormat: CIFormat { self == .jpeg ? .RGBA8 : .RGBA16 }
}

/// 내보내기 색 공간. Display P3는 RAW의 넓은 색을 남기지만 P3를 모르는 곳에서는 색이 옅게 보일 수 있다.
public enum ExportColorSpace: String, Codable, CaseIterable, Sendable {
    case sRGB, displayP3

    public var title: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }

    public var cgColorSpace: CGColorSpace {
        CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
    }
}

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
        // 16비트 출력(HEIF·TIFF)은 16비트로 그려 계조를 잃지 않는다.
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: image.bitsPerComponent > 8 ? 16 : 8, bytesPerRow: 0,
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
    public var format: ExportFormat
    public var colorSpace: ExportColorSpace

    public init(maxPixel: Int? = nil, quality: Double = 0.85, includeLocation: Bool = false,
                filenameTemplate: String = ExportOptions.defaultFilenameTemplate, watermark: Watermark? = nil,
                format: ExportFormat = .jpeg, colorSpace: ExportColorSpace = .sRGB) {
        self.maxPixel = maxPixel
        self.quality = quality
        self.includeLocation = includeLocation
        self.filenameTemplate = filenameTemplate
        self.watermark = watermark
        self.format = format
        self.colorSpace = colorSpace
    }

    private enum CodingKeys: String, CodingKey {
        case maxPixel, quality, includeLocation, filenameTemplate, watermark, format, colorSpace
    }

    /// 형식·색 공간이 없던 예전 설정과 프리셋은 JPEG·sRGB로 읽는다.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxPixel = try container.decodeIfPresent(Int.self, forKey: .maxPixel)
        quality = try container.decode(Double.self, forKey: .quality)
        includeLocation = try container.decode(Bool.self, forKey: .includeLocation)
        filenameTemplate = try container.decode(String.self, forKey: .filenameTemplate)
        watermark = try container.decodeIfPresent(Watermark.self, forKey: .watermark)
        format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .jpeg
        colorSpace = try container.decodeIfPresent(ExportColorSpace.self, forKey: .colorSpace) ?? .sRGB
    }

    /// `{원본}` 원본 파일 이름, `{날짜}` 촬영일(yyyy-MM-dd), `{시간}` 촬영 시각(HHmmss), `{번호}` 이번 내보내기의 순번(001부터),
    /// `{사본}` 가상 사본이면 `-사본1`처럼 사본 이름(원래 항목은 빈칸). 규칙에 `{사본}`이 없으면 사본은 이름 끝에 붙인다.
    /// 파일 이름에 쓸 수 없는 `/`와 `:`는 `-`로 바꾸고, 결과가 비면 원본 이름을 쓴다.
    public static func baseName(template: String, sourceURL: URL, capturedAt: Date?, sequence: Int,
                                copyName: String? = nil, calendar: Calendar = .current) -> String {
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
        let copy = copyName.map { "-" + $0.replacingOccurrences(of: " ", with: "") } ?? ""
        let name = (template.contains("{사본}") ? template : template + "{사본}")
            .replacingOccurrences(of: "{사본}", with: copy)
            .replacingOccurrences(of: "{원본}", with: stem)
            .replacingOccurrences(of: "{날짜}", with: date)
            .replacingOccurrences(of: "{시간}", with: time)
            .replacingOccurrences(of: "{번호}", with: String(format: "%03d", sequence))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !visible.isEmpty else { return stem }
        // 파일 이름은 UTF-8 255바이트까지라 번호 접미사와 확장자 자리를 남기고 200바이트에서 자른다(한글은 글자당 3바이트).
        var trimmed = name
        while trimmed.utf8.count > 200 { trimmed.removeLast() }
        return trimmed
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
