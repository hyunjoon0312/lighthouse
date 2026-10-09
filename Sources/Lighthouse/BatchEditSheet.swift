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
    @State private var reRecognizeAutomaticMasks = true

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
                    Toggle("전체 보정 (빛·색·카메라 프로필·캘리브레이션·화이트밸런스·텍스처·명료도·디헤이즈·생동감·비네팅·곡선·HSL·컬러 그레이딩·선명도·노이즈 감소·입자·RAW 현상)", isOn: $copyGlobal)
                    Toggle("LUT", isOn: $copyLUT)
                    if snapshot.edits.lut == nil {
                        Text("LUT를 포함하면 대상 사진의 LUT가 해제됩니다.")
                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
                    }
                    Toggle("회전·크롭", isOn: $copyGeometry)
                    Toggle("부분 보정 영역", isOn: $copyLocal)
                    if copyLocal && snapshot.edits.localAdjustments.contains(where: { $0.automaticMaskKind != nil }) {
                        Toggle("사진마다 피사체·배경 다시 인식", isOn: $reRecognizeAutomaticMasks)
                        Text("대상마다 한 번 인식합니다. 실패한 사진은 전체 일괄 변경에서 제외됩니다. 브러시와 복구 위치는 자동으로 이동하지 않습니다.")
                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
                    }
                    Toggle("복구 작업", isOn: $copyRetouch)
                    Text("직접 그린 브러시 영역과 복구 위치는 대상 사진의 같은 정규화 좌표로 복사됩니다.")
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
                // 창이 내용 크기에 맞춰지면 스크롤 영역이 0으로 줄어 목록이 보이지 않으므로 줄 수만큼 높이를 준다.
                .frame(height: min(150, CGFloat(snapshot.targets.count) * 20))
                Text("원본 파일, 별점과 선택·제외 표시는 바뀌지 않습니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                if model.isRunningWorkflow {
                    ProgressView(value: model.workflowProgress)
                }
                if let report = model.batchWorkflowReport {
                    Text("변경 \(report.changed)장 · 건너뜀 \(report.skipped)장 · 실패 \(report.failures.count)장")
                        .font(.caption).foregroundStyle(report.failures.isEmpty ? Color.secondary : Color.orange)
                    if report.cancelled {
                        Text("일괄 적용을 취소했습니다. 변경 사항은 적용하지 않았습니다.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !report.failures.isEmpty {
                        DisclosureGroup("실패한 사진 \(report.failures.count)장") {
                            ForEach(report.failures) { failure in
                                Text("\(failure.filename): \(failure.message)")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(model.isRunningWorkflow ? "처리 취소" : "취소") {
                        if model.isRunningWorkflow { model.cancelWorkflow() } else { dismiss() }
                    }
                    Button("선택한 \(snapshot.targets.count)장에 적용") {
                        model.applyBatchEditsWithAutomaticMasks(source: snapshot.edits,
                                                                to: snapshot.targets.map(\.id), components: components,
                                                                reRecognize: reRecognizeAutomaticMasks)
                        if !reRecognizeAutomaticMasks || !copyLocal ||
                            !snapshot.edits.localAdjustments.contains(where: { $0.automaticMaskKind != nil }) { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(components.isEmpty || model.isRunningWorkflow)
                }
            } else {
                ProgressView()
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(model.isRunningWorkflow)
        .onAppear {
            guard snapshot == nil, let source = model.selection else { return }
            model.batchWorkflowReport = nil
            model.workflowMessage = nil
            snapshot = BatchSnapshot(sourceName: source.filename, edits: source.edits,
                                     targets: model.selectedPhotos.map { BatchTarget(id: $0.id, filename: $0.filename) })
        }
    }
}
