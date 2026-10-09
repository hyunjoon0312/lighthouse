import Foundation

public enum LightroomPresetImportError: LocalizedError, Equatable, Sendable {
    case unsupportedFile(String)
    case fileTooLarge
    case invalidEncoding
    case unsafeXML
    case invalidXML(String)
    case unrelatedXML
    case conflictingValue(String)
    case invalidValue(String)
    case unsupportedPresetType(String)
    case invalidTemplate(String)
    case emptyPreset

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): "지원하지 않는 프리셋 파일입니다: \(name)"
        case .fileTooLarge: "프리셋 파일은 2 MiB 이하여야 합니다."
        case .invalidEncoding: "프리셋은 UTF-8 텍스트여야 합니다."
        case .unsafeXML: "DTD 또는 entity가 포함된 XMP는 읽을 수 없습니다."
        case .invalidXML(let reason): "XMP를 읽을 수 없습니다: \(reason)"
        case .unrelatedXML: "Camera Raw 설정이 없는 XML입니다."
        case .conflictingValue(let key): "서로 다른 값이 반복된 설정입니다: \(key)"
        case .invalidValue(let key): "Lightroom 설정값이 올바르지 않습니다: \(key)"
        case .unsupportedPresetType(let type): "현상 프리셋이 아닙니다: \(type)"
        case .invalidTemplate(let reason): "lrtemplate을 읽을 수 없습니다: \(reason)"
        case .emptyPreset: "지원하는 보정값이 없는 프리셋입니다."
        }
    }
}

public enum LightroomPresetImporter {
    public static let maximumFileSize = 2 * 1024 * 1024

    public static func load(url: URL) throws -> EditPreset {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw LightroomPresetImportError.unsupportedFile(url.lastPathComponent)
        }
        if let size = values.fileSize, size > maximumFileSize {
            throw LightroomPresetImportError.fileTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        guard data.count <= maximumFileSize else { throw LightroomPresetImportError.fileTooLarge }
        return try parse(data: data, fileName: url.lastPathComponent)
    }

    public static func parse(data: Data, fileName: String) throws -> EditPreset {
        guard data.count <= maximumFileSize else { throw LightroomPresetImportError.fileTooLarge }
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "xmp": return try parseXMP(data: data, fileName: fileName)
        case "lrtemplate": return try parseLRTemplate(data: data, fileName: fileName)
        default: throw LightroomPresetImportError.unsupportedFile(fileName)
        }
    }

    private static func parseXMP(data: Data, fileName: String) throws -> EditPreset {
        guard let source = String(data: data, encoding: .utf8), !source.contains("\0") else {
            throw LightroomPresetImportError.invalidEncoding
        }
        let lower = source.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity") else {
            throw LightroomPresetImportError.unsafeXML
        }
        let delegate = XMPDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            if let failure = delegate.failure { throw failure }
            throw LightroomPresetImportError.invalidXML(parser.parserError?.localizedDescription ?? "잘못된 XML")
        }
        guard delegate.sawCameraRawNamespace else { throw LightroomPresetImportError.unrelatedXML }
        return try makePreset(
            format: "xmp",
            fileName: fileName,
            suppliedName: delegate.preferredName,
            rawScalars: delegate.scalars,
            curves: delegate.curves,
            unsupportedKeys: delegate.unsupportedKeys,
            presetType: delegate.presetType
        )
    }

    private static func parseLRTemplate(data: Data, fileName: String) throws -> EditPreset {
        guard let source = String(data: data, encoding: .utf8), !source.contains("\0") else {
            throw LightroomPresetImportError.invalidEncoding
        }
        var literalParser = try LuaLiteralParser(source: source)
        let root = try literalParser.parse()
        guard case .table(let rootTable) = root else {
            throw LightroomPresetImportError.invalidTemplate("최상위 table이 없습니다")
        }
        let value = rootTable["value"]?.tableValue
        let settings = value?["settings"]?.tableValue ?? rootTable["settings"]?.tableValue
        guard let settings else { throw LightroomPresetImportError.invalidTemplate("settings table이 없습니다") }
        let type = rootTable["type"]?.stringValue ?? value?["type"]?.stringValue
        let rootName = rootTable["title"]?.stringValue ?? rootTable["name"]?.stringValue
        let valueName = value?["title"]?.stringValue ?? value?["name"]?.stringValue
        let name = rootName ?? valueName
        var scalars: [String: String] = [:]
        var curveSources: [String: [CurvePoint]] = [:]
        var encounteredCurveKeys = Set<String>()
        var unsupported = Set<String>()
        for (key, value) in settings {
            if curveChannel(for: key) != nil {
                encounteredCurveKeys.insert(key)
                guard let points = curvePoints(from: value) else {
                    unsupported.insert(key)
                    continue
                }
                curveSources[key] = points
            } else if LightroomPresetPayload.scalarRanges[key] != nil {
                guard let number = value.numberValue else {
                    throw LightroomPresetImportError.invalidValue(key)
                }
                scalars[key] = String(number)
            } else if key == "CameraProfile" {
                guard let profile = value.stringValue else {
                    throw LightroomPresetImportError.invalidValue(key)
                }
                scalars[key] = profile
            } else if key == "Look" {
                guard let look = value.tableValue else { throw LightroomPresetImportError.invalidValue(key) }
                let entries = Dictionary(look.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
                if let lookName = entries["name"]?.stringValue { scalars["LookName"] = lookName } else { unsupported.insert(key) }
                if let amount = entries["amount"] {
                    guard let number = amount.numberValue else { throw LightroomPresetImportError.invalidValue(key) }
                    scalars["LookAmount"] = String(number)
                }
            } else if key == "WhiteBalance" {
                guard let name = value.stringValue else {
                    throw LightroomPresetImportError.invalidValue(key)
                }
                scalars[key] = name
            } else if key == "ConvertToGrayscale" {
                guard let enabled = value.booleanValue else {
                    throw LightroomPresetImportError.invalidValue(key)
                }
                scalars[key] = enabled ? "true" : "false"
            } else if isUnsupportedSetting(key) {
                unsupported.insert(key)
            } else if value.tableValue != nil {
                unsupported.insert(key)
            } else if !isMetadataKey(key) {
                unsupported.insert(key)
            }
        }
        let curves = preferredCurves(from: curveSources, encountered: encounteredCurveKeys)
        return try makePreset(format: "lrtemplate", fileName: fileName, suppliedName: name,
                              rawScalars: scalars, curves: curves, unsupportedKeys: unsupported,
                              presetType: type)
    }

    private static func makePreset(format: String, fileName: String, suppliedName: String?,
                                   rawScalars: [String: String], curves rawCurves: [String: [CurvePoint]],
                                   unsupportedKeys: Set<String>, presetType: String?) throws -> EditPreset {
        if let type = presetType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
            let allowed = format == "xmp"
                ? type.caseInsensitiveCompare("Normal") == .orderedSame
                : type.caseInsensitiveCompare("Develop") == .orderedSame
            guard allowed else { throw LightroomPresetImportError.unsupportedPresetType(type) }
        }
        var scalars: [String: Double] = [:]
        let excluded = rawScalars["LookName"] == nil ? unsupportedKeys : unsupportedKeys.subtracting(["Look"])
        var warnings = excluded.sorted().map { "지원하지 않아 제외: \($0)" }
        var consumed = Set<String>()
        let aliases = [("Exposure2012", "Exposure"), ("Contrast2012", "Contrast"), ("Clarity2012", "Clarity")]
        for (modern, legacy) in aliases {
            if let raw = rawScalars[modern] {
                scalars[modern] = try validatedScalar(raw, key: modern)
                consumed.formUnion([modern, legacy])
            } else if let raw = rawScalars[legacy] {
                scalars[legacy] = try validatedScalar(raw, key: legacy)
                consumed.insert(legacy)
            }
        }
        for (key, raw) in rawScalars where !consumed.contains(key) {
            guard LightroomPresetPayload.scalarRanges[key] != nil else { continue }
            scalars[key] = try validatedScalar(raw, key: key)
        }
        var colorProfile: PhotoColorProfile?
        var cameraProfile: String?
        if let raw = rawScalars["CameraProfile"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed.lowercased() {
            case "default color", "color":
                colorProfile = .color
                warnings.append("CameraProfile을 Lighthouse 기본 색상으로 매핑; Adobe/카메라 전용 프로필과 결과가 다를 수 있습니다.")
            case "default monochrome", "monochrome":
                colorProfile = .monochrome
                warnings.append("CameraProfile을 Lighthouse 기본 흑백으로 매핑; Adobe/카메라 전용 프로필과 결과가 다를 수 있습니다.")
            default:
                if LightroomPresetPayload.isDNGProfileName(trimmed), trimmed.count <= 128 {
                    cameraProfile = trimmed
                    colorProfile = .color
                    warnings.append("카메라 프로필은 이 Mac에 설치된 DCP로 근사하며 Adobe 결과와 다를 수 있습니다.")
                } else {
                    warnings.append("지원하지 않아 제외: CameraProfile (\(raw))")
                }
            }
        }
        var profileAmount: Double?
        if let lookName = rawScalars["LookName"]?.trimmingCharacters(in: .whitespacesAndNewlines), !lookName.isEmpty {
            if LightroomPresetPayload.isDNGProfileName(lookName), lookName.count <= 128 {
                cameraProfile = lookName
                warnings.append("카메라 프로필은 이 Mac에 설치된 DCP로 근사하며 Adobe 결과와 다를 수 있습니다.")
                if let raw = rawScalars["LookAmount"] {
                    guard let amount = Double(raw.trimmingCharacters(in: .whitespaces)), amount.isFinite,
                          (0...2).contains(amount) else { throw LightroomPresetImportError.invalidValue("Look") }
                    profileAmount = amount
                }
            } else {
                warnings.append("지원하지 않아 제외: Look (\(lookName))")
            }
        }
        var whiteBalance: String?
        if let raw = rawScalars["WhiteBalance"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            whiteBalance = LightroomPresetPayload.whiteBalanceNames.first {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }
            if whiteBalance == nil { warnings.append("지원하지 않아 제외: WhiteBalance (\(raw))") }
            if whiteBalance == "Auto" { warnings.append("자동 화이트밸런스는 적용하지 않습니다.") }
        }
        if whiteBalance != nil || scalars.keys.contains(where: LightroomPresetPayload.whiteBalanceKeys.contains) {
            warnings.append("화이트밸런스는 macOS RAW 현상의 색온도로 근사하며 Adobe 결과와 다를 수 있습니다.")
        }
        if let raw = rawScalars["ConvertToGrayscale"] {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true":
                colorProfile = .monochrome
                warnings.append("ConvertToGrayscale에 따라 Lighthouse 기본 흑백을 우선 적용합니다.")
            case "false":
                colorProfile = .color
                warnings.append("ConvertToGrayscale에 따라 Lighthouse 기본 색상을 우선 적용합니다.")
            default: throw LightroomPresetImportError.invalidValue("ConvertToGrayscale")
            }
        }
        var curves: [String: [CurvePoint]] = [:]
        for (channel, points) in rawCurves {
            do {
                let candidate = LightroomPresetPayload(format: format, scalars: ["Saturation": 0],
                                                       curves: [channel: points], warnings: [])
                try candidate.validate()
                curves[channel] = points
            } catch {
                warnings.append("형식이 맞지 않아 곡선을 제외: \(channel)")
            }
        }
        if let exposure = scalars["Exposure2012"] ?? scalars["Exposure"], !( -4...4).contains(exposure) {
            warnings.append("노출을 Lighthouse 범위 -4…4로 제한")
        }
        if scalars.keys.contains(where: { key in LightroomPresetPayload.calibrationKeys.contains { $0.0 == key } }) {
            warnings.append("캘리브레이션은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다.")
        }
        if scalars.keys.contains(where: LightroomPresetPayload.colorGradingKeys.contains) {
            warnings.append("컬러 그레이딩은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다.")
        }
        warnings.append("Adobe 현상 엔진과 결과가 다를 수 있습니다.")
        var uniqueWarnings: [String] = []
        for warning in warnings where !uniqueWarnings.contains(warning) { uniqueWarnings.append(warning) }
        let payload = LightroomPresetPayload(format: format, scalars: scalars, curves: curves,
                                              warnings: uniqueWarnings, colorProfile: colorProfile,
                                              whiteBalance: whiteBalance, cameraProfile: cameraProfile,
                                              profileAmount: profileAmount)
        do { try payload.validate() } catch LightroomPresetPayloadError.emptySettings {
            throw LightroomPresetImportError.emptyPreset
        }
        let fallback = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let chosenName = (suppliedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                          ? suppliedName!.trimmingCharacters(in: .whitespacesAndNewlines) : fallback)
        guard !chosenName.isEmpty else { throw LightroomPresetImportError.emptyPreset }
        return EditPreset(name: String(chosenName.prefix(80)), lightroom: payload)
    }

    private static func validatedScalar(_ raw: String, key: String) throws -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            throw LightroomPresetImportError.invalidValue(key)
        }
        guard let range = LightroomPresetPayload.scalarRanges[key], range.contains(value) else {
            throw LightroomPresetImportError.invalidValue(key)
        }
        return value
    }

    fileprivate static func curveChannel(for key: String) -> String? {
        switch key {
        case "ToneCurvePV2012", "ToneCurve": return "master"
        case "ToneCurvePV2012Red": return "red"
        case "ToneCurvePV2012Green": return "green"
        case "ToneCurvePV2012Blue": return "blue"
        default: return nil
        }
    }

    fileprivate static func preferredCurves(from sources: [String: [CurvePoint]],
                                            encountered: Set<String>) -> [String: [CurvePoint]] {
        var result: [String: [CurvePoint]] = [:]
        result["master"] = encountered.contains("ToneCurvePV2012")
            ? sources["ToneCurvePV2012"] : sources["ToneCurve"]
        result["red"] = sources["ToneCurvePV2012Red"]
        result["green"] = sources["ToneCurvePV2012Green"]
        result["blue"] = sources["ToneCurvePV2012Blue"]
        return result
    }

    private static func curvePoints(from value: LuaValue) -> [CurvePoint]? {
        guard case .array(let values) = value else { return nil }
        var pairs: [(Double, Double)] = []
        if values.allSatisfy({ $0.numberValue != nil }), values.count.isMultiple(of: 2) {
            for index in stride(from: 0, to: values.count, by: 2) {
                pairs.append((values[index].numberValue!, values[index + 1].numberValue!))
            }
        } else {
            for item in values {
                guard case .array(let pair) = item, pair.count == 2,
                      let x = pair[0].numberValue, let y = pair[1].numberValue else { return nil }
                pairs.append((x, y))
            }
        }
        return normalizedCurve(pairs)
    }

    fileprivate static func normalizedCurve(_ pairs: [(Double, Double)]) -> [CurvePoint]? {
        guard (2...16).contains(pairs.count) else { return nil }
        let points = pairs.map { CurvePoint(x: $0.0 / 255, y: $0.1 / 255) }
        guard points.first?.x == 0, points.last?.x == 1 else { return nil }
        var previous = -Double.infinity
        for point in points {
            guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x),
                  (0...1).contains(point.y), point.x > previous else { return nil }
            previous = point.x
        }
        return points
    }

    fileprivate static func isMetadataKey(_ key: String) -> Bool {
        let exact: Set<String> = ["Name", "Group", "UUID", "Version", "ProcessVersion", "Copyright",
                                  "ContactInfo", "HasSettings", "PresetType"]
        return exact.contains(key) || key.hasPrefix("Supports")
    }

    fileprivate static func isUnsupportedSetting(_ key: String) -> Bool {
        let prefixes = ["Temperature", "Tint", "IncrementalTemperature", "IncrementalTint", "WhiteBalance",
                        "Whites", "Blacks", "Texture", "Dehaze", "ConvertToGrayscale", "SplitToning",
                        "ColorGrade", "CameraProfile", "Look", "Lens", "Mask", "Retouch", "Gradient",
                        "CircularGradient", "PaintBasedCorrections"]
        return prefixes.contains(where: { key.hasPrefix($0) })
    }
}

private final class XMPDelegate: NSObject, XMLParserDelegate {
    private static let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private struct Node { let local: String; let uri: String? }
    private var stack: [Node] = []
    private var prefixURIs: [String: [String]] = [:]
    private var rootRDFDepth: Int?
    private var scalarCapture: (key: String, depth: Int, text: String)?
    private var globalDescriptionDepth: Int?
    private var nameDepth: Int?
    /// `crs:Look` 요소의 깊이. 안의 Name·Amount만 읽고 표 등 나머지는 건너뛴다.
    private var lookDepth: Int?
    private var curveCapture: (key: String, depth: Int)?
    private var itemCapture: (depth: Int, text: String, language: String?)?
    private var names: [(String?, String)] = []
    private(set) var scalars: [String: String] = [:]
    private var curveSources: [String: [CurvePoint]] = [:]
    private var encounteredCurveKeys = Set<String>()
    private(set) var unsupportedKeys = Set<String>()
    private(set) var presetType: String?
    private(set) var sawCameraRawNamespace = false
    private(set) var failure: LightroomPresetImportError?

    var curves: [String: [CurvePoint]] {
        LightroomPresetImporter.preferredCurves(from: curveSources, encountered: encounteredCurveKeys)
    }

    var preferredName: String? {
        names.first(where: { $0.0 == "x-default" })?.1 ?? names.first?.1
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixURIs[prefix, default: []].append(namespaceURI)
        if namespaceURI == Self.crs { sawCameraRawNamespace = true }
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        prefixURIs[prefix]?.removeLast()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard failure == nil else { return }
        let parent = stack.last
        stack.append(Node(local: elementName, uri: namespaceURI))
        if namespaceURI == Self.crs { sawCameraRawNamespace = true }
        if namespaceURI == Self.rdf, elementName == "RDF", rootRDFDepth == nil {
            rootRDFDepth = stack.count
        }
        if let scalarCapture, stack.count > scalarCapture.depth {
            fail(.invalidValue(scalarCapture.key), parser: parser)
            return
        }
        if namespaceURI == Self.rdf, elementName == "Description",
           parent?.uri == Self.rdf, parent?.local == "RDF", rootRDFDepth == stack.count - 1 {
            globalDescriptionDepth = stack.count
            for (qualified, raw) in attributeDict {
                guard let key = cameraRawAttribute(qualified) else { continue }
                processDirect(key: key, raw: raw, parser: parser)
            }
            return
        }
        if let lookDepth, stack.count > lookDepth {
            if namespaceURI == Self.rdf, elementName == "Description", stack.count == lookDepth + 1 {
                for (qualified, raw) in attributeDict {
                    guard let key = cameraRawAttribute(qualified), key == "Name" || key == "Amount" else { continue }
                    processDirect(key: "Look" + key, raw: raw, parser: parser)
                }
            } else if namespaceURI == Self.crs, elementName == "Amount", stack.count == lookDepth + 2 {
                scalarCapture = ("LookAmount", stack.count, "")
            }
            return
        }
        if parent?.uri == Self.rdf, parent?.local == "Description", namespaceURI == Self.crs,
           globalDescriptionDepth == stack.count - 1 {
            if elementName == "Look" {
                lookDepth = stack.count
                // 이름을 찾으면 makePreset에서 지운다. 이름 없는 Look은 제외 경고로 남는다.
                unsupportedKeys.insert("Look")
            } else if LightroomPresetImporter.curveChannel(for: elementName) != nil {
                encounteredCurveKeys.insert(elementName)
                curveCapture = (elementName, stack.count)
            } else if elementName == "Name" {
                nameDepth = stack.count
            } else if LightroomPresetPayload.scalarRanges[elementName] != nil || elementName == "PresetType"
                        || elementName == "CameraProfile" || elementName == "ConvertToGrayscale"
                        || elementName == "WhiteBalance" {
                scalarCapture = (elementName, stack.count, "")
            } else if !LightroomPresetImporter.isMetadataKey(elementName) {
                unsupportedKeys.insert(elementName)
            }
        }
        if namespaceURI == Self.rdf, elementName == "li", nameDepth != nil || curveCapture != nil {
            itemCapture = (stack.count, "", attributeDict.first(where: { $0.key == "xml:lang" })?.value)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if itemCapture != nil { itemCapture!.text += string }
        else if scalarCapture != nil { scalarCapture!.text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !stack.isEmpty else { return }
        if let item = itemCapture, item.depth == stack.count {
            let value = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                if nameDepth != nil { names.append((item.language, value)) }
                else if curveCapture != nil {
                    let pieces = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if pieces.count == 2, let x = Double(pieces[0]), let y = Double(pieces[1]) {
                        pendingCurvePairs.append((x, y))
                    } else { curveMalformed = true }
                }
            }
            itemCapture = nil
        }
        if let scalar = scalarCapture, scalar.depth == stack.count {
            processDirect(key: scalar.key, raw: scalar.text.trimmingCharacters(in: .whitespacesAndNewlines), parser: parser)
            scalarCapture = nil
        }
        if let capture = curveCapture, capture.depth == stack.count {
            if !curveMalformed, let points = LightroomPresetImporter.normalizedCurve(pendingCurvePairs) {
                if let current = curveSources[capture.key], current != points {
                    fail(.conflictingValue(elementName), parser: parser)
                } else { curveSources[capture.key] = points }
            } else { unsupportedKeys.insert(elementName) }
            pendingCurvePairs = []
            curveMalformed = false
            curveCapture = nil
        }
        if nameDepth == stack.count { nameDepth = nil }
        if lookDepth == stack.count { lookDepth = nil }
        if globalDescriptionDepth == stack.count { globalDescriptionDepth = nil }
        if rootRDFDepth == stack.count { rootRDFDepth = nil }
        stack.removeLast()
    }

    private var pendingCurvePairs: [(Double, Double)] = []
    private var curveMalformed = false

    private func cameraRawAttribute(_ qualified: String) -> String? {
        guard let colon = qualified.firstIndex(of: ":") else { return nil }
        let prefix = String(qualified[..<colon])
        guard prefixURIs[prefix]?.last == Self.crs else { return nil }
        sawCameraRawNamespace = true
        return String(qualified[qualified.index(after: colon)...])
    }

    private func processDirect(key: String, raw: String, parser: XMLParser) {
        if key == "Name" {
            if let current = names.first?.1, current != raw { fail(.conflictingValue(key), parser: parser) }
            else if !raw.isEmpty { names.append((nil, raw)) }
        } else if key == "PresetType" {
            if let current = presetType, current != raw { fail(.conflictingValue(key), parser: parser) }
            else { presetType = raw }
        } else if LightroomPresetPayload.scalarRanges[key] != nil {
            if let current = scalars[key], !equalNumeric(current, raw) { fail(.conflictingValue(key), parser: parser) }
            else { scalars[key] = raw }
        } else if key == "CameraProfile" || key == "ConvertToGrayscale" || key == "WhiteBalance" || key == "LookName"
                    || key == "LookAmount" {
            if let current = scalars[key], current.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(raw.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
                fail(.conflictingValue(key), parser: parser)
            } else {
                scalars[key] = raw
            }
        } else if LightroomPresetImporter.isUnsupportedSetting(key) || !LightroomPresetImporter.isMetadataKey(key) {
            unsupportedKeys.insert(key)
        }
    }

    private func equalNumeric(_ lhs: String, _ rhs: String) -> Bool {
        if let a = Double(lhs.trimmingCharacters(in: .whitespacesAndNewlines)),
           let b = Double(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) { return a == b }
        return lhs == rhs
    }

    private func fail(_ error: LightroomPresetImportError, parser: XMLParser) {
        failure = error
        parser.abortParsing()
    }
}

private enum LuaValue: Equatable {
    case string(String), number(Double), boolean(Bool), table([String: LuaValue]), array([LuaValue])
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    var booleanValue: Bool? { if case .boolean(let value) = self { value } else { nil } }
    var tableValue: [String: LuaValue]? { if case .table(let value) = self { value } else { nil } }
}

private struct LuaLiteralParser {
    private enum Token: Equatable { case identifier(String), string(String), number(Double), boolean(Bool), symbol(Character), eof }
    private var tokens: [Token] = []
    private var index = 0
    private let maxDepth = 32

    init(source: String) throws {
        tokens = try Self.lex(source)
    }

    mutating func parse() throws -> LuaValue {
        if case .identifier = peek(), case .symbol("=") = token(at: index + 1) { index += 2 }
        let result = try value(depth: 0)
        guard peek() == .eof else { throw LightroomPresetImportError.invalidTemplate("table 뒤에 코드가 있습니다") }
        return result
    }

    private mutating func value(depth: Int) throws -> LuaValue {
        guard depth <= maxDepth else { throw LightroomPresetImportError.invalidTemplate("중첩이 너무 깊습니다") }
        switch take() {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .boolean(let value): return .boolean(value)
        case .symbol("{"): return try table(depth: depth + 1)
        default: throw LightroomPresetImportError.invalidTemplate("데이터 리터럴만 허용합니다")
        }
    }

    private mutating func table(depth: Int) throws -> LuaValue {
        var keyed: [String: LuaValue] = [:]
        var array: [LuaValue] = []
        while peek() != .symbol("}") {
            if peek() == .eof { throw LightroomPresetImportError.invalidTemplate("닫히지 않은 table입니다") }
            if case .identifier(let key) = peek(), token(at: index + 1) == .symbol("=") {
                index += 2
                guard keyed[key] == nil else { throw LightroomPresetImportError.conflictingValue(key) }
                keyed[key] = try value(depth: depth)
            } else if peek() == .symbol("[") {
                _ = take()
                let keyToken = take()
                guard take() == .symbol("]"), take() == .symbol("=") else {
                    throw LightroomPresetImportError.invalidTemplate("잘못된 table key입니다")
                }
                let key: String
                switch keyToken {
                case .string(let value): key = value
                case .number(let value): key = String(value)
                default: throw LightroomPresetImportError.invalidTemplate("table key는 문자열 또는 숫자여야 합니다")
                }
                guard keyed[key] == nil else { throw LightroomPresetImportError.conflictingValue(key) }
                keyed[key] = try value(depth: depth)
            } else {
                array.append(try value(depth: depth))
            }
            if peek() == .symbol(",") || peek() == .symbol(";") { _ = take() }
            else if peek() != .symbol("}") { throw LightroomPresetImportError.invalidTemplate("항목 구분자가 필요합니다") }
        }
        _ = take()
        guard keyed.isEmpty || array.isEmpty else { throw LightroomPresetImportError.invalidTemplate("혼합 table은 지원하지 않습니다") }
        return keyed.isEmpty ? .array(array) : .table(keyed)
    }

    private func peek() -> Token { token(at: index) }
    private func token(at position: Int) -> Token { position < tokens.count ? tokens[position] : .eof }
    private mutating func take() -> Token { defer { index += 1 }; return peek() }

    private static func lex(_ source: String) throws -> [Token] {
        var result: [Token] = []
        var index = source.startIndex
        func advance(_ i: inout String.Index) { i = source.index(after: i) }
        while index < source.endIndex {
            let char = source[index]
            if char.isWhitespace { advance(&index); continue }
            if char == "-", source.index(after: index) < source.endIndex,
               source[source.index(after: index)] == "-" {
                advance(&index); advance(&index)
                if index < source.endIndex, source[index] == "[" {
                    let next = source.index(after: index)
                    if next < source.endIndex, source[next] == "[" {
                        index = source.index(after: next)
                        guard let end = source[index...].range(of: "]]" ) else {
                            throw LightroomPresetImportError.invalidTemplate("닫히지 않은 주석입니다")
                        }
                        index = end.upperBound
                        continue
                    }
                }
                while index < source.endIndex, source[index] != "\n" { advance(&index) }
                continue
            }
            if "{}[]=,;".contains(char) { result.append(.symbol(char)); advance(&index); continue }
            if char == "\"" || char == "'" {
                let quote = char
                advance(&index)
                var value = ""
                var closed = false
                while index < source.endIndex {
                    let current = source[index]
                    advance(&index)
                    if current == quote { closed = true; break }
                    if current == "\\" {
                        guard index < source.endIndex else { break }
                        let escaped = source[index]; advance(&index)
                        switch escaped { case "n": value.append("\n"); case "r": value.append("\r"); case "t": value.append("\t"); default: value.append(escaped) }
                    } else { value.append(current) }
                }
                guard closed else { throw LightroomPresetImportError.invalidTemplate("닫히지 않은 문자열입니다") }
                result.append(.string(value)); continue
            }
            if char.isNumber || char == "-" || char == "+" || char == "." {
                let start = index
                advance(&index)
                while index < source.endIndex, source[index].isNumber || ".eE+-".contains(source[index]) { advance(&index) }
                let raw = String(source[start..<index])
                guard let value = Double(raw), value.isFinite else { throw LightroomPresetImportError.invalidTemplate("잘못된 숫자입니다") }
                result.append(.number(value)); continue
            }
            if char.isLetter || char == "_" {
                let start = index
                advance(&index)
                while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" { advance(&index) }
                let word = String(source[start..<index])
                if word == "true" { result.append(.boolean(true)) }
                else if word == "false" { result.append(.boolean(false)) }
                else { result.append(.identifier(word)) }
                continue
            }
            throw LightroomPresetImportError.invalidTemplate("허용하지 않는 문자입니다: \(char)")
        }
        guard result.count <= 20_000 else { throw LightroomPresetImportError.invalidTemplate("토큰이 너무 많습니다") }
        result.append(.eof)
        return result
    }
}
