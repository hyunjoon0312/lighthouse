import Foundation

public enum PhotoFlag: String, Codable, CaseIterable, Sendable {
    case none, pick, reject
}

/// 별점·선택과 따로 붙이는 색상 라벨(예: 블로그용, 인화용). 6–9 키가 빨강·노랑·초록·파랑이다.
public enum PhotoColorLabel: String, Codable, CaseIterable, Sendable {
    case red, yellow, green, blue, purple

    public var title: String {
        switch self {
        case .red: "빨강"
        case .yellow: "노랑"
        case .green: "초록"
        case .blue: "파랑"
        case .purple: "보라"
        }
    }

    /// XMP `xmp:Label`에 쓰는 이름. Lightroom·Bridge와 같은 영어 이름이다.
    public var xmpName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// 6–9 키로 붙이는 라벨. 보라는 키가 없다.
    public static func forKey(_ key: String) -> PhotoColorLabel? {
        ["6": .red, "7": .yellow, "8": .green, "9": .blue][key]
    }
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
    public var gradient: MaskGradient?
    public var temperature: Double
    public var saturation: Double
    public var clarity: Double
    public var automaticMaskKind: AutomaticMaskKind?
    public var rangeSelection: RangeSelection?
    public var noiseReduction: NoiseReductionSettings

    public init(id: UUID = UUID(), name: String = "영역 1", isEnabled: Bool = true,
                exposure: Double = 0, contrast: Double = 1, feather: Double = 0.01,
                strokes: [MaskStroke] = [], baseMask: RasterMask? = nil,
                isInverted: Bool = false, gradient: MaskGradient? = nil,
                temperature: Double = 0, saturation: Double = 0, clarity: Double = 0,
                automaticMaskKind: AutomaticMaskKind? = nil, rangeSelection: RangeSelection? = nil,
                noiseReduction: NoiseReductionSettings = NoiseReductionSettings()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.exposure = exposure
        self.contrast = contrast
        self.feather = feather
        self.strokes = strokes
        self.baseMask = baseMask
        self.isInverted = isInverted
        self.gradient = gradient
        self.temperature = temperature
        self.saturation = saturation
        self.clarity = clarity
        self.automaticMaskKind = automaticMaskKind
        self.rangeSelection = rangeSelection
        self.noiseReduction = noiseReduction
    }

    /// 마스크 안에서 실제로 바꾸는 값이 있는지.
    public var hasEffect: Bool {
        exposure != 0 || contrast != 1 || temperature != 0 || saturation != 0 || clarity != 0
            || noiseReduction.isActive
    }

    public var hasMask: Bool { baseMask != nil || gradient != nil || isInverted || !strokes.isEmpty }

    /// 마스크 모양을 정하는 값. 노출·색 같은 효과 값만 바뀌면 같으므로 마스크를 다시 그리지 않아도 된다.
    public var maskDefinition: LocalMaskDefinition {
        LocalMaskDefinition(baseMask: baseMask, gradient: gradient, isInverted: isInverted,
                            strokes: strokes, feather: feather)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, exposure, contrast, feather, strokes, baseMask, isInverted
        case gradient, temperature, saturation, clarity, automaticMaskKind, rangeSelection, noiseReduction
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
        gradient = try container.decodeIfPresent(MaskGradient.self, forKey: .gradient)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        automaticMaskKind = try container.contains(.automaticMaskKind)
            ? container.decode(AutomaticMaskKind.self, forKey: .automaticMaskKind) : nil
        rangeSelection = try container.contains(.rangeSelection)
            ? container.decode(RangeSelection.self, forKey: .rangeSelection) : nil
        noiseReduction = try container.contains(.noiseReduction)
            ? container.decode(NoiseReductionSettings.self, forKey: .noiseReduction) : NoiseReductionSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(feather, forKey: .feather)
        try container.encode(strokes, forKey: .strokes)
        try container.encodeIfPresent(baseMask, forKey: .baseMask)
        try container.encode(isInverted, forKey: .isInverted)
        try container.encodeIfPresent(gradient, forKey: .gradient)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(clarity, forKey: .clarity)
        try container.encodeIfPresent(automaticMaskKind, forKey: .automaticMaskKind)
        try container.encodeIfPresent(rangeSelection, forKey: .rangeSelection)
        if noiseReduction != NoiseReductionSettings() {
            try container.encode(noiseReduction, forKey: .noiseReduction)
        }
    }
}

public struct LocalMaskDefinition: Equatable, Sendable {
    public let baseMask: RasterMask?
    public let gradient: MaskGradient?
    public let isInverted: Bool
    public let strokes: [MaskStroke]
    public let feather: Double
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

public enum PhotoColorProfile: String, Codable, CaseIterable, Sendable {
    case color
    case monochrome
}

public struct EditSettings: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var temperatureShift: Double
    public var tintShift: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var colorProfile: PhotoColorProfile
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
    public var rawDevelop: RAWDevelopSettings
    public var noiseReduction: NoiseReductionSettings
    public var flicker: FlickerSettings
    public var vibrance: Double
    public var clarity: Double
    public var vignette: Double
    /// RAW HDR 하이라이트(0…2). 0이면 쓰지 않는다. HDR 화면에서 밝은 부분을 더 밝게 보이고 HEIF·JPEG에 게인 맵을 넣는다.
    public var hdrAmount: Double
    /// 그림자·중간톤·하이라이트·전체 컬러 그레이딩. 중립이면 저장하지 않는다.
    public var colorGrading: ColorGrading
    /// 잔 디테일 대비(-1…1). 0이면 저장하지 않는다.
    public var texture: Double
    /// 안개 제거(+)·추가(-) (-1…1). 0이면 저장하지 않는다.
    public var dehaze: Double
    /// RAW 화이트밸런스 기준값. nil이면 촬영 시 값이고 저장하지 않는다. RAW가 아닌 파일에는 쓰지 않는다.
    public var whiteBalance: WhiteBalanceBase?
    /// RAW에 쓸 DCP 프로필 이름("Adobe Standard" 등). nil이면 macOS 기본 현상이고 저장하지 않는다.
    public var cameraProfile: String?
    /// 그림자 틴트와 원색 색조·채도. 중립이면 저장하지 않는다.
    public var calibration: CalibrationSettings

    public init(exposure: Double = 0, contrast: Double = 1, saturation: Double = 1,
                temperatureShift: Double = 0, tintShift: Double = 0, highlights: Double = 1,
                shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
                colorProfile: PhotoColorProfile = .color,
                sharpness: Double = 0, rotationQuarterTurns: Int = 0,
                cropAspect: Double? = nil, localAdjustments: [LocalAdjustment] = [],
                lut: LUTAdjustment? = nil, curves: ToneCurves = .identity,
                colorRanges: [ColorRangeAdjustment] = [], grain: GrainSettings = GrainSettings(),
                straightenDegrees: Double = 0, cropRect: NormalizedCrop? = nil,
                retouchStrokes: [RetouchStroke] = [], rawDevelop: RAWDevelopSettings = RAWDevelopSettings(),
                noiseReduction: NoiseReductionSettings = NoiseReductionSettings(), flicker: FlickerSettings = FlickerSettings(),
                vibrance: Double = 0, clarity: Double = 0, vignette: Double = 0, hdrAmount: Double = 0,
                colorGrading: ColorGrading = .neutral, texture: Double = 0, dehaze: Double = 0,
                whiteBalance: WhiteBalanceBase? = nil, cameraProfile: String? = nil,
                calibration: CalibrationSettings = .neutral) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperatureShift = temperatureShift
        self.tintShift = tintShift
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.colorProfile = colorProfile
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
        self.rawDevelop = rawDevelop
        self.noiseReduction = noiseReduction
        self.flicker = flicker
        self.vibrance = vibrance
        self.clarity = clarity
        self.vignette = vignette
        self.hdrAmount = hdrAmount
        self.colorGrading = colorGrading
        self.texture = texture
        self.dehaze = dehaze
        self.whiteBalance = whiteBalance
        self.cameraProfile = cameraProfile
        self.calibration = calibration
    }

    public static let neutral = EditSettings()
    public var isModified: Bool { self != .neutral }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperatureShift, tintShift, highlights, shadows, whites, blacks
        case colorProfile
        case sharpness, rotationQuarterTurns, cropAspect, localAdjustments, lut
        case curves, colorRanges, grain, straightenDegrees, cropRect, retouchStrokes, rawDevelop, noiseReduction, flicker
        case vibrance, clarity, vignette, hdrAmount, colorGrading, texture, dehaze, whiteBalance
        case cameraProfile, calibration
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
        whites = try container.contains(.whites) ? container.decode(Double.self, forKey: .whites) : 0
        blacks = try container.contains(.blacks) ? container.decode(Double.self, forKey: .blacks) : 0
        colorProfile = try container.contains(.colorProfile)
            ? container.decode(PhotoColorProfile.self, forKey: .colorProfile) : .color
        guard highlights.isFinite, (0...2).contains(highlights),
              shadows.isFinite, (-1...1).contains(shadows),
              whites.isFinite, (-1...1).contains(whites),
              blacks.isFinite, (-1...1).contains(blacks) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Tone settings must be finite and within their supported ranges"
            ))
        }
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
        rawDevelop = try container.contains(.rawDevelop)
            ? container.decode(RAWDevelopSettings.self, forKey: .rawDevelop) : RAWDevelopSettings()
        noiseReduction = try container.contains(.noiseReduction)
            ? container.decode(NoiseReductionSettings.self, forKey: .noiseReduction) : NoiseReductionSettings()
        flicker = try container.contains(.flicker)
            ? container.decode(FlickerSettings.self, forKey: .flicker) : FlickerSettings()
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        hdrAmount = try container.decodeIfPresent(Double.self, forKey: .hdrAmount) ?? 0
        colorGrading = try container.contains(.colorGrading)
            ? container.decode(ColorGrading.self, forKey: .colorGrading) : .neutral
        texture = try container.contains(.texture) ? container.decode(Double.self, forKey: .texture) : 0
        dehaze = try container.contains(.dehaze) ? container.decode(Double.self, forKey: .dehaze) : 0
        guard texture.isFinite, (-1...1).contains(texture), dehaze.isFinite, (-1...1).contains(dehaze) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Texture and dehaze must be finite and within -1…1"
            ))
        }
        whiteBalance = try container.contains(.whiteBalance)
            ? container.decode(WhiteBalanceBase.self, forKey: .whiteBalance) : nil
        cameraProfile = try container.contains(.cameraProfile)
            ? container.decode(String.self, forKey: .cameraProfile) : nil
        if let cameraProfile, cameraProfile.isEmpty || cameraProfile.count > 128 {
            throw DecodingError.dataCorruptedError(forKey: .cameraProfile, in: container,
                                                   debugDescription: "Camera profile name must be 1…128 characters")
        }
        calibration = try container.contains(.calibration)
            ? container.decode(CalibrationSettings.self, forKey: .calibration) : .neutral
    }

    /// HDR 하이라이트는 쓸 때만 적는다. 쓰지 않는 사진의 카탈로그와 썸네일 키가 예전과 같게 남는다.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(temperatureShift, forKey: .temperatureShift)
        try container.encode(tintShift, forKey: .tintShift)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        if whites != 0 { try container.encode(whites, forKey: .whites) }
        if blacks != 0 { try container.encode(blacks, forKey: .blacks) }
        if colorProfile != .color { try container.encode(colorProfile, forKey: .colorProfile) }
        try container.encode(sharpness, forKey: .sharpness)
        try container.encode(rotationQuarterTurns, forKey: .rotationQuarterTurns)
        try container.encodeIfPresent(cropAspect, forKey: .cropAspect)
        try container.encode(localAdjustments, forKey: .localAdjustments)
        try container.encodeIfPresent(lut, forKey: .lut)
        try container.encode(curves, forKey: .curves)
        try container.encode(colorRanges, forKey: .colorRanges)
        try container.encode(grain, forKey: .grain)
        try container.encode(straightenDegrees, forKey: .straightenDegrees)
        try container.encodeIfPresent(cropRect, forKey: .cropRect)
        try container.encode(retouchStrokes, forKey: .retouchStrokes)
        try container.encode(rawDevelop, forKey: .rawDevelop)
        if noiseReduction != NoiseReductionSettings() {
            try container.encode(noiseReduction, forKey: .noiseReduction)
        }
        if flicker != FlickerSettings() {
            try container.encode(flicker, forKey: .flicker)
        }
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(vignette, forKey: .vignette)
        if hdrAmount != 0 { try container.encode(hdrAmount, forKey: .hdrAmount) }
        if colorGrading != .neutral { try container.encode(colorGrading, forKey: .colorGrading) }
        if texture != 0 { try container.encode(texture, forKey: .texture) }
        if dehaze != 0 { try container.encode(dehaze, forKey: .dehaze) }
        try container.encodeIfPresent(whiteBalance, forKey: .whiteBalance)
        try container.encodeIfPresent(cameraProfile, forKey: .cameraProfile)
        if calibration != .neutral { try container.encode(calibration, forKey: .calibration) }
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
    /// 실제 초점거리(mm). 이 값이 생기기 전에 가져온 사진은 다음 실행 때 원본에서 다시 읽어 채운다.
    public var focalLength: Double?
    /// 원본을 읽었는데 초점거리가 없었다(수동 렌즈 등). 실행마다 다시 읽지 않게 남긴다. 아직 확인하지 않았으면 nil.
    public var focalLengthUnavailable: Bool?

    public init(width: Int = 0, height: Int = 0, camera: String? = nil, lens: String? = nil,
                iso: Int? = nil, aperture: Double? = nil, shutter: Double? = nil,
                capturedAt: Date? = nil, focalLength: Double? = nil, focalLengthUnavailable: Bool? = nil) {
        self.width = width
        self.height = height
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.capturedAt = capturedAt
        self.focalLength = focalLength
        self.focalLengthUnavailable = focalLengthUnavailable
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
    /// 가상 사본의 이름("사본 1"). nil이면 가져온 원래 항목이다. 사본은 같은 원본 파일을 가리키고 보정만 따로 가진다.
    public var copyName: String?
    /// 검색과 내보내기(IPTC)에 쓰는 키워드와 설명. 비어 있으면 카탈로그에 쓰지 않는다.
    public var keywords: [String] = []
    public var caption: String = ""
    public var colorLabel: PhotoColorLabel?
    /// 이름 붙여 저장한 보정 상태. 비어 있으면 카탈로그에 쓰지 않는다.
    public var snapshots: [EditSnapshot] = []
    /// 마지막으로 내보낸 기록.
    public var lastExport: ExportRecord?

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

    private enum CodingKeys: String, CodingKey {
        case id, path, importedAt, metadata, rating, flag, edits, copyName, keywords, caption, colorLabel, snapshots
        case lastExport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        metadata = try container.decode(PhotoMetadata.self, forKey: .metadata)
        rating = try container.decode(Int.self, forKey: .rating)
        flag = try container.decode(PhotoFlag.self, forKey: .flag)
        edits = try container.decode(EditSettings.self, forKey: .edits)
        copyName = try container.decodeIfPresent(String.self, forKey: .copyName)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        colorLabel = try container.decodeIfPresent(PhotoColorLabel.self, forKey: .colorLabel)
        snapshots = try container.decodeIfPresent([EditSnapshot].self, forKey: .snapshots) ?? []
        lastExport = try container.decodeIfPresent(ExportRecord.self, forKey: .lastExport)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(rating, forKey: .rating)
        try container.encode(flag, forKey: .flag)
        try container.encode(edits, forKey: .edits)
        try container.encodeIfPresent(copyName, forKey: .copyName)
        if !keywords.isEmpty { try container.encode(keywords, forKey: .keywords) }
        if !caption.isEmpty { try container.encode(caption, forKey: .caption) }
        try container.encodeIfPresent(colorLabel, forKey: .colorLabel)
        if !snapshots.isEmpty { try container.encode(snapshots, forKey: .snapshots) }
        try container.encodeIfPresent(lastExport, forKey: .lastExport)
    }

    /// 실행 취소 단위로 함께 바뀌는 별점·표시·키워드·설명·색상 라벨.
    public var marks: PhotoMarks {
        get { PhotoMarks(rating: rating, flag: flag, keywords: keywords, caption: caption, colorLabel: colorLabel) }
        set {
            rating = newValue.rating
            flag = newValue.flag
            keywords = newValue.keywords
            caption = newValue.caption
            colorLabel = newValue.colorLabel
        }
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { url.lastPathComponent }
    public var isRAW: Bool { ImagePipeline.isRAW(url) }
    public var isVirtualCopy: Bool { copyName != nil }
    /// 화면에 보이는 이름. 사본은 파일 이름 뒤에 사본 이름을 붙인다.
    public var displayName: String { copyName.map { "\(filename) · \($0)" } ?? filename }

    /// 같은 파일의 새 가상 사본. 보정·별점·표시와 가져온 시각을 그대로 가져오고 ID만 새로 정한다.
    /// 가져온 시각이 같아야 촬영 시각이 없는 사진도 정렬 뒤 원래 항목 옆에 남는다.
    /// 이름은 `existing` 중 같은 파일의 사본 번호 다음 번호다.
    public func virtualCopy(among existing: [PhotoAsset]) -> PhotoAsset {
        let used = Set(existing.filter { $0.path == path }.compactMap { photo -> Int? in
            guard let name = photo.copyName, name.hasPrefix("사본 ") else { return nil }
            return Int(name.dropFirst(3))
        })
        var number = 1
        while used.contains(number) { number += 1 }
        var copy = self
        copy.id = UUID()
        copy.copyName = "사본 \(number)"
        return copy
    }
}

/// 쉼표나 줄바꿈으로 구분한 키워드. 앞뒤 공백을 지우고 대소문자만 다른 중복은 처음 것만 남긴다.
public enum PhotoKeywords {
    public static let maximumCount = 64
    public static let maximumLength = 64

    public static func parse(_ text: String) -> [String] {
        merge([], text.components(separatedBy: CharacterSet(charactersIn: ",，;\n")))
    }

    /// `existing` 뒤에 `added`를 붙인다. 이미 있는 키워드는 다시 넣지 않는다.
    public static func merge(_ existing: [String], _ added: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in existing + added {
            let keyword = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
            guard !keyword.isEmpty, result.count < maximumCount,
                  seen.insert(keyword.lowercased()).inserted else { continue }
            result.append(keyword)
        }
        return result
    }

    public static func text(_ keywords: [String]) -> String { keywords.joined(separator: ", ") }
}
