import SwiftUI

/// 제목·값·슬라이더 한 줄. 제목이나 값을 두 번 누르면 그 항목만 기본값으로 돌린다(한 번에 실행 취소된다).
/// 슬라이더 손잡이는 AppKit이 마우스를 먼저 받아 두 번 누르기를 알 수 없으므로 글자 줄에서 받는다.
struct SliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let set: @MainActor (Double) -> Void
    let end: @MainActor () -> Void
    let reset: (@MainActor () -> Void)?

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(valueText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset?() }
            .help(reset == nil ? "" : "두 번 누르면 기본값으로 돌아갑니다")
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range) { editing in
                if !editing { end() }
            }
            .accessibilityLabel(title)
            .accessibilityAction(named: Text("기본값으로")) { reset?() }
        }
    }
}
