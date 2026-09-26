import SwiftUI
import LighthouseCore

/// 오른쪽 패널의 스냅숏과 이번 실행의 보정 기록. 누르면 그 상태로 돌아가며 ⌘Z로 되돌릴 수 있다.
struct EditHistoryPanel: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset
    @AppStorage("historyPanelExpanded") private var expanded = false
    @State private var snapshotName = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("스냅숏 이름", text: $snapshotName).textFieldStyle(.roundedBorder)
                        .onSubmit(saveSnapshot)
                    Button("지금 상태 저장", action: saveSnapshot)
                }
                if photo.snapshots.isEmpty {
                    Text("보정 도중의 상태를 이름 붙여 저장해 두면 언제든 그 상태로 돌아갈 수 있습니다.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(photo.snapshots) { snapshot in
                    HStack {
                        Button { model.restoreEdits(snapshot.edits) } label: {
                            HStack {
                                Image(systemName: snapshot.edits == photo.edits ? "checkmark.circle.fill" : "camera.metering.center.weighted")
                                Text(snapshot.name).lineLimit(1)
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("\(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))에 저장")
                        .accessibilityLabel("스냅숏 \(snapshot.name)으로 돌아가기")
                        Spacer()
                        Button(role: .destructive) { model.deleteSnapshot(snapshot.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("스냅숏 \(snapshot.name) 삭제")
                    }
                    .font(.caption)
                }
                Divider()
                Text("이번 실행의 보정 기록").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                let timeline = model.editTimeline
                if timeline.isEmpty {
                    Text("이번 실행에서 아직 보정하지 않았습니다.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(timeline.reversed()) { entry in
                    Button { model.restoreEdits(entry.edits) } label: {
                        HStack {
                            Image(systemName: entry.edits == photo.edits ? "checkmark" : "arrow.uturn.backward")
                                .frame(width: 14)
                            Text(entry.title).lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(entry.edits == photo.edits)
                    .accessibilityLabel("\(entry.title) 상태로 돌아가기")
                }
            }
            .padding(.top, 6)
        } label: {
            Text("스냅숏 · 보정 기록").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
    }

    private func saveSnapshot() {
        model.saveSnapshot(name: snapshotName)
        snapshotName = ""
    }
}
