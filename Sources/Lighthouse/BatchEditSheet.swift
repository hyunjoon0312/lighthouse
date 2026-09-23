import SwiftUI
import LighthouseCore

private struct BatchTarget: Identifiable {
    let id: UUID
    let filename: String
}

private struct BatchSnapshot {
    let sourceName: String
    let edits: EditSettings
    let targets: [BatchTarget]
}

struct BatchEditSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: BatchSnapshot?
    @State private var copyGlobal = true
    @State private var copyLUT = true
    @State private var copyGeometry = false
    @State private var copyLocal = false
    @State private var copyRetouch = false

    private var components: EditComponents {
        var result: EditComponents = []
        if copyGlobal { result.insert(.global) }
        if copyLUT { result.insert(.lut) }
        if copyGeometry { result.insert(.geometry) }
        if copyLocal { result.insert(.local) }
        if copyRetouch { result.insert(.retouch) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("보정 일괄 적용").font(.title2.weight(.semibold))
            if let snapshot {
                Text("기준 사진: \(snapshot.sourceName)").font(.subheadline)
                Text("선택한 \(snapshot.targets.count)장의 사진에 원하는 보정 항목을 복사합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("빛·색상·곡선·HSL·선명도·입자", isOn: $copyGlobal)
                    Toggle("LUT", isOn: $copyLUT)
                    if snapshot.edits.lut == nil {
                        Text("LUT를 포함하면 대상 사진의 LUT가 해제됩니다.")
                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
                    }
                    Toggle("회전·크롭", isOn: $copyGeometry)
                    Toggle("부분 보정 영역", isOn: $copyLocal)
                    Toggle("복구 작업", isOn: $copyRetouch)
                    Text("자동 마스크와 복구 위치는 대상 사진에서 다시 인식되지 않고 같은 정규화 위치에 복사됩니다.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
                }
                .toggleStyle(.checkbox)
                Divider()
                Text("대상 사진").font(.caption.weight(.semibold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(snapshot.targets) { target in
                            Text(target.filename).font(.caption).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                Text("원본 파일, 별점과 선택·제외 표시는 바뀌지 않습니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("취소") { dismiss() }
                    Button("선택한 \(snapshot.targets.count)장에 적용") {
                        model.applyBatchEdits(source: snapshot.edits,
                                              to: snapshot.targets.map(\.id), components: components)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(components.isEmpty)
                }
            } else {
                ProgressView()
            }
        }
        .padding(24).frame(width: 480)
        .onAppear {
            guard snapshot == nil, let source = model.selection else { return }
            snapshot = BatchSnapshot(sourceName: source.filename, edits: source.edits,
                                     targets: model.selectedPhotos.map { BatchTarget(id: $0.id, filename: $0.filename) })
        }
    }
}
