import Foundation

public enum DNGProfileError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case notProfile
    case truncated
    case invalidTag(String)
    case missingName

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "카메라 프로필 파일은 16 MiB 이하여야 합니다."
        case .notProfile: "DNG 카메라 프로필(DCP)이 아닙니다."
        case .truncated: "카메라 프로필 파일이 잘렸습니다."
        case .invalidTag(let name): "카메라 프로필의 \(name) 값이 올바르지 않습니다."
        case .missingName: "카메라 프로필에 이름이 없습니다."
        }
    }
}

/// 3×3 행렬(행 우선). DNG 행렬 태그와 같은 순서다.
struct Matrix3: Equatable, Sendable {
    var values: [Double]

    static let identity = Matrix3(values: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(values[0] * v.x + values[1] * v.y + values[2] * v.z,
              values[3] * v.x + values[4] * v.y + values[5] * v.z,
              values[6] * v.x + values[7] * v.y + values[8] * v.z)
    }

    static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                result[row * 3 + column] = (0..<3).reduce(0) { $0 + a.values[row * 3 + $1] * b.values[$1 * 3 + column] }
            }
        }
        return Matrix3(values: result)
    }

    var inverse: Matrix3? {
        let m = values
        let c00 = m[4] * m[8] - m[5] * m[7], c01 = m[5] * m[6] - m[3] * m[8], c02 = m[3] * m[7] - m[4] * m[6]
        let determinant = m[0] * c00 + m[1] * c01 + m[2] * c02
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let inverse = [
            c00, m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
            c01, m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
            c02, m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
        ]
        return Matrix3(values: inverse.map { $0 / determinant })
    }

    static func blend(_ a: Matrix3, _ b: Matrix3, weightOfA weight: Double) -> Matrix3 {
        Matrix3(values: zip(a.values, b.values).map { weight * $0 + (1 - weight) * $1 })
    }
}

/// DCP(DNG 카메라 프로필) 한 개. Lighthouse 렌더에 쓰는 태그만 읽는다.
public struct DNGProfile: Equatable, Sendable {
    /// HueSatMap·LookTable. 항목마다 (색조 이동°, 채도 배율, 명도 배율)이고 명도 → 색조 → 채도 순서로 놓인다.
    public struct HueSatTable: Equatable, Sendable {
        public let hueDivisions: Int
        public let saturationDivisions: Int
        public let valueDivisions: Int
        public let deltas: [Float]
        /// 명도 축을 sRGB 감마로 인코딩한 값으로 조회한다(DNG의 encoding 1).
        public let isSRGBEncoded: Bool

        func blended(with other: HueSatTable, weightOfSelf weight: Double) -> HueSatTable {
            guard other.hueDivisions == hueDivisions, other.saturationDivisions == saturationDivisions,
                  other.valueDivisions == valueDivisions else { return self }
            let w = Float(weight)
            return HueSatTable(hueDivisions: hueDivisions, saturationDivisions: saturationDivisions,
                               valueDivisions: valueDivisions,
                               deltas: zip(deltas, other.deltas).map { w * $0 + (1 - w) * $1 },
                               isSRGBEncoded: isSRGBEncoded)
        }
    }

    public static let maximumFileSize = 16 * 1024 * 1024

    public var name: String
    public var uniqueCameraModel: String?
    var illuminant1: Int?
    var illuminant2: Int?
    var forwardMatrix1: Matrix3?
    var forwardMatrix2: Matrix3?
    public var hueSatMap1: HueSatTable?
    public var hueSatMap2: HueSatTable?
    public var lookTable: HueSatTable?
    /// ProfileToneCurve의 (입력, 출력) 점. 0…1, 입력이 늘어나는 순서다.
    public var toneCurve: [SIMD2<Double>]?
    public var baselineExposureOffset: Double

    public var hasToneCurve: Bool { toneCurve != nil }

    public static func load(url: URL) throws -> DNGProfile {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw DNGProfileError.tooLarge }
        return try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> DNGProfile {
        guard data.count <= maximumFileSize else { throw DNGProfileError.tooLarge }
        let reader = try TIFFReader(data)
        let entries = try reader.entries()
        guard let name = entries[50936].flatMap(reader.string), !name.isEmpty else { throw DNGProfileError.missingName }

        func matrix(_ tag: UInt16, _ label: String) throws -> Matrix3? {
            guard let entry = entries[tag] else { return nil }
            let values = try reader.numbers(entry)
            guard values.count == 9, values.allSatisfy(\.isFinite) else { throw DNGProfileError.invalidTag(label) }
            return Matrix3(values: values)
        }
        func table(dims: UInt16, data: UInt16, encoding: UInt16, _ label: String) throws -> HueSatTable? {
            guard let dataEntry = entries[data] else { return nil }
            guard let dimsEntry = entries[dims] else { throw DNGProfileError.invalidTag(label) }
            let dimensions = try reader.numbers(dimsEntry).map(Int.init)
            guard dimensions.count == 3, (1...360).contains(dimensions[0]), (2...256).contains(dimensions[1]),
                  (1...256).contains(dimensions[2]) else { throw DNGProfileError.invalidTag(label) }
            let deltas = try reader.numbers(dataEntry).map(Float.init)
            guard deltas.count == dimensions[0] * dimensions[1] * dimensions[2] * 3, deltas.allSatisfy(\.isFinite) else {
                throw DNGProfileError.invalidTag(label)
            }
            let encodingValue = try entries[encoding].map { try reader.numbers($0).first ?? 0 } ?? 0
            return HueSatTable(hueDivisions: dimensions[0], saturationDivisions: dimensions[1],
                               valueDivisions: dimensions[2], deltas: deltas, isSRGBEncoded: encodingValue == 1)
        }

        var profile = DNGProfile(name: name, baselineExposureOffset: 0)
        profile.uniqueCameraModel = entries[50708].flatMap(reader.string)
        profile.illuminant1 = try entries[50778].flatMap { try reader.numbers($0).first }.map(Int.init)
        profile.illuminant2 = try entries[50779].flatMap { try reader.numbers($0).first }.map(Int.init)
        profile.forwardMatrix1 = try matrix(50964, "ForwardMatrix1")
        profile.forwardMatrix2 = try matrix(50965, "ForwardMatrix2")
        profile.hueSatMap1 = try table(dims: 50937, data: 50938, encoding: 51107, "HueSatMap")
        profile.hueSatMap2 = try table(dims: 50937, data: 50939, encoding: 51107, "HueSatMap")
        profile.lookTable = try table(dims: 50981, data: 50982, encoding: 51108, "LookTable")
        if let entry = entries[50940] {
            let values = try reader.numbers(entry)
            guard values.count >= 4, values.count.isMultiple(of: 2) else { throw DNGProfileError.invalidTag("ProfileToneCurve") }
            let points = stride(from: 0, to: values.count, by: 2).map { SIMD2(values[$0], values[$0 + 1]) }
            var previous = -Double.infinity
            for point in points {
                guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
                      point.x > previous else { throw DNGProfileError.invalidTag("ProfileToneCurve") }
                previous = point.x
            }
            profile.toneCurve = points
        }
        if let entry = entries[51109] {
            guard let value = try reader.numbers(entry).first, value.isFinite, (-4...4).contains(value) else {
                throw DNGProfileError.invalidTag("BaselineExposureOffset")
            }
            profile.baselineExposureOffset = value
        }
        return profile
    }

    init(name: String, baselineExposureOffset: Double) {
        self.name = name
        self.baselineExposureOffset = baselineExposureOffset
    }

    /// 중립 색온도 T에서 첫 번째 표준광 값의 가중치(0…1). DNG SDK처럼 역 색온도로 보간한다.
    func illuminantWeight(temperature: Double) -> Double {
        guard let first = illuminant1.flatMap(Self.temperature(ofIlluminant:)),
              let second = illuminant2.flatMap(Self.temperature(ofIlluminant:)), first != second,
              temperature.isFinite, temperature > 0 else { return 1 }
        let (low, high, lowIsFirst) = first < second ? (first, second, true) : (second, first, false)
        let weightOfLow: Double
        if temperature <= low { weightOfLow = 1 }
        else if temperature >= high { weightOfLow = 0 }
        else { weightOfLow = (1 / temperature - 1 / high) / (1 / low - 1 / high) }
        return lowIsFirst ? weightOfLow : 1 - weightOfLow
    }

    func forwardMatrix(weight: Double) -> Matrix3? {
        switch (forwardMatrix1, forwardMatrix2) {
        case let (first?, second?): Matrix3.blend(first, second, weightOfA: weight)
        case let (first?, nil): first
        case let (nil, second?): second
        default: nil
        }
    }

    func hueSatMap(weight: Double) -> HueSatTable? {
        switch (hueSatMap1, hueSatMap2) {
        case let (first?, second?): first.blended(with: second, weightOfSelf: weight)
        case let (first?, nil): first
        case let (nil, second?): second
        default: nil
        }
    }

    /// EXIF LightSource 값의 색온도(K). DNG SDK의 표와 같다.
    static func temperature(ofIlluminant code: Int) -> Double? {
        switch code {
        case 1, 4, 9: 5500
        case 2, 14: 4200
        case 3: 2850
        case 10: 6500
        case 11: 7500
        case 12: 6400
        case 13: 5000
        case 15: 3450
        case 17: 2856
        case 18: 4874
        case 19: 6774
        case 20: 5503
        case 21: 6504
        case 22: 7504
        case 23: 5003
        case 24: 3200
        default: nil
        }
    }
}

/// DCP의 색 변환을 선형 sRGB(D65) 값에 적용한다. 계약: docs/camera-profiles-calibration-contract.md
struct DNGProfileTransform: Sendable {
    /// 선형 sRGB → XYZ(D50), Bradford 순응.
    static let sRGBToXYZ = Matrix3(values: [0.4360747, 0.3850649, 0.1430804,
                                            0.2225045, 0.7168786, 0.0606169,
                                            0.0139322, 0.0971045, 0.7141733])
    /// ProPhoto 선형 RGB → XYZ(D50).
    static let proPhotoToXYZ = Matrix3(values: [0.7976749, 0.1351917, 0.0313534,
                                                0.2880402, 0.7118741, 0.0000857,
                                                0, 0, 0.8252100])

    let toProPhoto: Matrix3
    let toSRGB: Matrix3
    let hueSatMap: DNGProfile.HueSatTable?
    let exposureScale: Double
    let lookTable: DNGProfile.HueSatTable?
    let toneCurve: [SIMD2<Double>]?

    /// `reference`는 같은 카메라의 Adobe Standard다. macOS 현상 결과를 그 프로필의 색 측정 결과로 보고 카메라 RGB를 되돌린다.
    init(profile: DNGProfile, reference: DNGProfile?, temperature: Double) {
        let weight = profile.illuminantWeight(temperature: temperature)
        var difference = Matrix3.identity
        if let forward = profile.forwardMatrix(weight: weight),
           let base = (reference ?? profile).forwardMatrix(weight: (reference ?? profile).illuminantWeight(temperature: temperature)),
           let baseInverse = base.inverse {
            difference = forward * baseInverse
        }
        let xyzToProPhoto = Self.proPhotoToXYZ.inverse!
        toProPhoto = xyzToProPhoto * difference * Self.sRGBToXYZ
        toSRGB = Self.sRGBToXYZ.inverse! * Self.proPhotoToXYZ
        hueSatMap = profile.hueSatMap(weight: weight)
        exposureScale = pow(2, profile.baselineExposureOffset)
        lookTable = profile.lookTable
        toneCurve = profile.toneCurve
    }

    func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var value = toProPhoto.apply(rgb)
        value = SIMD3(max(0, value.x), max(0, value.y), max(0, value.z))
        if let hueSatMap { value = Self.applying(hueSatMap, to: value) }
        value *= exposureScale
        if let lookTable { value = Self.applying(lookTable, to: value) }
        if let toneCurve { value = Self.applyingTone(toneCurve, to: value) }
        return toSRGB.apply(value)
    }

    /// DNG SDK `RefBaselineHueSatMap`과 같은 보간. 1보다 큰 명도는 1에서 구한 배율을 그대로 곱해 자르지 않는다.
    static func applying(_ table: DNGProfile.HueSatTable, to rgb: SIMD3<Double>) -> SIMD3<Double> {
        var (h, s, v) = hsv(rgb)
        guard v > 0 else { return rgb }
        let limited = min(v, 1)
        let encoded = table.isSRGBEncoded ? srgbEncode(limited) : limited
        let hueScale = table.hueDivisions < 2 ? 0 : Double(table.hueDivisions) / 6
        let hueScaled = h * hueScale
        let satScaled = s * Double(table.saturationDivisions - 1)
        var hue0 = Int(hueScaled)
        let sat0 = min(Int(satScaled), table.saturationDivisions - 2)
        var hue1 = hue0 + 1
        if hue0 >= table.hueDivisions - 1 { hue0 = table.hueDivisions - 1; hue1 = 0 }
        let hueFraction = hueScaled - Double(hue0)
        let satFraction = satScaled - Double(sat0)
        let hueStep = table.saturationDivisions
        let valueStep = table.hueDivisions * hueStep

        func entry(_ index: Int) -> SIMD3<Double> {
            SIMD3(Double(table.deltas[index * 3]), Double(table.deltas[index * 3 + 1]), Double(table.deltas[index * 3 + 2]))
        }
        func plane(_ valueIndex: Int) -> SIMD3<Double> {
            let base0 = valueIndex * valueStep + hue0 * hueStep + sat0
            let base1 = valueIndex * valueStep + hue1 * hueStep + sat0
            let low = (1 - hueFraction) * entry(base0) + hueFraction * entry(base1)
            let high = (1 - hueFraction) * entry(base0 + 1) + hueFraction * entry(base1 + 1)
            return (1 - satFraction) * low + satFraction * high
        }
        let modify: SIMD3<Double>
        if table.valueDivisions < 2 {
            modify = plane(0)
        } else {
            let valueScaled = encoded * Double(table.valueDivisions - 1)
            let value0 = min(Int(valueScaled), table.valueDivisions - 2)
            let valueFraction = valueScaled - Double(value0)
            modify = (1 - valueFraction) * plane(value0) + valueFraction * plane(value0 + 1)
        }
        h += modify.x * 6 / 360
        s = min(s * modify.y, 1)
        let changedEncoded = min(1, max(0, encoded * modify.z))
        let changed = table.isSRGBEncoded ? srgbDecode(changedEncoded) : changedEncoded
        v = v > 1 ? v * changed : changed
        return rgbFromHSV(h, s, v)
    }

    /// DNG SDK `RefBaselineRGBTone`: 가장 큰·작은 채널에 곡선을 걸고 가운데 채널은 둘 사이의 비율을 유지한다.
    static func applyingTone(_ curve: [SIMD2<Double>], to rgb: SIMD3<Double>) -> SIMD3<Double> {
        let channels = [min(1, max(0, rgb.x)), min(1, max(0, rgb.y)), min(1, max(0, rgb.z))]
        let order = (0..<3).sorted { channels[$0] > channels[$1] }
        let high = channels[order[0]], middle = channels[order[1]], low = channels[order[2]]
        let highOut = interpolate(curve, high)
        let lowOut = interpolate(curve, low)
        let middleOut = high > low ? lowOut + (highOut - lowOut) * (middle - low) / (high - low) : interpolate(curve, middle)
        var result = [0.0, 0.0, 0.0]
        result[order[0]] = highOut
        result[order[1]] = middleOut
        result[order[2]] = lowOut
        return SIMD3(result[0], result[1], result[2])
    }

    static func interpolate(_ curve: [SIMD2<Double>], _ x: Double) -> Double {
        guard let first = curve.first, let last = curve.last else { return x }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        var low = 0, high = curve.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if curve[mid].x <= x { low = mid } else { high = mid }
        }
        let a = curve[low], b = curve[high]
        return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    }

    /// DNG SDK의 HSV: 색조 0…6, 채도 0…1, 명도 = 가장 큰 채널.
    static func hsv(_ rgb: SIMD3<Double>) -> (Double, Double, Double) {
        let v = max(rgb.x, rgb.y, rgb.z)
        let gap = v - min(rgb.x, rgb.y, rgb.z)
        guard gap > 0, v > 0 else { return (0, 0, v) }
        var h: Double
        if rgb.x == v {
            h = (rgb.y - rgb.z) / gap
            if h < 0 { h += 6 }
        } else if rgb.y == v {
            h = 2 + (rgb.z - rgb.x) / gap
        } else {
            h = 4 + (rgb.x - rgb.y) / gap
        }
        return (h, gap / v, v)
    }

    static func rgbFromHSV(_ hue: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        guard s > 0 else { return SIMD3(repeating: v) }
        var h = hue.truncatingRemainder(dividingBy: 6)
        if h < 0 { h += 6 }
        let i = min(5, Int(h))
        let f = h - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    static func srgbEncode(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func srgbDecode(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
}

/// DCP를 읽는 데 필요한 만큼의 TIFF IFD0 읽기. 매직 42(TIFF)와 0x4352(DCP)를 받는다.
private struct TIFFReader {
    struct Entry { let type: UInt16; let count: Int; let valueOffset: Int }

    let data: Data
    let littleEndian: Bool

    init(_ data: Data) throws {
        guard data.count >= 8 else { throw DNGProfileError.notProfile }
        self.data = data
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw DNGProfileError.notProfile
        }
        let magic = try u16(2)
        guard magic == 42 || magic == 0x4352 else { throw DNGProfileError.notProfile }
    }

    func entries() throws -> [UInt16: Entry] {
        let offset = Int(try u32(4))
        let count = Int(try u16(offset))
        guard count <= 4096 else { throw DNGProfileError.notProfile }
        var result: [UInt16: Entry] = [:]
        for index in 0..<count {
            let start = offset + 2 + index * 12
            let tag = try u16(start)
            let type = try u16(start + 2)
            let valueCount = Int(try u32(start + 4))
            guard let size = Self.size(of: type) else { continue }
            let (bytes, overflow) = size.multipliedReportingOverflow(by: valueCount)
            guard !overflow, bytes <= data.count else { throw DNGProfileError.truncated }
            let valueOffset = bytes <= 4 ? start + 8 : Int(try u32(start + 8))
            guard valueOffset >= 0, valueOffset + bytes <= data.count else { throw DNGProfileError.truncated }
            result[tag] = Entry(type: type, count: valueCount, valueOffset: valueOffset)
        }
        return result
    }

    func string(_ entry: Entry) -> String? {
        guard entry.type == 2 || entry.type == 1 else { return nil }
        let start = data.startIndex + entry.valueOffset
        let bytes = data[start..<(start + entry.count)].prefix { $0 != 0 }
        return String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: .isoLatin1)
    }

    func numbers(_ entry: Entry) throws -> [Double] {
        guard let size = Self.size(of: entry.type) else { throw DNGProfileError.notProfile }
        return try (0..<entry.count).map { index in
            let at = entry.valueOffset + index * size
            switch entry.type {
            case 1, 7: return Double(data[data.startIndex + at])
            case 3: return Double(try u16(at))
            case 4: return Double(try u32(at))
            case 8: return Double(Int16(bitPattern: try u16(at)))
            case 9: return Double(Int32(bitPattern: try u32(at)))
            case 5:
                let denominator = Double(try u32(at + 4))
                return denominator == 0 ? .nan : Double(try u32(at)) / denominator
            case 10:
                let denominator = Double(Int32(bitPattern: try u32(at + 4)))
                return denominator == 0 ? .nan : Double(Int32(bitPattern: try u32(at))) / denominator
            case 11: return Double(Float(bitPattern: try u32(at)))
            case 12: return Double(bitPattern: try u64(at))
            default: throw DNGProfileError.notProfile
            }
        }
    }

    private static func size(of type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11: 4
        case 5, 10, 12: 8
        default: nil
        }
    }

    private func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
        guard offset >= 0, offset + count <= data.count else { throw DNGProfileError.truncated }
        let start = data.startIndex + offset
        let slice = Array(data[start..<(start + count)])
        return littleEndian ? slice : slice.reversed()
    }

    private func u16(_ offset: Int) throws -> UInt16 {
        let b = try bytes(offset, 2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    private func u32(_ offset: Int) throws -> UInt32 {
        let b = try bytes(offset, 4)
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1]) << (8 * UInt32($1)) }
    }

    private func u64(_ offset: Int) throws -> UInt64 {
        let b = try bytes(offset, 8)
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) }
    }
}
