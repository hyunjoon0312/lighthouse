import SwiftUI
import LighthouseCore

struct RetouchControls: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset

    var body: some View {
        Group {
            Text("작은 먼지와 잡티를 복구하거나 다른 위치의 질감을 복제합니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("복구 방식", selection: Binding(
                get: { model.retouchMode },
                set: { model.cancelRetouchDraft(); model.retouchMode = $0 }
            )) {
                Text("스팟 복구").tag(RetouchMode.heal)
                Text("복제").tag(RetouchMode.clone)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("복구 방식")
            VStack(spacing: 3) {
                HStack {
                    Text("브러시 크기").font(.caption)
                    Spacer()
                    Text("\(Int(model.retouchRadius * 200))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $model.retouchRadius, in: 0.002...0.15)
                    .accessibilityLabel("복구 브러시 크기")
            }
            if model.retouchMode == .clone {
                Button(model.isPickingCloneSource ? "사진에서 소스를 클릭하세요" : "소스 선택") {
                    model.cancelRetouchDraft()
                    model.isPickingCloneSource = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("복제 소스 선택")
                if model.cloneSource != nil {
                    Text("소스가 선택되었습니다. 사진 위를 드래그해 복제하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("먼저 복제할 질감의 중심을 사진에서 선택하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("사진 위를 클릭하거나 짧게 드래그하세요. 주변 패치를 자동으로 찾습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.isFindingHealSource {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("주변 패치를 찾는 중…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("취소") { model.cancelRetouchDraft() }.accessibilityLabel("스팟 복구 패치 찾기 취소")
                }
            }
            if let error = model.retouchError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("작업 \(photo.edits.retouchStrokes.count)개").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Button("전체 지우기", role: .destructive) { model.clearRetouchStrokes() }
                    .disabled(photo.edits.retouchStrokes.isEmpty)
                    .accessibilityLabel("복구 작업 전체 지우기")
            }
            ForEach(Array(photo.edits.retouchStrokes.enumerated()), id: \.element.id) { index, stroke in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { stroke.isEnabled },
                        set: { model.setRetouchStrokeEnabled(stroke.id, enabled: $0) }
                    ))
                    .labelsHidden().accessibilityLabel("복구 작업 \(index + 1) 활성화")
                    Image(systemName: stroke.mode == .heal ? "bandage" : "square.on.square")
                    Text("\(stroke.mode == .heal ? "스팟 복구" : "복제") \(index + 1)")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Button(role: .destructive) { model.deleteRetouchStroke(stroke.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain).accessibilityLabel("복구 작업 \(index + 1) 삭제")
                }
            }
            if photo.edits.retouchStrokes.isEmpty {
                Text("아직 복구 작업이 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
