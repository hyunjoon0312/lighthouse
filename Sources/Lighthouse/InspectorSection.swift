import SwiftUI

/// 오른쪽 패널의 접히는 묶음. Lightroom 현상 패널처럼 제목 줄을 눌러 접고 펴며, 접은 상태는 다음 실행에도 기억한다.
/// 묶음의 보정값이 기본값과 다르면 제목 옆에 점을 찍어, 접혀 있어도 이 묶음이 사진을 바꾸고 있음을 알린다.
/// 오른쪽 클릭 메뉴로 이 묶음만 초기화한다(한 번에 실행 취소된다).
struct InspectorSection<Accessory: View, Content: View>: View {
    let title: String
    let modified: Bool
    let reset: (() -> Void)?
    let accessory: Accessory
    let content: Content
    @AppStorage private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `storageKey`는 접은 상태를 기억하는 이름이다. 묶음마다 달라야 한다.
    init(_ title: String, storageKey: String, expandedByDefault: Bool = true, modified: Bool = false,
         reset: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.modified = modified
        self.reset = reset
        self.accessory = accessory()
        self.content = content()
        _expanded = AppStorage(wrappedValue: expandedByDefault, storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        Text(title).font(.caption.weight(.semibold))
                            .foregroundStyle(expanded ? Color.primary : Palette.inactive)
                        if modified {
                            Circle().fill(Palette.accent).frame(width: 5, height: 5)
                                .help("기본값에서 바뀐 항목이 있습니다")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(modified ? "\(title), 바뀜" : title)
                .accessibilityValue(expanded ? "펼침" : "접힘")
                .accessibilityHint("눌러서 펼치거나 접습니다")
                .contextMenu {
                    if let reset {
                        Button("‘\(title)’ 초기화", action: reset).disabled(!modified)
                    }
                }
                accessory
            }
            if expanded {
                VStack(alignment: .leading, spacing: 12) { content }
                    .transition(.opacity)
            }
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, storageKey: String, expandedByDefault: Bool = true, modified: Bool = false,
         reset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, storageKey: storageKey, expandedByDefault: expandedByDefault, modified: modified,
                  reset: reset, accessory: { EmptyView() }, content: content)
    }
}
