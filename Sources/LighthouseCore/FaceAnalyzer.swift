import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum FaceAnalyzerError: LocalizedError {
    case detectionFailed(String)
    case alignmentFailed
    case imageConversionFailed
    case modelResourceMissing
    case modelCompilationFailed(String)
    case modelLoadFailed(String)
    case predictionFailed(String)
    case invalidModelOutput
    case thumbnailEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .detectionFailed(let reason): "얼굴을 찾을 수 없습니다: \(reason)"
        case .alignmentFailed: "얼굴 특징점을 정렬할 수 없습니다."
        case .imageConversionFailed: "얼굴 이미지를 변환할 수 없습니다."
        case .modelResourceMissing: "앱에 얼굴 분석 모델이 포함되어 있지 않습니다."
        case .modelCompilationFailed(let reason): "얼굴 분석 모델을 준비할 수 없습니다: \(reason)"
        case .modelLoadFailed(let reason): "얼굴 분석 모델을 불러올 수 없습니다: \(reason)"
        case .predictionFailed(let reason): "얼굴 특징을 계산할 수 없습니다: \(reason)"
        case .invalidModelOutput: "얼굴 분석 모델의 출력이 올바르지 않습니다."
        case .thumbnailEncodingFailed: "얼굴 미리보기를 만들 수 없습니다."
        }
    }
}

public final class FaceAnalyzer: @unchecked Sendable {
    private static let alignedSize = 112
    private static let outputRectangle = CGRect(x: 0, y: 0, width: alignedSize, height: alignedSize)

    private let lock = NSLock()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context: CIContext
    private var model: MLModel?
    private var compiledModelURL: URL?

    public init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    deinit {
        if let compiledModelURL {
            try? FileManager.default.removeItem(at: compiledModelURL)
        }
    }

    public func analyze(url: URL, pipeline: ImagePipeline) throws -> [DetectedFace] {
        try withLock {
            let image = try pipeline.thumbnail(for: url, maxPixel: 2048)
            let request = VNDetectFaceLandmarksRequest()
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            } catch {
                throw FaceAnalyzerError.detectionFailed(error.localizedDescription)
            }

            let observations = request.results ?? []
            return try observations.compactMap { observation in
                guard observation.confidence >= 0.6,
                      observation.boundingBox.width * CGFloat(image.width) >= 40,
                      observation.boundingBox.height * CGFloat(image.height) >= 40,
                      let landmarks = landmarkPoints(for: observation, image: image) else { return nil }

                let aligned: CGImage
                do {
                    aligned = try alignedFaceLocked(image, landmarks: landmarks)
                } catch is FaceAlignment.Error {
                    return nil
                }
                let embedding = try embeddingLocked(forAlignedFace: aligned)
                let thumbnail = try jpegData(for: aligned)
                guard let bounds = normalizedBounds(observation.boundingBox) else { return nil }
                return DetectedFace(
                    bounds: bounds,
                    embedding: embedding,
                    thumbnailJPEG: thumbnail
                )
            }
        }
    }

    func alignedFace(_ image: CGImage, landmarks: [CGPoint]) throws -> CGImage {
        try withLock { try alignedFaceLocked(image, landmarks: landmarks) }
    }

    func inputArray(forAlignedFace image: CGImage) throws -> MLMultiArray {
        guard image.width == Self.alignedSize, image.height == Self.alignedSize else {
            throw FaceAnalyzerError.imageConversionFailed
        }
        let pixelCount = Self.alignedSize * Self.alignedSize
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmapContext = CGContext(
                data: buffer.baseAddress,
                width: Self.alignedSize,
                height: Self.alignedSize,
                bitsPerComponent: 8,
                bytesPerRow: Self.alignedSize * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            bitmapContext.draw(image, in: Self.outputRectangle)
            return true
        }
        guard rendered else { throw FaceAnalyzerError.imageConversionFailed }

        let input: MLMultiArray
        do {
            input = try MLMultiArray(
                shape: [3, NSNumber(value: Self.alignedSize), NSNumber(value: Self.alignedSize)],
                dataType: .float32
            )
        } catch {
            throw FaceAnalyzerError.imageConversionFailed
        }
        let channelStride = input.strides[0].intValue
        let rowStride = input.strides[1].intValue
        let columnStride = input.strides[2].intValue
        let values = input.dataPointer.bindMemory(to: Float32.self, capacity: input.count)
        for y in 0..<Self.alignedSize {
            for x in 0..<Self.alignedSize {
                let pixel = (y * Self.alignedSize + x) * 4
                let offset = y * rowStride + x * columnStride
                values[offset] = Float32(rgba[pixel])
                values[channelStride + offset] = Float32(rgba[pixel + 1])
                values[channelStride * 2 + offset] = Float32(rgba[pixel + 2])
            }
        }
        return input
    }

    func embedding(forAlignedFace image: CGImage) throws -> [Float] {
        try withLock { try embeddingLocked(forAlignedFace: image) }
    }

    private func alignedFaceLocked(_ image: CGImage, landmarks: [CGPoint]) throws -> CGImage {
        let transform = try FaceAlignment.transform(
            source: landmarks,
            target: FaceAlignment.canonicalPoints
        )
        let transparent = CIImage(color: .clear).cropped(to: Self.outputRectangle)
        let transformed = CIImage(cgImage: image).transformed(by: transform)
            .composited(over: transparent)
            .cropped(to: Self.outputRectangle)
        guard let output = context.createCGImage(
            transformed,
            from: Self.outputRectangle,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else { throw FaceAnalyzerError.alignmentFailed }
        return output
    }

    private func embeddingLocked(forAlignedFace image: CGImage) throws -> [Float] {
        let input = try inputArray(forAlignedFace: image)
        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: ["data": input])
        } catch {
            throw FaceAnalyzerError.predictionFailed(error.localizedDescription)
        }
        let prediction: MLFeatureProvider
        do {
            prediction = try modelLocked().prediction(from: provider)
        } catch let error as FaceAnalyzerError {
            throw error
        } catch {
            throw FaceAnalyzerError.predictionFailed(error.localizedDescription)
        }
        guard let output = prediction.featureValue(for: "fc1")?.multiArrayValue,
              output.count == 128 else { throw FaceAnalyzerError.invalidModelOutput }
        let values = (0..<output.count).map { output[$0].floatValue }
        guard values.allSatisfy(\.isFinite) else { throw FaceAnalyzerError.invalidModelOutput }
        let magnitudeSquared = values.reduce(0.0) { partial, value in
            partial + Double(value) * Double(value)
        }
        guard magnitudeSquared.isFinite, magnitudeSquared > 0 else {
            throw FaceAnalyzerError.invalidModelOutput
        }
        let magnitude = Float(sqrt(magnitudeSquared))
        let normalized = values.map { $0 / magnitude }
        guard normalized.allSatisfy(\.isFinite) else { throw FaceAnalyzerError.invalidModelOutput }
        return normalized
    }

    private func modelLocked() throws -> MLModel {
        if let model { return model }
        let sourceURL = try modelSourceURL()
        let compiledURL: URL
        do {
            compiledURL = try MLModel.compileModel(at: sourceURL)
        } catch {
            throw FaceAnalyzerError.modelCompilationFailed(error.localizedDescription)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        do {
            let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
            compiledModelURL = compiledURL
            model = loaded
            return loaded
        } catch {
            try? FileManager.default.removeItem(at: compiledURL)
            throw FaceAnalyzerError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func modelSourceURL() throws -> URL {
        if let resourcesDirectory = Bundle.main.resourceURL,
           let packaged = Self.packagedModelURL(in: resourcesDirectory) {
            return packaged
        }
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            throw FaceAnalyzerError.modelResourceMissing
        }
        guard let development = Bundle.module.url(
            forResource: "SFace",
            withExtension: "mlmodel",
            subdirectory: "Resources"
        ) else { throw FaceAnalyzerError.modelResourceMissing }
        return development
    }

    static func packagedModelURL(in resourcesDirectory: URL) -> URL? {
        let bundleURL = resourcesDirectory
            .appendingPathComponent("Lighthouse_LighthouseCore.bundle", isDirectory: true)
        guard let resourceBundle = Bundle(url: bundleURL) else { return nil }
        return resourceBundle.url(
            forResource: "SFace",
            withExtension: "mlmodel",
            subdirectory: "Resources"
        )
    }

    private func landmarkPoints(for observation: VNFaceObservation, image: CGImage) -> [CGPoint]? {
        guard let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let outerLips = landmarks.outerLips else { return nil }

        func imagePoints(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.normalizedPoints.map { point in
                CGPoint(
                    x: (observation.boundingBox.minX + CGFloat(point.x) * observation.boundingBox.width)
                        * CGFloat(image.width),
                    y: (observation.boundingBox.minY + CGFloat(point.y) * observation.boundingBox.height)
                        * CGFloat(image.height)
                )
            }
        }
        guard let leftCenter = mean(imagePoints(leftEye)),
              let rightCenter = mean(imagePoints(rightEye)) else { return nil }
        let eyes = [leftCenter, rightCenter].sorted { $0.x < $1.x }
        guard hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y) >= 10 else { return nil }

        let nosePoint: CGPoint?
        if let noseCrest = landmarks.noseCrest {
            nosePoint = imagePoints(noseCrest).min { $0.y < $1.y }
        } else if let nose = landmarks.nose {
            nosePoint = mean(imagePoints(nose))
        } else {
            nosePoint = nil
        }
        let mouth = imagePoints(outerLips)
        guard let nosePoint,
              let leftMouth = mouth.min(by: { $0.x < $1.x }),
              let rightMouth = mouth.max(by: { $0.x < $1.x }) else { return nil }
        let points = eyes + [nosePoint, leftMouth, rightMouth]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              (try? FaceAlignment.transform(source: points, target: FaceAlignment.canonicalPoints)) != nil else {
            return nil
        }
        return points
    }

    private func mean(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func normalizedBounds(_ boundingBox: CGRect) -> FaceBounds? {
        let minimumX = max(0, min(1, boundingBox.minX))
        let maximumX = max(0, min(1, boundingBox.maxX))
        let minimumY = max(0, min(1, boundingBox.minY))
        let maximumY = max(0, min(1, boundingBox.maxY))
        guard maximumX > minimumX, maximumY > minimumY else { return nil }
        return FaceBounds(
            x: Double(minimumX),
            y: Double(1 - maximumY),
            width: Double(maximumX - minimumX),
            height: Double(maximumY - minimumY)
        )
    }

    private func jpegData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw FaceAnalyzerError.thumbnailEncodingFailed }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw FaceAnalyzerError.thumbnailEncodingFailed
        }
        return data as Data
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
