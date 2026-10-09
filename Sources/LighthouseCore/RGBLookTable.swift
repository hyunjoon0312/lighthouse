import Foundation

/// 크리에이티브 프로필의 RGBTable(3D LUT). DNG SDK `dng_rgb_table`의 저장 형식을 읽는다.
/// 계약: docs/camera-profiles-calibration-contract.md "크리에이티브 프로필"
public struct RGBLookTable: Equatable, Sendable {
    public let divisions: Int
    /// r(가장 바깥)·g·b(가장 안쪽) 순서의 (r, g, b) 값, 0…1.
    let samples: [Float]
    /// 0 sRGB, 1 Adobe RGB, 2 ProPhoto, 3 Display P3, 4 Rec.2020
    public let primaries: Int
    /// 0 선형, 1 sRGB, 2 감마 1.8, 3 감마 2.2
    public let gamma: Int
    public let minimumAmount: Double
    public let maximumAmount: Double
    let toTable: Matrix3
    let fromTable: Matrix3

    /// 풀어 놓은 표(리틀 엔디언). 종류 1이 아니면 `unsupportedTable`이다.
    static func decode(_ raw: Data) throws -> RGBLookTable {
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= raw.count else { throw AdobeLookProfileError.invalidTable }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[raw.startIndex + offset + $1]) << (8 * UInt32($1)) }
        }
        guard try u32(0) == 1 else { throw AdobeLookProfileError.unsupportedTable }
        guard try u32(8) == 3 else { throw AdobeLookProfileError.unsupportedTable }
        let divisions = Int(try u32(12))
        guard (2...64).contains(divisions) else { throw AdobeLookProfileError.invalidTable }
        let count = divisions * divisions * divisions * 3
        let tail = 16 + count * 2
        guard raw.count >= tail + 12 + 16 else { throw AdobeLookProfileError.invalidTable }
        let nominal = (0..<divisions).map { (UInt32($0) * 0xFFFF + UInt32((divisions - 1) / 2)) / UInt32(divisions - 1) }
        var samples = [Float](repeating: 0, count: count)
        var index = 0
        for r in 0..<divisions {
            for g in 0..<divisions {
                for b in 0..<divisions {
                    for (channel, base) in [nominal[r], nominal[g], nominal[b]].enumerated() {
                        let at = raw.startIndex + 16 + (index + channel) * 2
                        let delta = UInt16(raw[at]) | UInt16(raw[at + 1]) << 8
                        samples[index + channel] = Float(UInt16(truncatingIfNeeded: base &+ UInt32(delta))) / 65535
                    }
                    index += 3
                }
            }
        }
        let primaries = Int(try u32(tail)), gamma = Int(try u32(tail + 4))
        guard (0...4).contains(primaries), (0...3).contains(gamma) else { throw AdobeLookProfileError.unsupportedTable }
        func f64(_ offset: Int) -> Double {
            Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[raw.startIndex + offset + $1]) << (8 * UInt64($1)) })
        }
        let minimum = f64(tail + 12), maximum = f64(tail + 20)
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum, (0...4).contains(maximum) else {
            throw AdobeLookProfileError.invalidTable
        }
        let (toTable, fromTable) = matrices(primaries)
        return RGBLookTable(divisions: divisions, samples: samples, primaries: primaries, gamma: gamma,
                            minimumAmount: minimum, maximumAmount: maximum, toTable: toTable, fromTable: fromTable)
    }

    /// 선형 sRGB 값에 `amount`만큼 표를 적용한다. 0…1 밖의 값은 자른 점의 변화량을 더해 넘는 부분을 보존한다.
    func apply(_ linearSRGB: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        guard amount != 0 else { return linearSRGB }
        let value = toTable.apply(linearSRGB)
        let clamped = SIMD3(min(1, max(0, value.x)), min(1, max(0, value.y)), min(1, max(0, value.z)))
        let encoded = SIMD3(encode(clamped.x), encode(clamped.y), encode(clamped.z))
        let looked = lookup(encoded)
        let blended = encoded + amount * (looked - encoded)
        let changed = SIMD3(decode(blended.x), decode(blended.y), decode(blended.z))
        return fromTable.apply(changed + (value - clamped))
    }

    private func lookup(_ e: SIMD3<Double>) -> SIMD3<Double> {
        let scale = Double(divisions - 1)
        let position = e * scale
        let low = SIMD3(min(divisions - 2, Int(position.x)), min(divisions - 2, Int(position.y)),
                        min(divisions - 2, Int(position.z)))
        let fraction = position - SIMD3(Double(low.x), Double(low.y), Double(low.z))
        func sample(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
            let index = ((r * divisions + g) * divisions + b) * 3
            return SIMD3(Double(samples[index]), Double(samples[index + 1]), Double(samples[index + 2]))
        }
        var result = SIMD3<Double>(repeating: 0)
        for dr in 0...1 {
            for dg in 0...1 {
                for db in 0...1 {
                    let weight = (dr == 1 ? fraction.x : 1 - fraction.x) * (dg == 1 ? fraction.y : 1 - fraction.y)
                        * (db == 1 ? fraction.z : 1 - fraction.z)
                    if weight > 0 { result += weight * sample(low.x + dr, low.y + dg, low.z + db) }
                }
            }
        }
        return result
    }

    private func encode(_ x: Double) -> Double {
        switch gamma {
        case 1: DNGProfileTransform.srgbEncode(x)
        case 2: pow(x, 1 / 1.8)
        case 3: pow(x, 1 / 2.2)
        default: x
        }
    }

    /// 양이 1보다 크면 0 아래나 1 위가 나올 수 있어 부호를 지키며 되돌린다.
    private func decode(_ x: Double) -> Double {
        let magnitude = abs(x)
        let linear: Double = switch gamma {
        case 1: DNGProfileTransform.srgbDecode(magnitude)
        case 2: pow(magnitude, 1.8)
        case 3: pow(magnitude, 2.2)
        default: magnitude
        }
        return x < 0 ? -linear : linear
    }

    /// 선형 sRGB(D65)와 표 원색 사이의 행렬. ProPhoto는 D50이라 Bradford 순응 행렬을 거친다.
    static func matrices(_ primaries: Int) -> (Matrix3, Matrix3) {
        let sRGBToXYZ65 = Matrix3(values: [0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750,
                                           0.0193339, 0.1191920, 0.9503041])
        let other: Matrix3
        switch primaries {
        case 1: other = Matrix3(values: [0.5767309, 0.1855540, 0.1881852, 0.2973769, 0.6273491, 0.0752741,
                                         0.0270343, 0.0706872, 0.9911085])
        case 2:
            let toProPhoto = DNGProfileTransform.proPhotoToXYZ.inverse! * DNGProfileTransform.sRGBToXYZ
            return (toProPhoto, toProPhoto.inverse!)
        case 3: other = Matrix3(values: [0.4865709, 0.2656677, 0.1982173, 0.2289746, 0.6917385, 0.0792869,
                                         0, 0.0451134, 1.0439444])
        case 4: other = Matrix3(values: [0.6369580, 0.1446169, 0.1688810, 0.2627002, 0.6779981, 0.0593017,
                                         0, 0.0280727, 1.0609851])
        default: return (.identity, .identity)
        }
        let to = other.inverse! * sRGBToXYZ65
        return (to, to.inverse!)
    }
}
