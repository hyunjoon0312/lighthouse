import SwiftUI
import LighthouseCore

struct LightroomPresetImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: LightroomPresetSheetRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch request.content {
            case .importResult(let summary): importResult(summary)
            case .compatibility(let preset): compatibility(preset)
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Palette.panel)
    }

    @ViewBuilder
    private func importResult(_ summary: LightroomPresetImportSummary) -> some View {
        Text("Lightroom 프리셋 가져오기 결과").font(.title2.weight(.semibold))
        Text("추가 \(summary.imported.count)개 · 실패 \(summary.failures.count)개")
            .font(.headline)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(summary.imported) { preset in
                    presetCompatibility(preset, showsTitle: true)
                }
                ForEach(summary.failures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(failure.filename, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        Text(failure.message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.28, green: 0.08, blue: 0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if summary.imported.isEmpty && summary.failures.isEmpty {
                    Text("추가된 프리셋이 없습니다.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 440)
    }

    @ViewBuilder
    private func compatibility(_ preset: EditPreset) -> some View {
        Text("프리셋 호환 정보").font(.title2.weight(.semibold))
        ScrollView {
            presetCompatibility(preset, showsTitle: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 440)
    }

    @ViewBuilder
    private func presetCompatibility(_ preset: EditPreset, showsTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsTitle { Text(preset.name).font(.headline).textSelection(.enabled) }
            if let payload = preset.lightroom {
                Text(payload.format == "xmp" ? "Lightroom XMP" : "Lightroom lrtemplate")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                Text("지원 설정 \(payload.scalars.count + payload.curves.count + (payload.colorProfile == nil ? 0 : 1))개")
                    .font(.caption).foregroundStyle(.secondary)
                if payload.warnings.isEmpty {
                    Text("제외된 설정이 없습니다.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(payload.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Lighthouse에서 저장한 프리셋입니다. 선택한 보정 항목을 앱의 원래 값으로 적용합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
