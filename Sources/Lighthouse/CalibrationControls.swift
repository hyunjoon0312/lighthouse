import SwiftUI
import LighthouseCore

/// Lightroom 캘리브레이션: 그림자 틴트와 빨강·초록·파랑 원색의 색조·채도(-100…100).
struct CalibrationControls: View {
    @EnvironmentObject private var model: LibraryModel
    let edits: EditSettings

    private static let rows: [(String, WritableKeyPath<CalibrationSettings, Double>)] = [
        ("그림자 틴트", \.shadowTint),
        ("빨강 색조", \.redHue), ("빨강 채도", \.redSaturation),
        ("초록 색조", \.greenHue), ("초록 채도", \.greenSaturation),
        ("파랑 색조", \.blueHue), ("파랑 채도", \.blueSaturation),
    ]

    var body: some View {
        Group {
            Divider()
            Text("캘리브레이션").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .help("원색의 색조·채도와 그림자 틴트를 바꿉니다. Lighthouse 수식이며 Adobe 결과와 다를 수 있습니다.")
            ForEach(Self.rows, id: \.0) { title, path in
                let value = edits.calibration[keyPath: path] * 100
                SliderRow(title: title, value: value, range: -100...100,
                          valueText: value.rounded() == 0 ? "0" : String(format: "%+.0f", value),
                          set: { update(path, $0, continuous: true) }, end: { model.endContinuousEdit() },
                          reset: { update(path, 0) })
            }
            Button("캘리브레이션 초기화") {
                var next = edits
                next.calibration = .neutral
                model.updateEdits(next)
            }
            .disabled(edits.calibration.isNeutral)
        }
    }

    private func update(_ path: WritableKeyPath<CalibrationSettings, Double>, _ value: Double, continuous: Bool = false) {
        var next = edits
        next.calibration[keyPath: path] = value.isFinite ? min(1, max(-1, value / 100)) : 0
        model.updateEdits(next, continuous: continuous)
    }
}
