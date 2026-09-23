import Foundation

public enum PhotoFlag: String, Codable, CaseIterable, Sendable {
    case none, pick, reject
}

public struct MaskPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MaskStroke: Codable, Equatable, Sendable {
    public var points: [MaskPoint]
    public var radius: Double
    public var isErasing: Bool

    public init(points: [MaskPoint], radius: Double, isErasing: Bool = false) {
        self.points = points
        self.radius = radius
        self.isErasing = isErasing
    }
}

public struct LocalAdjustment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var exposure: Double
    public var contrast: Double
    public var feather: Double
    public var strokes: [MaskStroke]
    public var baseMask: RasterMask?
    public var isInverted: Bool

    public init(id: UUID = UUID(), name: String = "영역 1", isEnabled: Bool = true,
                exposure: Double = 0, contrast: Double = 1, feather: Double = 0.01,
                strokes: [MaskStroke] = [], baseMask: RasterMask? = nil,
                isInverted: Bool = false) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.exposure = exposure
        self.contrast = contrast
        self.feather = feather
        self.strokes = strokes
        self.baseMask = baseMask
        self.isInverted = isInverted
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, exposure, contrast, feather, strokes, baseMask, isInverted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        exposure = try container.decode(Double.self, forKey: .exposure)
        contrast = try container.decode(Double.self, forKey: .contrast)
        feather = try container.decode(Double.self, forKey: .feather)
        strokes = try container.decode([MaskStroke].self, forKey: .strokes)
        baseMask = try container.decodeIfPresent(RasterMask.self, forKey: .baseMask)
        isInverted = try container.contains(.isInverted)
            ? container.decode(Bool.self, forKey: .isInverted) : false
    }
}

public struct LUTAdjustment: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var intensity: Double
    public var isEnabled: Bool

    public init(id: String, name: String, intensity: Double = 1, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.intensity = intensity
        self.isEnabled = isEnabled
    }
}

public struct EditSettings: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var temperatureShift: Double
    public var tintShift: Double
    public var highlights: Double
    public var shadows: Double
    public var sharpness: Double
    public var rotationQuarterTurns: Int
    public var cropAspect: Double?
    public var localAdjustments: [LocalAdjustment]
    public var lut: LUTAdjustment?
    public var curves: ToneCurves
    public var colorRanges: [ColorRangeAdjustment]
    public var grain: GrainSettings
    public var straightenDegrees: Double
    public var cropRect: NormalizedCrop?
    public var retouchStrokes: [RetouchStroke]

    public init(exposure: Double = 0, contrast: Double = 1, saturation: Double = 1,
                temperatureShift: Double = 0, tintShift: Double = 0, highlights: Double = 1,
                shadows: Double = 0, sharpness: Double = 0, rotationQuarterTurns: Int = 0,
                cropAspect: Double? = nil, localAdjustments: [LocalAdjustment] = [],
                lut: LUTAdjustment? = nil, curves: ToneCurves = .identity,
                colorRanges: [ColorRangeAdjustment] = [], grain: GrainSettings = GrainSettings(),
                straightenDegrees: Double = 0, cropRect: NormalizedCrop? = nil,
                retouchStrokes: [RetouchStroke] = []) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperatureShift = temperatureShift
        self.tintShift = tintShift
        self.highlights = highlights
        self.shadows = shadows
        self.sharpness = sharpness
        self.rotationQuarterTurns = rotationQuarterTurns
        self.cropAspect = cropAspect
        self.localAdjustments = localAdjustments
        self.lut = lut
        self.curves = curves
        self.colorRanges = colorRanges
        self.grain = grain
        self.straightenDegrees = straightenDegrees
        self.cropRect = cropRect
        self.retouchStrokes = retouchStrokes
    }

    public static let neutral = EditSettings()
    public var isModified: Bool { self != .neutral }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperatureShift, tintShift, highlights, shadows
        case sharpness, rotationQuarterTurns, cropAspect, localAdjustments, lut
        case curves, colorRanges, grain, straightenDegrees, cropRect, retouchStrokes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decode(Double.self, forKey: .exposure)
        contrast = try container.decode(Double.self, forKey: .contrast)
        saturation = try container.decode(Double.self, forKey: .saturation)
        temperatureShift = try container.decode(Double.self, forKey: .temperatureShift)
        tintShift = try container.decode(Double.self, forKey: .tintShift)
        highlights = try container.decode(Double.self, forKey: .highlights)
        shadows = try container.decode(Double.self, forKey: .shadows)
        sharpness = try container.decode(Double.self, forKey: .sharpness)
        rotationQuarterTurns = try container.decode(Int.self, forKey: .rotationQuarterTurns)
        cropAspect = try container.decodeIfPresent(Double.self, forKey: .cropAspect)
        localAdjustments = try container.contains(.localAdjustments)
            ? container.decode([LocalAdjustment].self, forKey: .localAdjustments) : []
        lut = try container.decodeIfPresent(LUTAdjustment.self, forKey: .lut)
        curves = try container.contains(.curves)
            ? container.decode(ToneCurves.self, forKey: .curves) : .identity
        colorRanges = try container.contains(.colorRanges)
            ? container.decode([ColorRangeAdjustment].self, forKey: .colorRanges) : []
        grain = try container.contains(.grain)
            ? container.decode(GrainSettings.self, forKey: .grain) : GrainSettings()
        straightenDegrees = try container.contains(.straightenDegrees)
            ? container.decode(Double.self, forKey: .straightenDegrees) : 0
        cropRect = try container.decodeIfPresent(NormalizedCrop.self, forKey: .cropRect)
        retouchStrokes = try container.contains(.retouchStrokes)
            ? container.decode([RetouchStroke].self, forKey: .retouchStrokes) : []
    }
}

public struct PhotoMetadata: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var camera: String?
    public var lens: String?
    public var iso: Int?
    public var aperture: Double?
    public var shutter: Double?
    public var capturedAt: Date?

    public init(width: Int = 0, height: Int = 0, camera: String? = nil, lens: String? = nil,
                iso: Int? = nil, aperture: Double? = nil, shutter: Double? = nil,
                capturedAt: Date? = nil) {
        self.width = width
        self.height = height
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.capturedAt = capturedAt
    }
}

public struct PhotoAsset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var importedAt: Date
    public var metadata: PhotoMetadata
    public var rating: Int
    public var flag: PhotoFlag
    public var edits: EditSettings

    public init(id: UUID = UUID(), url: URL, metadata: PhotoMetadata = PhotoMetadata(),
                importedAt: Date = Date()) {
        self.id = id
        self.path = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.importedAt = importedAt
        self.metadata = metadata
        self.rating = 0
        self.flag = .none
        self.edits = .neutral
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { url.lastPathComponent }
    public var isRAW: Bool { ImagePipeline.isRAW(url) }
}
