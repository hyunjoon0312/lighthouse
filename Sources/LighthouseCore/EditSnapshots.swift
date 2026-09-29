import Foundation

/// 사진마다 이름 붙여 저장한 보정 상태. 카탈로그에 함께 저장되며 누르면 그 상태로 돌아간다(실행 취소할 수 있다).
public struct EditSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var edits: EditSettings

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), edits: EditSettings) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.edits = edits
    }
}

public extension EditSettings {
    /// `before`에서 바뀐 항목 이름("노출·대비", "부분 보정 외 2"). 보정 기록 목록에 쓴다.
    func changeSummary(from before: EditSettings) -> String {
        guard self != before else { return "변경 없음" }
        if self == .neutral { return "보정 초기화" }
        let fields: [(String, Bool)] = [
            ("노출", exposure != before.exposure),
            ("대비", contrast != before.contrast),
            ("하이라이트", highlights != before.highlights),
            ("섀도", shadows != before.shadows),
            ("명료도", clarity != before.clarity),
            ("색온도", temperatureShift != before.temperatureShift),
            ("틴트", tintShift != before.tintShift),
            ("생동감", vibrance != before.vibrance),
            ("채도", saturation != before.saturation),
            ("곡선", curves != before.curves),
            ("HSL", colorRanges != before.colorRanges),
            ("필름 입자", grain != before.grain),
            ("RAW 현상", rawDevelop != before.rawDevelop),
            ("노이즈 감소", noiseReduction != before.noiseReduction),
            ("플리커", flicker != before.flicker),
            ("HDR", hdrAmount != before.hdrAmount),
            ("선명도", sharpness != before.sharpness),
            ("비네팅", vignette != before.vignette),
            ("LUT", lut != before.lut),
            ("회전", rotationQuarterTurns != before.rotationQuarterTurns),
            ("크롭", cropRect != before.cropRect || cropAspect != before.cropAspect ||
                straightenDegrees != before.straightenDegrees),
            ("부분 보정", localAdjustments != before.localAdjustments),
            ("복구", retouchStrokes != before.retouchStrokes),
        ]
        let changed = fields.filter(\.1).map(\.0)
        guard let first = changed.first else { return "보정" }
        return changed.count <= 3 ? changed.joined(separator: "·") : "\(first)·\(changed[1]) 외 \(changed.count - 2)"
    }
}
