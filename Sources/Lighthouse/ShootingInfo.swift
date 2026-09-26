import Foundation
import LighthouseCore

extension PhotoMetadata {
    /// 셔터 속도("1/3200초", "2.0초").
    static func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 1 { return "1/\(Int((1 / seconds).rounded()))초" }
        return String(format: "%.1f초", seconds)
    }

    /// 초점거리·조리개·셔터·ISO를 한 줄로("45mm · f/2.8 · 1/3200초 · ISO 200"). 없는 값은 뺀다.
    var shootingSummary: String {
        var parts: [String] = []
        if let focalLength { parts.append(focalLength.rounded() == focalLength ? "\(Int(focalLength))mm" : String(format: "%.1fmm", focalLength)) }
        if let aperture { parts.append(String(format: "f/%.1f", aperture)) }
        if let shutter { parts.append(Self.shutterText(shutter)) }
        if let iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: " · ")
    }
}
