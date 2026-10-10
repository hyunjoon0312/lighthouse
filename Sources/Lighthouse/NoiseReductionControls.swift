import SwiftUI
import LighthouseCore

/// JPEG·HEIC와 현상된 RAW에 공통으로 적용되는 노이즈 감소.
struct NoiseReductionControls: View {
    @EnvironmentObject private var model: LibraryModel
    let edits: EditSettings

    private var settings: NoiseReductionSettings { edits.noiseReduction }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("노이즈 감소").font(.caption.weight(.semibold))
                Spacer()
                Button("초기화") { update(NoiseReductionSettings()) }
                    .font(.caption).buttonStyle(.borderless)
                    .disabled(settings == NoiseReductionSettings())
                    .accessibilityLabel("노이즈 감소 초기화")
            }
            Picker("노이즈 감소 방식", selection: Binding(
                get: { settings.mode },
                set: { mode in
                    var next = settings
                    next.mode = mode
                    update(next)
                }
            )) {
                ForEach(Array(NoiseReductionMode.allCases.enumerated()), id: \.offset) { _, mode in
                    Text(title(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption)
            .accessibilityLabel("노이즈 감소 방식")

            SliderRow(title: "노이즈 감소 강도", value: settings.amount * 100, range: 0...100,
                      valueText: String(format: "%.0f%%", settings.amount * 100),
                      set: { amount in
                          var next = settings
                          next.amount = amount / 100
                          update(next, continuous: true)
                      },
                      end: { model.endContinuousEdit() },
                      reset: {
                          var next = settings
                          next.amount = NoiseReductionSettings().amount
                          update(next)
                          model.endContinuousEdit()
                      })
                .disabled(settings.mode == .off)

            Text(helpText)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(helpText)
        }
    }

    private var helpText: String {
        switch settings.mode {
        case .off:
            "일반과 AI 방식은 JPEG·HEIC와 현상된 RAW에 적용됩니다."
        case .standard:
            "Mac의 일반 필터로 JPEG·HEIC와 현상된 RAW의 노이즈를 줄입니다."
        case .ai:
            "Mac에서 로컬로 처리합니다. 처음에는 시간이 걸릴 수 있으며 100% 확대에서 결과를 확인하세요."
        }
    }

    private func title(for mode: NoiseReductionMode) -> String {
        switch mode {
        case .off: "끔"
        case .standard: "일반"
        case .ai: "AI"
        }
    }

    private func update(_ settings: NoiseReductionSettings, continuous: Bool = false) {
        var next = edits
        next.noiseReduction = settings
        model.updateEdits(next, continuous: continuous)
    }
}
