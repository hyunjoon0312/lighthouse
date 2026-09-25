import CoreGraphics
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
        guard quality.isFinite else { throw ImagePipelineError.invalidJPEGQuality }
        var rendered = try render(url: url, edits: edits, maxPixel: maxPixel)
        if let watermark {
            guard let marked = watermark.applied(to: rendered) else { throw ImagePipelineError.exportFailed(url) }
            rendered = marked
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ImagePipelineError.exportFailed(url)
        }
        var properties = Self.exportMetadata(from: url, width: rendered.width, height: rendered.height,
                                             includeLocation: includeLocation, keywords: keywords, caption: caption)
        properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality))
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

    /// 원본의 촬영 메타데이터를 옮긴다. 픽셀은 이미 회전되어 있으므로 방향은 1로 둔다.
    /// 앱에서 붙인 키워드와 설명은 IPTC에 넣는다(원본에 있던 값보다 우선).
    static func exportMetadata(from url: URL, width: Int, height: Int, includeLocation: Bool,
                               keywords: [String] = [], caption: String = "") -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var metadata: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            exif[kCGImagePropertyExifColorSpace] = 1
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

    /// `baseName.jpg`로 쓴다. 이미 있으면 `-2`, `-3`을 붙이며 기존 파일은 덮어쓰지 않는다.
    func writeJPEG(_ data: Data, baseName: String, to directory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImagePipelineError.invalidDirectory(directory)
        }
        guard data.count >= 2, data[data.startIndex] == 0xff,
              data[data.index(after: data.startIndex)] == 0xd8,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ImagePipelineError.invalidJPEGData
        }

        let base = baseName
        for number in 1...10_000 {
            let suffix = number == 1 ? "" : "-\(number)"
            let output = directory.appendingPathComponent(base + suffix + ".jpg")
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
