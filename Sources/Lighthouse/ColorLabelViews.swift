import SwiftUI
import LighthouseCore

extension PhotoColorLabel {
    var color: Color {
        switch self {
        case .red: Color(red: 0.93, green: 0.30, blue: 0.28)
        case .yellow: Color(red: 0.97, green: 0.80, blue: 0.25)
        case .green: Color(red: 0.36, green: 0.78, blue: 0.40)
        case .blue: Color(red: 0.30, green: 0.56, blue: 0.95)
        case .purple: Color(red: 0.68, green: 0.45, blue: 0.90)
        }
    }

    /// 메뉴·도움말에 붙이는 키. 보라는 키가 없다.
    var keyHint: String? {
        switch self {
        case .red: "6"
        case .yellow: "7"
        case .green: "8"
        case .blue: "9"
        case .purple: nil
        }
    }
}

/// 오른쪽 패널의 색상 라벨 고르기. 붙어 있는 라벨을 다시 누르면 뗀다. 붙은 라벨은 색만이 아니라 이름으로도 보인다.
struct ColorLabelRow: View {
    let current: PhotoColorLabel?
    /// 사용자가 붙인 라벨 이름(빨강 → 블로그).
    let names: [PhotoColorLabel: String]
    let choose: @MainActor (PhotoColorLabel) -> Void
    let rename: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text("라벨").font(.caption).foregroundStyle(.secondary)
            if let current {
                Text(name(current)).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                Button { choose(label) } label: {
                    Circle().fill(label.color).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: current == label ? 2 : 0))
                        .opacity(current == nil || current == label ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .help((names[label].map { "\($0) · \(label.title)" } ?? label.title) + (label.keyHint.map { " (\($0))" } ?? ""))
                .accessibilityLabel("\(name(label)) 라벨")
                .accessibilityAddTraits(current == label ? .isSelected : [])
            }
        }
        .contextMenu { Button("라벨 이름 정하기…") { rename() } }
    }

    private func name(_ label: PhotoColorLabel) -> String { names[label] ?? label.title }
}

/// 색상 라벨마다 쓰임 이름을 붙이는 창(빨강 → 블로그, 초록 → 인화). 비우면 색 이름으로 돌아간다.
struct ColorLabelNamesSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [PhotoColorLabel: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("라벨 이름").font(.title3.weight(.semibold))
            Text("색마다 쓰임을 적어 두면 오른쪽 패널·메뉴·조건에 이름으로 보입니다(예: 빨강 → 블로그). 비워 두면 색 이름을 씁니다.")
                .font(.callout).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                    GridRow {
                        Circle().fill(label.color).frame(width: 12, height: 12)
                        Text(label.title).foregroundStyle(Palette.muted)
                        TextField(label.title, text: Binding(get: { draft[label] ?? "" }, set: { draft[label] = $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .accessibilityLabel("\(label.title) 라벨 이름")
                        Text(label.keyHint.map { "\($0) 키" } ?? "").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
            HStack {
                Button("모두 색 이름으로") { draft = [:] }
                    .disabled(draft.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") {
                    model.setColorLabelNames(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Palette.accent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { draft = model.colorLabelNames }
    }
}
