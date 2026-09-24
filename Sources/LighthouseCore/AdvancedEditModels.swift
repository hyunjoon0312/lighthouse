import Foundation

public struct CurvePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ToneCurves: Codable, Equatable, Sendable {
    public var master: [CurvePoint]
    public var red: [CurvePoint]
    public var green: [CurvePoint]
    public var blue: [CurvePoint]

    public init(master: [CurvePoint] = Self.identityPoints,
                red: [CurvePoint] = Self.identityPoints,
                green: [CurvePoint] = Self.identityPoints,
                blue: [CurvePoint] = Self.identityPoints) {
        self.master = master
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = ToneCurves()
    public var isIdentity: Bool { self == .identity }

    public func validate() throws {
        try Self.validate(master, channel: "master")
        try Self.validate(red, channel: "red")
        try Self.validate(green, channel: "green")
        try Self.validate(blue, channel: "blue")
    }

    public static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    private static func validate(_ points: [CurvePoint], channel: String) throws {
        guard (2...16).contains(points.count) else {
            throw ValidationError.invalidCurve(channel: channel)
        }
        guard points[0].x == 0, points[points.count - 1].x == 1 else {
            throw ValidationError.invalidCurve(channel: channel)
        }
        var previousX = -Double.infinity
        for point in points {
            guard point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y),
                  point.x > previousX else {
                throw ValidationError.invalidCurve(channel: channel)
            }
            previousX = point.x
        }
    }

    private enum CodingKeys: String, CodingKey {
        case master, red, green, blue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        master = try container.decode([CurvePoint].self, forKey: .master)
        red = try container.decode([CurvePoint].self, forKey: .red)
        green = try container.decode([CurvePoint].self, forKey: .green)
        blue = try container.decode([CurvePoint].self, forKey: .blue)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Tone curve points must define valid 0...1 curves",
                underlyingError: error
            ))
        }
    }

    public enum ValidationError: LocalizedError, Equatable, Sendable {
        case invalidCurve(channel: String)

        public var errorDescription: String? {
            switch self {
            case .invalidCurve(let channel):
                "\(channel) curve must contain 2...16 finite, ordered points from x=0 through x=1"
            }
        }
    }
}

public enum ColorBand: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        }
    }
}

public struct ColorRangeAdjustment: Codable, Equatable, Sendable {
    public var band: ColorBand
    public var hue: Double
    public var saturation: Double
    public var lightness: Double

    public init(band: ColorBand, hue: Double = 0, saturation: Double = 0, lightness: Double = 0) {
        self.band = band
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }
}

public struct GrainSettings: Codable, Equatable, Sendable {
    public var amount: Double
    public var size: Double
    public var seed: UInt32

    public init(amount: Double = 0, size: Double = 1.5, seed: UInt32 = 1) {
        self.amount = amount
        self.size = size
        self.seed = seed
    }
}

public struct NormalizedCrop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedCrop()

    public var clamped: NormalizedCrop {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return .full }
        let clampedWidth = min(1, max(0.02, width))
        let clampedHeight = min(1, max(0.02, height))
        return NormalizedCrop(
            x: min(1 - clampedWidth, max(0, x)),
            y: min(1 - clampedHeight, max(0, y)),
            width: clampedWidth,
            height: clampedHeight
        )
    }
}

public struct RasterMask: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pngData: Data

    public init(width: Int, height: Int, pngData: Data) {
        self.width = width
        self.height = height
        self.pngData = pngData
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, pngData, sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        if container.contains(.pngData) {
            pngData = try container.decode(Data.self, forKey: .pngData)
        } else {
            let id = try container.decode(String.self, forKey: .sha256)
            guard let directory = decoder.userInfo[.rasterMaskDirectory] as? URL else {
                throw DecodingError.dataCorruptedError(forKey: .sha256, in: container,
                                                       debugDescription: "Mask file directory is unavailable")
            }
            pngData = try MaskFileStore(directory: directory).load(id: id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        if encoder.userInfo[.rasterMaskDirectory] is URL {
            try container.encode(MaskFileStore.contentID(pngData), forKey: .sha256)
        } else {
            try container.encode(pngData, forKey: .pngData)
        }
    }
}

public enum RetouchMode: String, Codable, CaseIterable, Sendable {
    case heal, clone
}

public struct RetouchStroke: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var mode: RetouchMode
    public var points: [MaskPoint]
    public var radius: Double
    public var sourceOffset: MaskPoint?
    public var isEnabled: Bool

    public init(id: UUID = UUID(), mode: RetouchMode = .heal, points: [MaskPoint] = [],
                radius: Double = 0.02, sourceOffset: MaskPoint? = nil, isEnabled: Bool = true) {
        self.id = id
        self.mode = mode
        self.points = points
        self.radius = radius
        self.sourceOffset = sourceOffset
        self.isEnabled = isEnabled
    }
}
