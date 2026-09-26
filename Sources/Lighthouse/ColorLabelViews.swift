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

/// 오른쪽 패널의 색상 라벨 고르기. 붙어 있는 라벨을 다시 누르면 뗀다.
struct ColorLabelRow: View {
    let current: PhotoColorLabel?
    let choose: @MainActor (PhotoColorLabel?) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text("라벨").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                Button { choose(current == label ? nil : label) } label: {
                    Circle().fill(label.color).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: current == label ? 2 : 0))
                        .opacity(current == nil || current == label ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .help(label.title + (label.keyHint.map { " (\($0))" } ?? ""))
                .accessibilityLabel("\(label.title) 라벨")
                .accessibilityAddTraits(current == label ? .isSelected : [])
            }
        }
    }
}
