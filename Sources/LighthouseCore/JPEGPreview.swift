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
                     quality: Double) throws -> JPEGPreview {
        guard quality.isFinite else { throw ImagePipelineError.invalidJPEGQuality }
        let rendered = try render(url: url, edits: edits, maxPixel: maxPixel)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ImagePipelineError.exportFailed(url)
        }
        CGImageDestinationAddImage(
            destination,
            rendered,
            [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))] as CFDictionary
        )
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

    func writeJPEG(_ data: Data, sourceURL: URL, to directory: URL) throws -> URL {
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

        let base = sourceURL.deletingPathExtension().lastPathComponent + "-edited"
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
