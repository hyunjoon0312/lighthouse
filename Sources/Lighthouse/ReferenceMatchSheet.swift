import AppKit
import SwiftUI
import LighthouseCore

struct ReferenceMatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ReferenceMatchModel
    private let onStored: (LUTAdjustment, Bool) -> Void

    init(source: PhotoAsset, onStored: @escaping (LUTAdjustment, Bool) -> Void) {
        _model = StateObject(wrappedValue: ReferenceMatchModel(source: source))
        self.onStored = onStored
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "camera.filters").font(.title2).foregroundStyle(.orange)
                    Text("참조 사진 색감 맞추기").font(.title2.weight(.semibold))
                    Spacer()
                    Button("닫기") { dismiss() }
                        .disabled(model.isWriting)
                }

                Text("사진의 밝기와 색 분포를 근사합니다. 조명과 피사체가 다르면 결과도 달라집니다.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("현재 LUT는 대체됩니다. 다른 보정은 유지됩니다.")
                    .font(.callout).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("참조 사진 선택…") { model.chooseReference() }
                        .disabled(model.isWriting)
                    Text(model.referenceName ?? "참조 사진을 선택하세요")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    previewCard("현재 사진 (LUT 제외)", subtitle: model.source.filename,
                                image: model.sourcePreview)
                    previewCard("참조 사진", subtitle: model.referenceName ?? "파일 미선택",
                                image: model.referencePreview)
                    previewCard("색감 맞춘 결과", subtitle: "강도 \(Int(model.strength * 100))%",
                                image: model.matchedPreview)
                }

                HStack(spacing: 12) {
                    Text("강도").frame(width: 65, alignment: .leading)
                    Slider(value: $model.strength, in: 0...1, step: 0.01)
                        .onChange(of: model.strength) { _, _ in model.updateStrength() }
                        .disabled(model.sourcePreview == nil || model.isAnalyzing || model.isWriting)
                        .accessibilityLabel("색감 맞추기 강도")
                    Text("\(Int(model.strength * 100))%")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text("LUT 이름").frame(width: 65, alignment: .leading)
                    TextField("LUT 이름", text: $model.lutName)
                        .disabled(model.isWriting)
                }

                Text("S9: Standard 기반 33³ LUT · 실기 색감 확인 필요")
                    .font(.caption).foregroundStyle(.secondary)

                if model.isAnalyzing || model.isPreviewUpdating || model.isWriting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.isAnalyzing ? "사진 분석 중…" :
                             model.isPreviewUpdating ? "미리보기 갱신 중…" : "LUT 저장 중…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let success = model.successMessage {
                    Text(success).font(.caption).foregroundStyle(.green).textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button("S9용 .cube 내보내기…") { model.chooseExportLocation() }
                        .disabled(!model.canWrite)
                    Spacer()
                    Button("LUT만 보관") { store(apply: false) }
                        .disabled(!model.canWrite)
                    Button("보관하고 현재 사진에 적용") { store(apply: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canWrite)
                }
            }
            .padding(24)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 940, height: 700)
        .interactiveDismissDisabled(model.isWriting)
        .onDisappear { model.invalidate() }
    }

    private func previewCard(_ title: String, subtitle: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.25))
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .padding(5)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 260)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func store(apply: Bool) {
        model.store(apply: apply) { adjustment, apply in
            onStored(adjustment, apply)
            dismiss()
        }
    }
}
