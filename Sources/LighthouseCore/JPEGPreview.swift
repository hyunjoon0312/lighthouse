import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

public struct JPEGPreview: @unchecked Sendable {
    public let data: Data
    public let image: CGImage

    public var width: Int { image.width }
    public var height: Int { image.height }

    public init(data: Data, image: CGImage) {
        self.data = data
        self.image = image
    }
}

public extension ImagePipeline {
    func prepareJPEG(url: URL, edits: EditSettings, maxPixel: Int?,
                     quality: Double, includeLocation: Bool = false, watermark: Watermark? = nil,
                     keywords: [String] = [], caption: String = "") throws -> JPEGPreview {
        try prepareExport(url: url, edits: edits,
                          options: ExportOptions(maxPixel: maxPixel, quality: quality, includeLocation: includeLocation,
                                                 watermark: watermark),
                          keywords: keywords, caption: caption)
    }

    /// `options`의 형식·색 공간·크기로 그려 파일 데이터로 만든다. 돌려받은 이미지는 그 데이터를 다시 읽은 것이다.
    func prepareExport(url: URL, edits: EditSettings, options: ExportOptions,
                       keywords: [String] = [], caption: String = "") throws -> JPEGPreview {
        guard options.quality.isFinite else { throw ImagePipelineError.invalidJPEGQuality }
        let composition = try composedForExport(url: url, edits: edits, maxPixel: options.maxPixel)
        var rendered = try outputImage(composition.image, url: url, format: options.format.renderFormat,
                                       colorSpace: options.colorSpace.cgColorSpace)
        if let watermark = options.watermark {
            guard let marked = watermark.applied(to: rendered) else { throw ImagePipelineError.exportFailed(url) }
            rendered = marked
        }
        if options.includesHDR, options.format.supportsHDR,
           let gain = try hdrGain(for: composition, url: url, edits: edits, maxPixel: options.maxPixel, scale: 1) {
            let metadata = Self.exportMetadata(from: url, width: rendered.width, height: rendered.height,
                                               includeLocation: options.includeLocation, keywords: keywords,
                                               caption: caption, colorSpace: options.colorSpace)
            return try hdrExport(rendered, gain: gain, metadata: metadata, options: options, url: url)
        }
        if options.format == .tiff16 {
            // TIFF는 알파가 있으면 채널을 하나 더 저장한다(24MP 183MB → 137MB). HEIF는 알파를 저장하지 않고,
            // 불투명하게 다시 그리면 오히려 커져서(9.5MB → 35.6MB) 그대로 둔다.
            guard let opaque = Self.opaque(rendered) else { throw ImagePipelineError.exportFailed(url) }
            rendered = opaque
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, options.format.type.identifier as CFString, 1, nil
        ) else {
            throw ImagePipelineError.exportFailed(url)
        }
        var properties = Self.exportMetadata(from: url, width: rendered.width, height: rendered.height,
                                             includeLocation: options.includeLocation, keywords: keywords,
                                             caption: caption, colorSpace: options.colorSpace)
        if options.format.usesQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, options.quality))
        }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagePipelineError.exportFailed(url)
        }
        let data = encoded as Data
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagePipelineError.invalidJPEGData
        }
        return JPEGPreview(data: data, image: decoded)
    }

    /// SDR 결과(워터마크 포함)를 기본 이미지로, 배율을 곱한 HDR 이미지로 게인 맵을 만들어 JPEG·HEIF(10비트)로 쓴다.
    /// HDR을 모르는 앱·화면에서는 기본 이미지(SDR)가 보인다. 촬영 정보·키워드는 기본 이미지의 속성으로 넣는다.
    private func hdrExport(_ standard: CGImage, gain: CIImage, metadata: [CFString: Any], options: ExportOptions,
                           url: URL) throws -> JPEGPreview {
        let space = options.colorSpace.cgColorSpace
        let base = CIImage(cgImage: standard, options: [.properties: metadata as NSDictionary])
        let hdr = Self.applying(gain, to: CIImage(cgImage: standard))
        var representation: [CIImageRepresentationOption: Any] = [.hdrImage: hdr]
        representation[CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)] =
            min(1, max(0, options.quality))
        let encoded: Data?
        switch options.format {
        case .jpeg: encoded = context.jpegRepresentation(of: base, colorSpace: space, options: representation)
        case .heif: encoded = try context.heif10Representation(of: base, colorSpace: space, options: representation)
        case .tiff16: encoded = nil
        }
        guard let data = encoded, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagePipelineError.exportFailed(url)
        }
        return JPEGPreview(data: data, image: decoded)
    }

    private static func opaque(_ image: CGImage) -> CGImage? {
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: image.bitsPerComponent > 8 ? 16 : 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 원본의 촬영 메타데이터를 옮긴다. 픽셀은 이미 회전되어 있으므로 방향은 1로 둔다.
    /// 앱에서 붙인 키워드와 설명은 IPTC에 넣는다(원본에 있던 값보다 우선).
    static func exportMetadata(from url: URL, width: Int, height: Int, includeLocation: Bool,
                               keywords: [String] = [], caption: String = "",
                               colorSpace: ExportColorSpace = .sRGB) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var metadata: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            // EXIF 색 공간은 sRGB(1)만 표시할 수 있고 나머지는 ‘보정 안 됨’(65535)이며 실제 색은 내장 프로필을 따른다.
            exif[kCGImagePropertyExifColorSpace] = colorSpace == .sRGB ? 1 : 65535
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        let tiffKeys = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                        kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
                        kCGImagePropertyTIFFImageDescription]
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1]
        if let originalTIFF = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for key in tiffKeys { tiff[key] = originalTIFF[key] }
        }
        metadata[kCGImagePropertyTIFFDictionary] = tiff
        for key in [kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary] {
            if let dictionary = original[key] { metadata[key] = dictionary }
        }
        if !keywords.isEmpty || !caption.isEmpty {
            var iptc = metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = keywords }
            if !caption.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract] = caption }
            metadata[kCGImagePropertyIPTCDictionary] = iptc
        }
        if includeLocation, let gps = original[kCGImagePropertyGPSDictionary] {
            metadata[kCGImagePropertyGPSDictionary] = gps
        }
        return metadata
    }

    func writeJPEG(_ data: Data, sourceURL: URL, to directory: URL) throws -> URL {
        try writeJPEG(data, baseName: sourceURL.deletingPathExtension().lastPathComponent + "-edited", to: directory)
    }

    func writeJPEG(_ data: Data, baseName: String, to directory: URL) throws -> URL {
        try writeExport(data, format: .jpeg, baseName: baseName, to: directory)
    }

    /// `baseName.<확장자>`로 쓴다. 이미 있으면 `-2`, `-3`을 붙이며 기존 파일은 덮어쓰지 않는다.
    func writeExport(_ data: Data, format: ExportFormat, baseName: String, to directory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImagePipelineError.invalidDirectory(directory)
        }
        guard data.count >= 2, format != .jpeg || (data[data.startIndex] == 0xff &&
                                                    data[data.index(after: data.startIndex)] == 0xd8),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              (CGImageSourceGetType(source) as String?).flatMap(UTType.init)?.conforms(to: format.type) == true,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ImagePipelineError.invalidJPEGData
        }

        let base = baseName
        for number in 1...10_000 {
            let suffix = number == 1 ? "" : "-\(number)"
            let output = directory.appendingPathComponent(base + suffix + "." + format.fileExtension)
            let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw ImagePipelineError.exportFailed(output)
            }
            do {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try handle.write(contentsOf: data)
                try handle.close()
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw ImagePipelineError.exportFailed(output)
            }
        }
        throw ImagePipelineError.exportFailed(directory)
    }
}
