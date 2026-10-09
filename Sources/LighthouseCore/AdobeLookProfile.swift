import Foundation

public enum AdobeLookProfileError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case unreadable
    case notLook
    case invalidTable
    case unsupportedTable

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Adobe 프로필 파일은 4 MiB 이하여야 합니다."
        case .unreadable: "Adobe 프로필 XMP를 읽을 수 없습니다."
        case .notLook: "Adobe Raw 프로필(Look)이 아닙니다."
        case .invalidTable: "Adobe 프로필의 색 표가 올바르지 않습니다."
        case .unsupportedTable: "지원하지 않는 종류의 Adobe 프로필 색 표입니다."
        }
    }
}

/// Camera Raw의 Look XMP 프로필. "Adobe Raw"(Adobe Color 등)와 크리에이티브 프로필(Artistic 등)이 같은 형식이다.
/// 색 표(LookTable·RGBTable)·톤 곡선·기본 조정을 담는다.
/// 계약: docs/camera-profiles-calibration-contract.md "Adobe Raw 프로필", "크리에이티브 프로필"
public struct AdobeLookProfile: Equatable, Sendable {
    public static let maximumFileSize = 4 * 1024 * 1024

    public var name: String
    /// 기준 DCP 이름. Adobe Raw 프로필은 "Adobe Standard"이고 크리에이티브 프로필은 없다.
    public var baseProfile: String?
    public var lookTable: DNGProfile.HueSatTable?
    public var rgbTable: RGBLookTable?
    /// 프로필이 정한 RGB 표 양. 사용자 "프로필 양"을 곱해 쓴다.
    public var rgbTableAmount: Double
    public var supportsAmount: Bool
    /// 현상 직후 sRGB 인코딩 값에 거는 곡선(0…1).
    public var curves: ToneCurves
    /// Lighthouse가 쓰는 프로필 속 설정(Adobe 단위). 키는 `supportedSettingKeys`다.
    public var settings: [String: Double]
    public var isMonochrome: Bool

    public init(name: String, baseProfile: String?, lookTable: DNGProfile.HueSatTable?, rgbTable: RGBLookTable? = nil,
                rgbTableAmount: Double = 1, supportsAmount: Bool = false, curves: ToneCurves = ToneCurves(),
                settings: [String: Double] = [:], isMonochrome: Bool = false) {
        self.name = name
        self.baseProfile = baseProfile
        self.lookTable = lookTable
        self.rgbTable = rgbTable
        self.rgbTableAmount = rgbTableAmount
        self.supportsAmount = supportsAmount
        self.curves = curves
        self.settings = settings
        self.isMonochrome = isMonochrome
    }

    /// 프로필 속 설정 중 Lighthouse가 반영하는 것. 나머지(파라메트릭 곡선 등)는 적용하지 않는다.
    static let supportedSettingKeys: Set<String> = {
        var keys: Set<String> = ["Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012",
                                 "Blacks2012", "Clarity2012", "Saturation", "Vibrance", "PostCropVignetteAmount",
                                 "SplitToningShadowHue", "SplitToningShadowSaturation", "SplitToningHighlightHue",
                                 "SplitToningHighlightSaturation", "SplitToningBalance"]
        for band in ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"] {
            keys.formUnion(["HueAdjustment\(band)", "SaturationAdjustment\(band)", "LuminanceAdjustment\(band)",
                            "GrayMixer\(band)"])
        }
        return keys
    }()

    public static func load(url: URL) throws -> AdobeLookProfile {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw AdobeLookProfileError.tooLarge }
        return try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> AdobeLookProfile {
        guard data.count <= maximumFileSize, let text = String(data: data, encoding: .utf8) else {
            throw AdobeLookProfileError.unreadable
        }
        let lower = text.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity") else { throw AdobeLookProfileError.unreadable }
        let delegate = LookXMPDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw AdobeLookProfileError.unreadable }
        let attributes = delegate.attributes
        guard attributes["PresetType"]?.caseInsensitiveCompare("Look") == .orderedSame,
              let name = delegate.name ?? attributes["Name"], !name.isEmpty else {
            throw AdobeLookProfileError.notLook
        }
        func table(_ key: String) -> String? { attributes[key].flatMap { attributes["Table_" + $0] } }
        let lookTable = try table("LookTable").map(decodeTable)
        let rgbTable = try table("RGBTable").map { try RGBLookTable.decode(decodeBlock($0)) }
        guard lookTable != nil || rgbTable != nil else { throw AdobeLookProfileError.notLook }
        var settings: [String: Double] = [:]
        for key in supportedSettingKeys {
            guard let raw = attributes[key] else { continue }
            let limit: ClosedRange<Double> = key == "Exposure2012" ? -5...5 : key.hasSuffix("Hue") && key.hasPrefix("Split")
                ? 0...360 : -100...100
            guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, limit.contains(value) else {
                throw AdobeLookProfileError.unreadable
            }
            settings[key] = value
        }
        var rgbTableAmount = 1.0
        if let raw = attributes["RGBTableAmount"] {
            guard let value = Double(raw), value.isFinite, (0...4).contains(value) else { throw AdobeLookProfileError.unreadable }
            rgbTableAmount = value
        }
        var curves = ToneCurves()
        for (key, path) in [("ToneCurvePV2012", \ToneCurves.master), ("ToneCurvePV2012Red", \ToneCurves.red),
                            ("ToneCurvePV2012Green", \ToneCurves.green), ("ToneCurvePV2012Blue", \ToneCurves.blue)] {
            guard let pairs = delegate.curves[key] else { continue }
            let points = pairs.map { CurvePoint(x: $0.0 / 255, y: $0.1 / 255) }
            guard points.first?.x == 0, points.last?.x == 1 else { throw AdobeLookProfileError.unreadable }
            curves[keyPath: path] = points
        }
        do { try curves.validate() } catch { throw AdobeLookProfileError.unreadable }
        return AdobeLookProfile(
            name: name, baseProfile: attributes["CameraProfile"], lookTable: lookTable, rgbTable: rgbTable,
            rgbTableAmount: rgbTableAmount,
            supportsAmount: attributes["SupportsAmount"]?.caseInsensitiveCompare("True") == .orderedSame,
            curves: curves, settings: settings,
            isMonochrome: attributes["ConvertToGrayscale"]?.caseInsensitiveCompare("True") == .orderedSame)
    }

    /// 사용자 프로필 양(0…2)에서 RGB 표에 쓸 양. 표의 최소·최대 양으로 자른다.
    func rgbAmount(profileAmount: Double) -> Double {
        guard let rgbTable else { return 0 }
        let amount = rgbTableAmount * (supportsAmount ? min(2, max(0, profileAmount)) : 1)
        return min(rgbTable.maximumAmount, max(rgbTable.minimumAmount, amount))
    }

    /// 곡선을 항등선과 섞는다(프로필 양).
    func curves(amount: Double) -> ToneCurves {
        guard amount != 1 else { return curves }
        func blend(_ points: [CurvePoint]) -> [CurvePoint] {
            points.map { CurvePoint(x: $0.x, y: min(1, max(0, $0.x + amount * ($0.y - $0.x)))) }
        }
        return ToneCurves(master: blend(curves.master), red: blend(curves.red), green: blend(curves.green),
                          blue: blend(curves.blue))
    }

    /// DNG SDK의 큰 표 문자열: 85문자 인코딩 → (압축 전 길이 4바이트 + zlib) → 리틀 엔디언 LookTable.
    static func decodeTable(_ encoded: String) throws -> DNGProfile.HueSatTable {
        let raw = try decodeBlock(encoded)
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[raw.startIndex + offset + $1]) << (8 * UInt32($1)) }
        }
        guard raw.count >= 24 else { throw AdobeLookProfileError.invalidTable }
        guard u32(0) == 0 else { throw AdobeLookProfileError.unsupportedTable }
        let hue = Int(u32(8)), saturation = Int(u32(12)), value = Int(u32(16))
        guard (1...360).contains(hue), (2...256).contains(saturation), (1...256).contains(value) else {
            throw AdobeLookProfileError.invalidTable
        }
        let count = hue * saturation * value * 3
        guard raw.count >= 20 + count * 4 + 4 else { throw AdobeLookProfileError.invalidTable }
        let deltas = (0..<count).map { Float(bitPattern: u32(20 + $0 * 4)) }
        guard deltas.allSatisfy(\.isFinite) else { throw AdobeLookProfileError.invalidTable }
        return DNGProfile.HueSatTable(hueDivisions: hue, saturationDivisions: saturation, valueDivisions: value,
                                      deltas: deltas, isSRGBEncoded: u32(20 + count * 4) == 1)
    }

    /// 표 문자열을 풀어 표 바이트를 낸다.
    static func decodeBlock(_ encoded: String) throws -> Data {
        let bytes = try decode85(encoded)
        guard bytes.count > 6 else { throw AdobeLookProfileError.invalidTable }
        let expected = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        // zlib 머리(2바이트)와 꼬리(Adler-32, 4바이트)를 떼고 deflate만 푼다.
        guard expected > 0, expected <= 16 * 1024 * 1024, bytes[4] & 0x0F == 8, bytes[5] & 0x20 == 0, bytes.count > 10 else {
            throw AdobeLookProfileError.invalidTable
        }
        let deflate = Data(bytes[6..<(bytes.count - 4)])
        guard let raw = try? (deflate as NSData).decompressed(using: .zlib) as Data, raw.count == expected else {
            throw AdobeLookProfileError.invalidTable
        }
        return raw
    }

    static let encodingAlphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#")

    /// 5자마다 4바이트(낮은 자리부터 85진수). 마지막 n자는 n-1바이트다.
    static func decode85(_ text: String) throws -> [UInt8] {
        var lookup = [UInt8](repeating: 255, count: 256)
        for (index, character) in encodingAlphabet.enumerated() { lookup[Int(character.asciiValue!)] = UInt8(index) }
        let powers: [UInt64] = [1, 85, 7225, 614_125, 52_200_625]
        var result: [UInt8] = []
        result.reserveCapacity(text.utf8.count * 4 / 5)
        var value: UInt64 = 0
        var digits = 0
        func flush() throws {
            guard digits >= 2 else {
                if digits == 1 { throw AdobeLookProfileError.invalidTable }
                return
            }
            guard value <= UInt64(UInt32.max) else { throw AdobeLookProfileError.invalidTable }
            for byte in 0..<(digits - 1) { result.append(UInt8((value >> (8 * UInt64(byte))) & 0xFF)) }
            value = 0
            digits = 0
        }
        for byte in text.utf8 {
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { continue }
            let digit = lookup[Int(byte)]
            guard digit != 255 else { throw AdobeLookProfileError.invalidTable }
            value += UInt64(digit) * powers[digits]
            digits += 1
            if digits == 5 { try flush() }
        }
        try flush()
        return result
    }
}

/// Look XMP의 crs 속성과 곡선·이름 요소를 모은다. 이름공간은 `crs:` 접두사로만 구분한다.
private final class LookXMPDelegate: NSObject, XMLParserDelegate {
    private(set) var attributes: [String: String] = [:]
    private(set) var curves: [String: [(Double, Double)]] = [:]
    private(set) var name: String?
    private var element: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        element.append(elementName)
        if elementName == "rdf:Description" {
            for (key, value) in attributeDict where key.hasPrefix("crs:") { attributes[String(key.dropFirst(4))] = value }
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "rdf:li", let owner = element.dropLast().last(where: { $0.hasPrefix("crs:") }) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = String(owner.dropFirst(4))
            if key == "Name" {
                if name == nil, !value.isEmpty { name = value }
            } else if key.hasPrefix("ToneCurvePV2012") {
                let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, let x = parts[0], let y = parts[1] { curves[key, default: []].append((x, y)) }
                else { parser.abortParsing() }
            }
        } else if elementName.hasPrefix("crs:"), element.count >= 2, element[element.count - 2] == "rdf:Description" {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { attributes[String(elementName.dropFirst(4))] = value }
        }
        element.removeLast()
        text = ""
    }
}
