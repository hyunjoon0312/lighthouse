import Foundation

public enum BandDirection: String, Codable, CaseIterable, Sendable {
    case horizontal
    case vertical
}

public struct FlickerProfile: Codable, Equatable, Sendable {
    public var redCoefficients: [Double]
    public var greenCoefficients: [Double]
    public var blueCoefficients: [Double]
    public var referenceAmplitudeEV: Double

    public init(redCoefficients: [Double], greenCoefficients: [Double], blueCoefficients: [Double],
                referenceAmplitudeEV: Double) {
        self.redCoefficients = redCoefficients
        self.greenCoefficients = greenCoefficients
        self.blueCoefficients = blueCoefficients
        self.referenceAmplitudeEV = referenceAmplitudeEV
    }

    private enum CodingKeys: String, CodingKey {
        case redCoefficients, greenCoefficients, blueCoefficients, referenceAmplitudeEV
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        redCoefficients = try container.decode([Double].self, forKey: .redCoefficients)
        greenCoefficients = try container.decode([Double].self, forKey: .greenCoefficients)
        blueCoefficients = try container.decode([Double].self, forKey: .blueCoefficients)
        referenceAmplitudeEV = try container.decode(Double.self, forKey: .referenceAmplitudeEV)
        try Self.validate(redCoefficients, key: .redCoefficients, in: container)
        try Self.validate(greenCoefficients, key: .greenCoefficients, in: container)
        try Self.validate(blueCoefficients, key: .blueCoefficients, in: container)
        guard referenceAmplitudeEV.isFinite, referenceAmplitudeEV > 0, referenceAmplitudeEV <= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .referenceAmplitudeEV, in: container,
                                                   debugDescription: "Reference amplitude must be finite and in (0, 2].")
        }
    }

    private static func validate(_ values: [Double], key: CodingKeys,
                                 in container: KeyedDecodingContainer<CodingKeys>) throws {
        guard values.count == 6, values.allSatisfy({ $0.isFinite && abs($0) <= 2 }) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                                   debugDescription: "Flicker coefficients must contain six finite values in [-2, 2].")
        }
    }

    var isValid: Bool {
        [redCoefficients, greenCoefficients, blueCoefficients].allSatisfy {
            $0.count == 6 && $0.allSatisfy { $0.isFinite && abs($0) <= 2 }
        } && referenceAmplitudeEV.isFinite && referenceAmplitudeEV > 0 && referenceAmplitudeEV <= 2
    }
}

public struct FlickerSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var amount: Double
    public var direction: BandDirection
    public var cycles: Double
    public var phase: Double
    public var amplitudeEV: Double
    public var colorAmount: Double
    public var profile: FlickerProfile?

    public init(isEnabled: Bool = false, amount: Double = 0.7, direction: BandDirection = .horizontal,
                cycles: Double = 8, phase: Double = 0, amplitudeEV: Double = 0.25,
                colorAmount: Double = 0, profile: FlickerProfile? = nil) {
        self.isEnabled = isEnabled
        self.amount = amount
        self.direction = direction
        self.cycles = cycles
        self.phase = phase
        self.amplitudeEV = amplitudeEV
        self.colorAmount = colorAmount
        self.profile = profile
    }

    public var isActive: Bool { isEnabled && amount > 0 }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, amount, direction, cycles, phase, amplitudeEV, colorAmount, profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresentDefaultingMissing(Bool.self, forKey: .isEnabled, default: false)
        amount = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .amount, default: 0.7)
        direction = try container.decodeIfPresentDefaultingMissing(BandDirection.self, forKey: .direction,
                                                                    default: .horizontal)
        cycles = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .cycles, default: 8)
        phase = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .phase, default: 0)
        amplitudeEV = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .amplitudeEV, default: 0.25)
        colorAmount = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .colorAmount, default: 0)
        profile = try container.decodeOptionalRejectingNull(FlickerProfile.self, forKey: .profile)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: container,
                                                   debugDescription: "Flicker settings contain a non-finite or out-of-range value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if isEnabled { try container.encode(isEnabled, forKey: .isEnabled) }
        if amount != 0.7 { try container.encode(amount, forKey: .amount) }
        if direction != .horizontal { try container.encode(direction, forKey: .direction) }
        if cycles != 8 { try container.encode(cycles, forKey: .cycles) }
        if phase != 0 { try container.encode(phase, forKey: .phase) }
        if amplitudeEV != 0.25 { try container.encode(amplitudeEV, forKey: .amplitudeEV) }
        if colorAmount != 0 { try container.encode(colorAmount, forKey: .colorAmount) }
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    var isValid: Bool {
        amount.isFinite && (0...1).contains(amount) && cycles.isFinite && (1...128).contains(cycles)
            && phase.isFinite && (0...1).contains(phase) && amplitudeEV.isFinite && (0...2).contains(amplitudeEV)
            && colorAmount.isFinite && (0...1).contains(colorAmount) && (profile?.isValid ?? true)
    }
}

public enum RangeSelectionKind: String, Codable, CaseIterable, Sendable {
    case luminance
    case color
}

public struct RangeSelection: Codable, Equatable, Sendable {
    public typealias Kind = RangeSelectionKind

    public var kind: RangeSelectionKind
    public var lower: Double
    public var upper: Double
    public var softness: Double
    public var red: Double
    public var green: Double
    public var blue: Double
    public var tolerance: Double

    public init(kind: RangeSelectionKind = .luminance, lower: Double = 0, upper: Double = 1,
                softness: Double = 0.1, red: Double = 0.5, green: Double = 0.5,
                blue: Double = 0.5, tolerance: Double = 0.2) {
        self.kind = kind
        self.lower = lower
        self.upper = upper
        self.softness = softness
        self.red = red
        self.green = green
        self.blue = blue
        self.tolerance = tolerance
    }

    private enum CodingKeys: String, CodingKey {
        case kind, lower, upper, softness, red, green, blue, tolerance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresentDefaultingMissing(RangeSelectionKind.self, forKey: .kind,
                                                               default: .luminance)
        lower = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .lower, default: 0)
        upper = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .upper, default: 1)
        softness = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .softness, default: 0.1)
        red = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .red, default: 0.5)
        green = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .green, default: 0.5)
        blue = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .blue, default: 0.5)
        tolerance = try container.decodeIfPresentDefaultingMissing(Double.self, forKey: .tolerance, default: 0.2)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .lower, in: container,
                                                   debugDescription: "Range selection values must be finite, in [0, 1], and lower must not exceed upper.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if kind != .luminance { try container.encode(kind, forKey: .kind) }
        if lower != 0 { try container.encode(lower, forKey: .lower) }
        if upper != 1 { try container.encode(upper, forKey: .upper) }
        if softness != 0.1 { try container.encode(softness, forKey: .softness) }
        if red != 0.5 { try container.encode(red, forKey: .red) }
        if green != 0.5 { try container.encode(green, forKey: .green) }
        if blue != 0.5 { try container.encode(blue, forKey: .blue) }
        if tolerance != 0.2 { try container.encode(tolerance, forKey: .tolerance) }
    }

    var isValid: Bool {
        let values = [lower, upper, softness, red, green, blue, tolerance]
        return values.allSatisfy { $0.isFinite && (0...1).contains($0) } && lower <= upper
    }
}

public enum AutomaticMaskKind: String, Codable, CaseIterable, Sendable {
    case subject
    case background
}

public struct FlickerAnalysis: Codable, Equatable, Sendable {
    public var settings: FlickerSettings
    public var confidence: Double
    public var message: String

    public init(settings: FlickerSettings, confidence: Double, message: String) {
        self.settings = settings
        self.confidence = confidence
        self.message = message
    }
}

private extension KeyedDecodingContainer {
    func decodeIfPresentDefaultingMissing<T: Decodable>(_ type: T.Type, forKey key: Key,
                                                        default defaultValue: T) throws -> T {
        guard contains(key) else { return defaultValue }
        return try decode(T.self, forKey: key)
    }

    func decodeOptionalRejectingNull<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(T.self, forKey: key)
    }
}
