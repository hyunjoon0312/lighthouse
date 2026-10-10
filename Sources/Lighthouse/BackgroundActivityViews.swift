import SwiftUI

/// 사진 아래 상태 줄의 작업 표시. 얼굴 찾기·XMP 쓰기처럼 뒤에서 도는 작업이 잠깐(0.8초) 넘게 이어질 때만 나타나
/// 금방 끝나는 작업으로 줄이 깜박이지 않는다. "작업 보기"는 작업마다 진행과 중지 단추가 있는 목록을 연다.
/// 가져오기·내보내기는 바로 위 진행 막대가 보이므로 이 줄에서는 빼고 목록에만 둔다.
struct BackgroundActivityRow: View {
    @EnvironmentObject private var model: LibraryModel
    /// Drive 업로드는 따로 바뀌는 모델이라 직접 지켜본다.
    @ObservedObject var drive: GoogleDriveUploadModel
    @State private var visible = false
    @State private var showsList = false

    var body: some View {
        let activities = model.backgroundActivities.filter { $0.kind != .importing && $0.kind != .exporting }
        VStack(spacing: 0) {
            if visible, !activities.isEmpty {
                HStack(spacing: 8) {
                    indicator(activities)
                    Text(activities.map(Self.describe).joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("작업 보기") { showsList.toggle() }
                        .controlSize(.small).tint(Palette.inactive)
                        .help("진행 중인 작업과 중지 단추를 봅니다")
                        .accessibilityLabel("진행 중인 작업 보기")
                        .popover(isPresented: $showsList, arrowEdge: .top) {
                            // 팝오버는 본 창의 강조색 범위 안이라 중지 단추가 주황이 되지 않게 중립색을 준다.
                            BackgroundActivityList(drive: drive).environmentObject(model).tint(Palette.inactive)
                        }
                }
                .padding(.horizontal, 16).padding(.vertical, 5)
            }
        }
        .task(id: activities.isEmpty) {
            guard !activities.isEmpty else {
                visible = false
                showsList = false
                return
            }
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            visible = true
        }
    }

    private static func describe(_ activity: BackgroundActivity) -> String {
        [activity.title, activity.detail].compactMap { $0 }.joined(separator: " ")
    }

    /// 작업이 하나이고 진행을 알면 차오르는 원을, 아니면 도는 표시를 보인다.
    @ViewBuilder private func indicator(_ activities: [BackgroundActivity]) -> some View {
        if activities.count == 1, let progress = activities.first?.progress {
            ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini).tint(Palette.accent)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// 진행 중인 작업 목록. 진행을 아는 작업은 막대로, 모르는 작업은 움직이는 막대로 보이며, 멈출 수 있는 작업에는 중지 단추가 있다.
struct BackgroundActivityList: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var drive: GoogleDriveUploadModel

    var body: some View {
        let activities = model.backgroundActivities
        VStack(alignment: .leading, spacing: 14) {
            Text("진행 중인 작업").font(.headline)
            if activities.isEmpty {
                Text("모든 작업이 끝났습니다.").font(.callout).foregroundStyle(Palette.muted)
            }
            ForEach(activities) { row($0) }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func row(_ activity: BackgroundActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(activity.title).font(.callout.weight(.semibold))
                if let detail = activity.detail {
                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                if activity.canCancel {
                    let title = activity.isCancelling ? "중지하는 중…" : "중지"
                    Button(title) { model.cancelBackgroundActivity(activity.kind) }
                        .controlSize(.small)
                        .disabled(activity.isCancelling)
                        .help("남은 작업을 멈춥니다")
                        .accessibilityLabel("\(activity.title) \(title)")
                }
            }
            if let progress = activity.progress {
                ProgressView(value: progress).tint(Palette.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Palette.accent)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
