import Foundation

public struct LightroomPresetPayload: Codable, Equatable, Sendable {
    public var format: String
    public var scalars: [String: Double]
    public var curves: [String: [CurvePoint]]
    public var warnings: [String]
    public var colorProfile: PhotoColorProfile?
    /// Adobe `WhiteBalance` 이름(`whiteBalanceNames` 중 하나). 없으면 화이트밸런스 방식을 바꾸지 않는다.
    public var whiteBalance: String?
    /// DCP 프로필 이름("Adobe Standard", "Camera …"). 없으면 카메라 프로필을 바꾸지 않는다.
    public var cameraProfile: String?

    public init(format: String, scalars: [String: Double], curves: [String: [CurvePoint]], warnings: [String],
                colorProfile: PhotoColorProfile? = nil, whiteBalance: String? = nil, cameraProfile: String? = nil) {
        self.format = format
        self.scalars = scalars
        self.curves = curves
        self.warnings = warnings
        self.colorProfile = colorProfile
        self.whiteBalance = whiteBalance
        self.cameraProfile = cameraProfile
    }

    public func validate() throws {
        guard format == "xmp" || format == "lrtemplate" else {
            throw LightroomPresetPayloadError.invalidFormat(format)
        }
        guard !scalars.isEmpty || !curves.isEmpty || colorProfile != nil || whiteBalance != nil
                || cameraProfile != nil else {
            throw LightroomPresetPayloadError.emptySettings
        }
        if let whiteBalance, !Self.whiteBalanceNames.contains(whiteBalance) {
            throw LightroomPresetPayloadError.invalidScalar("WhiteBalance")
        }
        if let cameraProfile, !Self.isDNGProfileName(cameraProfile) || cameraProfile.count > 128 {
            throw LightroomPresetPayloadError.invalidScalar("CameraProfile")
        }
        for (key, value) in scalars {
            guard let range = Self.scalarRanges[key] else {
                throw LightroomPresetPayloadError.unsupportedScalar(key)
            }
            guard value.isFinite, range.contains(value) else {
                throw LightroomPresetPayloadError.invalidScalar(key)
            }
        }
        for (channel, points) in curves {
            guard Self.curveChannels.contains(channel) else {
                throw LightroomPresetPayloadError.unsupportedCurve(channel)
            }
            do {
                var toneCurves = ToneCurves()
                switch channel {
                case "master": toneCurves.master = points
                case "red": toneCurves.red = points
                case "green": toneCurves.green = points
                case "blue": toneCurves.blue = points
                default: break
                }
                try toneCurves.validate()
            } catch {
                throw LightroomPresetPayloadError.invalidCurve(channel)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format, scalars, curves, warnings, colorProfile, whiteBalance, cameraProfile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        scalars = try container.decode([String: Double].self, forKey: .scalars)
        curves = try container.decode([String: [CurvePoint]].self, forKey: .curves)
        warnings = try container.decode([String].self, forKey: .warnings)
        colorProfile = try container.contains(.colorProfile)
            ? container.decode(PhotoColorProfile.self, forKey: .colorProfile) : nil
        whiteBalance = container.contains(.whiteBalance)
            ? try container.decode(String.self, forKey: .whiteBalance) : nil
        cameraProfile = container.contains(.cameraProfile)
            ? try container.decode(String.self, forKey: .cameraProfile) : nil
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid Lightroom preset payload",
                underlyingError: error
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(scalars, forKey: .scalars)
        try container.encode(curves, forKey: .curves)
        try container.encode(warnings, forKey: .warnings)
        try container.encodeIfPresent(colorProfile, forKey: .colorProfile)
        try container.encodeIfPresent(whiteBalance, forKey: .whiteBalance)
        try container.encodeIfPresent(cameraProfile, forKey: .cameraProfile)
    }

    /// `isRAW`에 따라 화이트밸런스를 다르게 적용한다. RAW는 켈빈 기준값, 다른 파일은 Incremental 이동량을 쓴다.
    func applying(to edits: EditSettings, isRAW: Bool) -> EditSettings {
        var result = edits
        applyWhiteBalance(to: &result, isRAW: isRAW)
        if let value = scalars["Texture"] { result.texture = value / 100 }
        if let value = scalars["Dehaze"] { result.dehaze = value / 100 }
        if let cameraProfile { result.cameraProfile = cameraProfile }
        for (key, path) in Self.calibrationKeys {
            if let value = scalars[key] { result.calibration[keyPath: path] = value / 100 }
        }
        if let value = preferred(modern: "Exposure2012", legacy: "Exposure") {
            result.exposure = min(4, max(-4, value))
        }
        if let value = preferred(modern: "Contrast2012", legacy: "Contrast") {
            result.contrast = 1 + value / 200
        }
        if let value = scalars["Saturation"] { result.saturation = 1 + value / 100 }
        if let value = scalars["Vibrance"] { result.vibrance = value / 100 }
        if let value = preferred(modern: "Clarity2012", legacy: "Clarity") {
            result.clarity = value / 100
        }
        if let value = scalars["Highlights2012"] { result.highlights = 1 + value / 100 }
        if let value = scalars["Shadows2012"] { result.shadows = value / 100 }
        if let value = scalars["Whites2012"] { result.whites = value / 100 }
        if let value = scalars["Blacks2012"] { result.blacks = value / 100 }
        if let value = scalars["Sharpness"] { result.sharpness = value / 75 }
        if let value = scalars["PostCropVignetteAmount"] { result.vignette = value / 100 }
        if let value = scalars["GrainAmount"] { result.grain.amount = value / 100 }
        if let value = scalars["GrainSize"] { result.grain.size = 0.5 + value * 0.075 }
        if let value = scalars["GrainFrequency"] { result.grain.roughness = value / 100 }
        if let colorProfile { result.colorProfile = colorProfile }
        for entry in Self.colorGradeZoneKeys {
            let path = entry.region.keyPath
            if let value = scalars[entry.hue] {
                result.colorGrading[keyPath: path].hue = value.truncatingRemainder(dividingBy: 360)
            }
            if let value = scalars[entry.saturation] { result.colorGrading[keyPath: path].saturation = value / 100 }
            if let value = scalars[entry.luminance] { result.colorGrading[keyPath: path].luminance = value / 100 }
        }
        if let value = scalars["ColorGradeBlending"] { result.colorGrading.blending = value / 100 }
        if let value = scalars["SplitToningBalance"] { result.colorGrading.balance = value / 100 }

        for band in ColorBand.allCases {
            let suffix = band.adobeSuffix
            let hue = scalars["HueAdjustment\(suffix)"]
            let saturation = scalars["SaturationAdjustment\(suffix)"]
            let lightness = scalars["LuminanceAdjustment\(suffix)"]
            guard hue != nil || saturation != nil || lightness != nil else { continue }
            if let index = result.colorRanges.firstIndex(where: { $0.band == band }) {
                if let hue { result.colorRanges[index].hue = hue * 0.3 }
                if let saturation { result.colorRanges[index].saturation = saturation / 100 }
                if let lightness { result.colorRanges[index].lightness = lightness / 100 }
            } else {
                result.colorRanges.append(ColorRangeAdjustment(
                    band: band,
                    hue: (hue ?? 0) * 0.3,
                    saturation: (saturation ?? 0) / 100,
                    lightness: (lightness ?? 0) / 100
                ))
            }
        }

        for (channel, points) in curves {
            switch channel {
            case "master": result.curves.master = points
            case "red": result.curves.red = points
            case "green": result.curves.green = points
            case "blue": result.curves.blue = points
            default: break
            }
        }
        return result
    }

    private func applyWhiteBalance(to result: inout EditSettings, isRAW: Bool) {
        if isRAW {
            switch whiteBalance {
            case "As Shot":
                result.whiteBalance = nil
            case "Auto":
                return
            default:
                if let temperature = scalars["Temperature"] {
                    result.whiteBalance = WhiteBalanceBase(temperature: temperature, tint: scalars["Tint"] ?? 0)
                } else if let name = whiteBalance, let preset = Self.whiteBalancePresets[name] {
                    result.whiteBalance = preset.base
                } else {
                    return
                }
            }
            result.temperatureShift = 0
            result.tintShift = 0
        } else {
            if whiteBalance == "As Shot" {
                result.temperatureShift = 0
                result.tintShift = 0
            }
            if let value = scalars["IncrementalTemperature"] { result.temperatureShift = min(2500, max(-2500, value * 25)) }
            if let value = scalars["IncrementalTint"] { result.tintShift = value }
        }
    }

    /// Adobe `WhiteBalance` 값. 가져올 때 대소문자를 무시하고 이 이름으로 맞춘다.
    static let whiteBalanceNames: [String] = ["As Shot", "Auto", "Custom", "Daylight", "Cloudy", "Shade",
                                              "Tungsten", "Fluorescent", "Flash"]
    static let whiteBalancePresets: [String: WhiteBalancePreset] = [
        "Daylight": .daylight, "Cloudy": .cloudy, "Shade": .shade, "Tungsten": .tungsten,
        "Fluorescent": .fluorescent, "Flash": .flash,
    ]
    /// Lighthouse가 이 Mac에 설치된 DCP·Adobe Raw 프로필로 찾는 이름.
    static func isDNGProfileName(_ name: String) -> Bool {
        name == "Adobe Standard" || adobeRawProfileNames.contains(name) || (name.hasPrefix("Camera ") && name.count > 7)
    }

    /// Camera Raw가 설치하는 Adobe Raw 프로필(Look XMP). 같은 이름으로 설치본을 찾는다.
    static let adobeRawProfileNames: Set<String> = ["Adobe Color", "Adobe Landscape", "Adobe Monochrome",
                                                    "Adobe Neutral", "Adobe Portrait", "Adobe Vivid"]

    static var calibrationKeys: [(String, WritableKeyPath<CalibrationSettings, Double>)] {
        [("ShadowTint", \.shadowTint), ("RedHue", \.redHue), ("RedSaturation", \.redSaturation),
         ("GreenHue", \.greenHue), ("GreenSaturation", \.greenSaturation),
         ("BlueHue", \.blueHue), ("BlueSaturation", \.blueSaturation)]
    }

    static let whiteBalanceKeys: Set<String> = ["Temperature", "Tint", "IncrementalTemperature", "IncrementalTint"]

    private func preferred(modern: String, legacy: String) -> Double? {
        scalars[modern] ?? scalars[legacy]
    }

    /// Lightroom은 그림자·하이라이트 색과 균형을 옛 분할 톤 키에, 나머지를 ColorGrade 키에 저장한다.
    static let colorGradeZoneKeys: [(region: ColorGradeRegion, hue: String, saturation: String, luminance: String)] = [
        (.shadows, "SplitToningShadowHue", "SplitToningShadowSaturation", "ColorGradeShadowLum"),
        (.midtones, "ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum"),
        (.highlights, "SplitToningHighlightHue", "SplitToningHighlightSaturation", "ColorGradeHighlightLum"),
        (.global, "ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum"),
    ]

    static let colorGradingKeys: Set<String> = Set(colorGradeZoneKeys.flatMap {
        [$0.hue, $0.saturation, $0.luminance]
    } + ["SplitToningBalance", "ColorGradeBlending"])

    static let curveChannels: Set<String> = ["master", "red", "green", "blue"]

    static let scalarRanges: [String: ClosedRange<Double>] = {
        var ranges: [String: ClosedRange<Double>] = [
            "Exposure2012": -5...5, "Exposure": -5...5,
            "Contrast2012": -100...100, "Contrast": -50...100,
            "Saturation": -100...100, "Vibrance": -100...100,
            "Clarity2012": -100...100, "Clarity": -100...100,
            "Highlights2012": -100...100, "Shadows2012": -100...100,
            "Whites2012": -100...100, "Blacks2012": -100...100,
            "Sharpness": 0...150, "PostCropVignetteAmount": -100...100,
            "GrainAmount": 0...100, "GrainSize": 0...100, "GrainFrequency": 0...100,
            "Texture": -100...100, "Dehaze": -100...100,
            "Temperature": WhiteBalanceBase.temperatureRange, "Tint": WhiteBalanceBase.tintRange,
            "IncrementalTemperature": -100...100, "IncrementalTint": -100...100,
            "ShadowTint": -100...100, "RedHue": -100...100, "RedSaturation": -100...100,
            "GreenHue": -100...100, "GreenSaturation": -100...100, "BlueHue": -100...100, "BlueSaturation": -100...100,
        ]
        for band in ColorBand.allCases {
            let suffix = band.adobeSuffix
            ranges["HueAdjustment\(suffix)"] = -100...100
            ranges["SaturationAdjustment\(suffix)"] = -100...100
            ranges["LuminanceAdjustment\(suffix)"] = -100...100
        }
        for entry in colorGradeZoneKeys {
            ranges[entry.hue] = 0...360
            ranges[entry.saturation] = 0...100
            ranges[entry.luminance] = -100...100
        }
        ranges["SplitToningBalance"] = -100...100
        ranges["ColorGradeBlending"] = 0...100
        return ranges
    }()
}

public enum LightroomPresetPayloadError: LocalizedError, Equatable, Sendable {
    case invalidFormat(String)
    case emptySettings
    case unsupportedScalar(String)
    case invalidScalar(String)
    case unsupportedCurve(String)
    case invalidCurve(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let format): "지원하지 않는 Lightroom 프리셋 형식입니다: \(format)"
        case .emptySettings: "지원하는 Lightroom 보정값이 없습니다."
        case .unsupportedScalar(let key): "지원하지 않는 Lightroom 보정 키입니다: \(key)"
        case .invalidScalar(let key): "Lightroom 보정값이 허용 범위를 벗어났습니다: \(key)"
        case .unsupportedCurve(let channel): "지원하지 않는 Lightroom 곡선 채널입니다: \(channel)"
        case .invalidCurve(let channel): "Lightroom 곡선이 올바르지 않습니다: \(channel)"
        }
    }
}

private extension ColorBand {
    var adobeSuffix: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}
