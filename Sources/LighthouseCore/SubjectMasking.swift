import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public extension ImagePipeline {
    func subjectMask(url: URL) throws -> RasterMask {
        let rendered = try render(url: url, edits: .neutral, maxPixel: 1_536)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: rendered, orientation: .up)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else {
                throw ImagePipelineError.subjectNotFound
            }
            let pixelBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
            let maskImage = CIImage(cvPixelBuffer: pixelBuffer)
            let bounds = CGRect(x: 0, y: 0,
                                width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
            let gray = CGColorSpace(name: CGColorSpace.linearGray)!
            guard let mask = context.createCGImage(maskImage, from: bounds,
                                                   format: .L8, colorSpace: gray) else {
                throw ImagePipelineError.subjectMaskFailed("마스크 렌더 실패")
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encoded, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw ImagePipelineError.subjectMaskFailed("PNG 인코더 생성 실패")
            }
            CGImageDestinationAddImage(destination, mask, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ImagePipelineError.subjectMaskFailed("PNG 인코딩 실패")
            }
            let data = encoded as Data
            guard data.count <= Self.maximumMaskBytes else {
                throw ImagePipelineError.invalidMaskData("마스크 데이터가 8 MiB를 초과합니다")
            }
            return RasterMask(width: mask.width, height: mask.height, pngData: data)
        } catch let error as ImagePipelineError {
            throw error
        } catch {
            throw ImagePipelineError.subjectMaskFailed(error.localizedDescription)
        }
    }
}
