import Foundation

public enum CubeLUTError: LocalizedError {
    case invalidEncoding
    case tooLarge
    case invalidLine(Int, String)
    case unsupported(Int, String)
    case invalidCount(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: "LUT 파일은 UTF-8 텍스트여야 합니다."
        case .tooLarge: "LUT 파일은 64 MiB를 초과할 수 없습니다."
        case .invalidLine(let line, let reason): "LUT \(line)행이 올바르지 않습니다: \(reason)"
        case .unsupported(let line, let directive): "LUT \(line)행의 형식은 지원하지 않습니다: \(directive)"
        case .invalidCount(let expected, let actual): "LUT 색상 행은 \(expected)개가 필요하지만 \(actual)개입니다."
        }
    }
}

public struct CubeLUT: Sendable {
    public let title: String?
    public let dimension: Int
    public let cubeData: Data
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>

    public static func parse(_ data: Data) throws -> CubeLUT {
        guard data.count <= 64 * 1024 * 1024 else { throw CubeLUTError.tooLarge }
        guard var content = String(data: data, encoding: .utf8) else { throw CubeLUTError.invalidEncoding }
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }
        var title: String?
        var dimension: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var hasMin = false
        var hasMax = false
        var hasRange = false
        var values: [Float] = []
        var hasData = false

        for (offset, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = try stripComment(rawLine, lineNumber: lineNumber).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = tokens.first else { continue }
            if first.first?.isNumber == true || first.first == "-" || first.first == "+" || first.first == "." {
                guard let size = dimension else { throw CubeLUTError.invalidLine(lineNumber, "크기 선언이 없습니다") }
                guard tokens.count == 3, let rgb = parseTriplet(tokens) else {
                    throw CubeLUTError.invalidLine(lineNumber, "유한한 RGB 값 3개가 필요합니다")
                }
                hasData = true
                values.append(contentsOf: [rgb.x, rgb.y, rgb.z, 1])
                if values.count / 4 > size * size * size {
                    throw CubeLUTError.invalidCount(expected: size * size * size, actual: values.count / 4)
                }
                continue
            }
            if hasData { throw CubeLUTError.invalidLine(lineNumber, "메타데이터는 색상 행보다 앞에 있어야 합니다") }
            switch first {
            case "TITLE":
                guard title == nil else { throw CubeLUTError.invalidLine(lineNumber, "TITLE 중복") }
                let value = line.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { throw CubeLUTError.invalidLine(lineNumber, "TITLE 값이 없습니다") }
                if value.hasPrefix("\"") {
                    guard value.count >= 2, value.hasSuffix("\"") else {
                        throw CubeLUTError.invalidLine(lineNumber, "TITLE 따옴표가 닫히지 않았습니다")
                    }
                    title = String(value.dropFirst().dropLast())
                } else {
                    guard !value.contains("\"") else { throw CubeLUTError.invalidLine(lineNumber, "TITLE 따옴표 오류") }
                    title = value
                }
            case "LUT_3D_SIZE":
                guard dimension == nil, tokens.count == 2, let size = Int(tokens[1]), (2...65).contains(size) else {
                    throw CubeLUTError.invalidLine(lineNumber, "LUT_3D_SIZE는 중복 없이 2…65여야 합니다")
                }
                dimension = size
                values.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard !hasRange else { throw CubeLUTError.invalidLine(lineNumber, "DOMAIN과 INPUT_RANGE를 함께 사용할 수 없습니다") }
                guard tokens.count == 4, let triplet = parseTriplet(Array(tokens.dropFirst())) else {
                    throw CubeLUTError.invalidLine(lineNumber, "유한한 범위 값 3개가 필요합니다")
                }
                if first == "DOMAIN_MIN" {
                    guard !hasMin else { throw CubeLUTError.invalidLine(lineNumber, "DOMAIN_MIN 중복") }
                    domainMin = triplet
                    hasMin = true
                } else {
                    guard !hasMax else { throw CubeLUTError.invalidLine(lineNumber, "DOMAIN_MAX 중복") }
                    domainMax = triplet
                    hasMax = true
                }
            case "LUT_3D_INPUT_RANGE":
                guard !hasRange, !hasMin, !hasMax, tokens.count == 3,
                      let lower = Float(tokens[1]), let upper = Float(tokens[2]),
                      lower.isFinite, upper.isFinite, upper > lower else {
                    throw CubeLUTError.invalidLine(lineNumber, "INPUT_RANGE가 중복·혼합되었거나 범위가 올바르지 않습니다")
                }
                hasRange = true
                domainMin = SIMD3<Float>(repeating: lower)
                domainMax = SIMD3<Float>(repeating: upper)
            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
                throw CubeLUTError.unsupported(lineNumber, first)
            default:
                throw CubeLUTError.unsupported(lineNumber, first)
            }
        }
        guard let size = dimension else { throw CubeLUTError.invalidLine(0, "LUT_3D_SIZE가 없습니다") }
        guard domainMax.x > domainMin.x, domainMax.y > domainMin.y, domainMax.z > domainMin.z else {
            throw CubeLUTError.invalidLine(0, "DOMAIN_MAX는 DOMAIN_MIN보다 커야 합니다")
        }
        let span = domainMax - domainMin
        let scale = SIMD3<Float>(repeating: 1) / span
        let bias = -domainMin * scale
        guard [span.x, span.y, span.z, scale.x, scale.y, scale.z,
               bias.x, bias.y, bias.z].allSatisfy(\.isFinite) else {
            throw CubeLUTError.invalidLine(0, "DOMAIN 범위가 지원 가능한 수치를 벗어났습니다")
        }
        let expected = size * size * size
        guard values.count / 4 == expected else {
            throw CubeLUTError.invalidCount(expected: expected, actual: values.count / 4)
        }
        let cubeData = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        return CubeLUT(title: title, dimension: size, cubeData: cubeData,
                       domainMin: domainMin, domainMax: domainMax)
    }

    private static func parseTriplet(_ tokens: [String]) -> SIMD3<Float>? {
        guard tokens.count == 3, let x = Float(tokens[0]), let y = Float(tokens[1]),
              let z = Float(tokens[2]), x.isFinite, y.isFinite, z.isFinite else { return nil }
        return SIMD3<Float>(x, y, z)
    }

    private static func stripComment(_ line: String, lineNumber: Int) throws -> String {
        var quoted = false
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if character == "#", !quoted { return String(line[..<index]) }
        }
        if quoted { throw CubeLUTError.invalidLine(lineNumber, "닫히지 않은 따옴표") }
        return line
    }
}
