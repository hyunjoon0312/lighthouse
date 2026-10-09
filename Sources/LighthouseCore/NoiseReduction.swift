import Accelerate
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation

public enum NoiseReductionMode: String, Codable, CaseIterable, Sendable {
    case off
    case standard
    case ai
}

public struct NoiseReductionSettings: Codable, Equatable, Sendable {
    public var mode: NoiseReductionMode
    public var amount: Double

    public init(mode: NoiseReductionMode = .off, amount: Double = 0.35) {
        self.mode = mode
        self.amount = amount
    }

    public var isActive: Bool { mode != .off && amount > 0 }

    private enum CodingKeys: String, CodingKey {
        case mode, amount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(NoiseReductionMode.self, forKey: .mode)
        amount = try container.decode(Double.self, forKey: .amount)
        guard amount.isFinite, (0...1).contains(amount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Noise reduction amount must be finite and between 0 and 1."
            )
        }
    }
}

enum NoiseReductionError: LocalizedError {
    case invalidAmount
    case imageTooLarge
    case invalidImageSize
    case renderFailed
    case modelResourceMissing
    case modelCompilationFailed(String)
    case modelLoadFailed(String)
    case predictionFailed(String)
    case invalidModelOutput

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "노이즈 감소 강도는 0에서 1 사이의 유한한 값이어야 합니다."
        case .imageTooLarge: "AI 노이즈 감소는 6,400만 픽셀 이하의 이미지에서 사용할 수 있습니다."
        case .invalidImageSize: "노이즈 감소를 적용할 이미지 크기가 올바르지 않습니다."
        case .renderFailed: "AI 노이즈 감소용 이미지 픽셀을 읽을 수 없습니다."
        case .modelResourceMissing: "AI 노이즈 감소 모델을 찾을 수 없습니다."
        case .modelCompilationFailed(let reason): "AI 노이즈 감소 모델을 준비할 수 없습니다: \(reason)"
        case .modelLoadFailed(let reason): "AI 노이즈 감소 모델을 불러올 수 없습니다: \(reason)"
        case .predictionFailed(let reason): "AI 노이즈 감소 처리에 실패했습니다: \(reason)"
        case .invalidModelOutput: "AI 노이즈 감소 모델의 출력 형식이 올바르지 않습니다."
        }
    }
}

final class NoiseReductionService: @unchecked Sendable {
    static let shared = NoiseReductionService()

    static let maximumPixels = 64_000_000
    static let coreSize = 256
    static let halo = 32
    static let tileSize = coreSize + halo * 2
    static let modelSize = tileSize / 2
    static let engineVersion = 1

    struct CacheKey: Equatable {
        let value: String

        init(url: URL, attributes: [FileAttributeKey: Any], edits: EditSettings, width: Int, height: Int) {
            self.init(url: url, attributes: attributes, edits: edits, settings: edits.noiseReduction,
                      cacheContext: "", width: width, height: height)
        }

        init(url: URL, attributes: [FileAttributeKey: Any], edits: EditSettings,
             settings: NoiseReductionSettings, cacheContext: String, width: Int, height: Int) {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            var components = [
                "ffdnet-v\(NoiseReductionService.engineVersion)", path, String(size), String(modified),
            ]
            if ImagePipeline.isRAW(url) {
                components += [String(describing: edits.rawDevelop), String(edits.exposure),
                               String(edits.temperatureShift), String(edits.tintShift)]
                if let whiteBalance = edits.whiteBalance { components.append(String(describing: whiteBalance)) }
            }
            components += [String(describing: edits.flicker), cacheContext,
                           settings.mode.rawValue, String(settings.amount),
                           "\(width)x\(height)"]
            value = components.joined(separator: "|")
        }
    }

    private let lock = NSLock()
    private var model: MLModel?
    private var compiledModelURL: URL?
    private var cached: (key: CacheKey, image: CIImage)?

    deinit {
        if let compiledModelURL { try? FileManager.default.removeItem(at: compiledModelURL) }
    }

    func apply(to image: CIImage, url: URL, edits: EditSettings, context: CIContext,
               colorSpace: CGColorSpace) throws -> CIImage {
        try apply(to: image, url: url, edits: edits, settings: edits.noiseReduction,
                  context: context, colorSpace: colorSpace)
    }

    func apply(to image: CIImage, url: URL, edits: EditSettings, settings: NoiseReductionSettings,
               cacheContext: String = "", context: CIContext, colorSpace: CGColorSpace) throws -> CIImage {
        try withLock {
            let extent = image.extent
            guard extent.origin.x.isFinite, extent.origin.y.isFinite,
                  extent.width.isFinite, extent.height.isFinite,
                  extent.width > 0, extent.height > 0 else { throw NoiseReductionError.invalidImageSize }
            guard extent.width <= CGFloat(Self.maximumPixels),
                  extent.height <= CGFloat(Self.maximumPixels),
                  extent.width * extent.height <= CGFloat(Self.maximumPixels) else {
                throw NoiseReductionError.imageTooLarge
            }
            let width = Int(extent.width.rounded())
            let height = Int(extent.height.rounded())
            guard width > 0, height > 0,
                  abs(CGFloat(width) - extent.width) < 0.001,
                  abs(CGFloat(height) - extent.height) < 0.001 else {
                throw NoiseReductionError.invalidImageSize
            }
            let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let key = CacheKey(url: url, attributes: attributes, edits: edits, settings: settings,
                               cacheContext: cacheContext, width: width, height: height)
            if let cached, cached.key == key { return cached.image }
            let result = try infer(image: image, width: width, height: height, context: context,
                                   colorSpace: colorSpace, sigma: Float(settings.amount * 75 / 255))
            cached = (key, result)
            return result
        }
    }

    private func infer(image: CIImage, width: Int, height: Int, context: CIContext,
                       colorSpace: CGColorSpace, sigma: Float) throws -> CIImage {
        let model = try modelLocked()
        let tileSize = Self.tileSize
        let floatRowBytes = tileSize * 4 * MemoryLayout<Float>.size
        var tileBytes = Data(count: floatRowBytes * tileSize)
        var output = [UInt16](repeating: 0, count: width * height * 4)
        let clamped = image.clampedToExtent()

        for coreY in stride(from: 0, to: height, by: Self.coreSize) {
            for coreX in stride(from: 0, to: width, by: Self.coreSize) {
                let tileX = image.extent.minX + CGFloat(coreX - Self.halo)
                let tileY = image.extent.maxY - CGFloat(coreY - Self.halo + tileSize)
                let tileLength = CGFloat(tileSize)
                let tileRect = CGRect(
                    x: tileX,
                    y: tileY,
                    width: tileLength,
                    height: tileLength
                )
                tileBytes.withUnsafeMutableBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    context.render(clamped, toBitmap: base, rowBytes: floatRowBytes,
                                   bounds: tileRect, format: .RGBAf, colorSpace: colorSpace)
                }
                try autoreleasepool {
                    let input = try inputArray(from: tileBytes, rowBytes: floatRowBytes, sigma: sigma)
                    let provider: MLDictionaryFeatureProvider
                    do {
                        provider = try MLDictionaryFeatureProvider(dictionary: ["input": input])
                    } catch {
                        throw NoiseReductionError.predictionFailed(error.localizedDescription)
                    }
                    let prediction: MLFeatureProvider
                    do {
                        prediction = try model.prediction(from: provider)
                    } catch {
                        throw NoiseReductionError.predictionFailed(error.localizedDescription)
                    }
                    guard let predictionArray = prediction.featureValue(for: "output")?.multiArrayValue,
                          predictionArray.dataType == .float32,
                          predictionArray.shape.map(\.intValue) == [12, Self.modelSize, Self.modelSize] else {
                        throw NoiseReductionError.invalidModelOutput
                    }
                    try writeCore(source: tileBytes, rowBytes: floatRowBytes, prediction: predictionArray,
                                  coreX: coreX, coreY: coreY, width: width, height: height, output: &output)
                }
            }
        }

        let data = output.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<UInt16>.size,
                       size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: colorSpace)
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            .cropped(to: image.extent)
    }

    func inputArray(from data: Data, rowBytes: Int, sigma: Float) throws -> MLMultiArray {
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: [13, NSNumber(value: Self.modelSize), NSNumber(value: Self.modelSize)],
                                     dataType: .float32)
        } catch {
            throw NoiseReductionError.predictionFailed(error.localizedDescription)
        }
        let channelStride = array.strides[0].intValue
        let rowStride = array.strides[1].intValue
        let columnStride = array.strides[2].intValue
        let destination = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw NoiseReductionError.renderFailed }
            for y in 0..<Self.modelSize {
                for x in 0..<Self.modelSize {
                    let outputOffset = y * rowStride + x * columnStride
                    for channel in 0..<3 {
                        for dy in 0..<2 {
                            for dx in 0..<2 {
                                let pixel = base.advanced(by: (y * 2 + dy) * rowBytes)
                                    .assumingMemoryBound(to: Float.self)
                                let component = pixel[(x * 2 + dx) * 4 + channel]
                                let alpha = pixel[(x * 2 + dx) * 4 + 3]
                                let unpremultiplied = alpha > 0 ? component / alpha : 0
                                let plane = 4 * channel + 2 * dy + dx
                                destination[plane * channelStride + outputOffset] = min(1, max(0, unpremultiplied))
                            }
                        }
                    }
                    destination[12 * channelStride + outputOffset] = sigma
                }
            }
        }
        return array
    }

    func writeCore(source: Data, rowBytes: Int, prediction: MLMultiArray,
                   coreX: Int, coreY: Int, width: Int, height: Int,
                   output: inout [UInt16]) throws {
        let channelStride = prediction.strides[0].intValue
        let rowStride = prediction.strides[1].intValue
        let columnStride = prediction.strides[2].intValue
        let predicted = prediction.dataPointer.bindMemory(to: Float.self, capacity: prediction.count)
        let copyWidth = min(Self.coreSize, width - coreX)
        let copyHeight = min(Self.coreSize, height - coreY)
        var tile = [Float](repeating: 0, count: copyWidth * copyHeight * 4)
        try source.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw NoiseReductionError.renderFailed }
            for y in 0..<copyHeight {
                for x in 0..<copyWidth {
                    let tileX = x + Self.halo
                    let tileY = y + Self.halo
                    let sourcePixel = base.advanced(by: tileY * rowBytes).assumingMemoryBound(to: Float.self)
                    let sourceOffset = tileX * 4
                    let alpha = sourcePixel[sourceOffset + 3]
                    let modelY = tileY / 2
                    let modelX = tileX / 2
                    let phase = 2 * (tileY & 1) + (tileX & 1)
                    let modelOffset = modelY * rowStride + modelX * columnStride
                    let tileOffset = (y * copyWidth + x) * 4
                    for channel in 0..<3 {
                        let original = alpha > 0 ? sourcePixel[sourceOffset + channel] / alpha : 0
                        let clipped = min(1, max(0, original))
                        let value = original + predicted[(4 * channel + phase) * channelStride + modelOffset] - clipped
                        guard value.isFinite else { throw NoiseReductionError.invalidModelOutput }
                        tile[tileOffset + channel] = value * alpha
                    }
                    tile[tileOffset + 3] = alpha
                }
            }
        }
        let error = tile.withUnsafeMutableBytes { (sourceBytes: UnsafeMutableRawBufferPointer) -> vImage_Error in
            output.withUnsafeMutableBytes { (destinationBytes: UnsafeMutableRawBufferPointer) -> vImage_Error in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else { return kvImageNullPointerArgument }
                var sourceBuffer = vImage_Buffer(
                    data: sourceBase,
                    height: vImagePixelCount(copyHeight),
                    width: vImagePixelCount(copyWidth * 4),
                    rowBytes: copyWidth * 4 * MemoryLayout<Float>.size
                )
                var destinationBuffer = vImage_Buffer(
                    data: destinationBase.advanced(by: (coreY * width + coreX) * 4 * MemoryLayout<UInt16>.size),
                    height: vImagePixelCount(copyHeight),
                    width: vImagePixelCount(copyWidth * 4),
                    rowBytes: width * 4 * MemoryLayout<UInt16>.size
                )
                return vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageDoNotTile))
            }
        }
        guard error == kvImageNoError else { throw NoiseReductionError.renderFailed }
    }

    private func modelLocked() throws -> MLModel {
        if let model { return model }
        let sourceURL = try modelSourceURL()
        let compiledURL: URL
        do {
            compiledURL = try MLModel.compileModel(at: sourceURL)
        } catch {
            throw NoiseReductionError.modelCompilationFailed(error.localizedDescription)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        do {
            let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
            compiledModelURL = compiledURL
            model = loaded
            return loaded
        } catch {
            try? FileManager.default.removeItem(at: compiledURL)
            throw NoiseReductionError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func modelSourceURL() throws -> URL {
        if let resourcesDirectory = Bundle.main.resourceURL,
           let packaged = Self.packagedModelURL(in: resourcesDirectory) {
            return packaged
        }
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            throw NoiseReductionError.modelResourceMissing
        }
        guard let development = Bundle.module.url(forResource: "FFDNet", withExtension: "mlmodel",
                                                  subdirectory: "Resources") else {
            throw NoiseReductionError.modelResourceMissing
        }
        return development
    }

    static func packagedModelURL(in resourcesDirectory: URL) -> URL? {
        let bundleURL = resourcesDirectory.appendingPathComponent("Lighthouse_LighthouseCore.bundle", isDirectory: true)
        guard let resourceBundle = Bundle(url: bundleURL) else { return nil }
        return resourceBundle.url(forResource: "FFDNet", withExtension: "mlmodel", subdirectory: "Resources")
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
