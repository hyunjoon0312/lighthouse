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
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(valueText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            // 잠긴 줄은 글자도 흐리게 해 슬라이더와 함께 쓸 수 없음을 보인다.
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if isEnabled { reset?() } }
            .help(reset == nil ? "" : "두 번 누르면 기본값으로 돌아갑니다")
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range) { editing in
                if !editing { end() }
            }
            // macOS 슬라이더는 왼쪽 끝부터 손잡이까지 채운다. 가운데가 기본값인 항목이 많아 강조색으로 채우면
            // 손대지 않은 슬라이더도 바뀐 것처럼 보이므로, 채움은 트랙과 비슷한 중립색으로 둔다.
            // AppKit이 채움 색의 투명도를 쓰지 않아 불투명한 회색을 준다.
            .tint(Color(white: 0.3))
            .accessibilityLabel(title)
            // 음성 안내가 슬라이더 내부 값(예: 대비 1.1) 대신 화면에 보이는 값(+20)을 읽게 한다.
            .accessibilityValue(valueText)
            .accessibilityAction(named: Text("기본값으로")) { reset?() }
        }
    }
}
