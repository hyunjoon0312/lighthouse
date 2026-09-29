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
            return try encodedRasterMask(mask)
        } catch let error as ImagePipelineError {
            throw error
        } catch {
            throw ImagePipelineError.subjectMaskFailed(error.localizedDescription)
        }
    }
}
