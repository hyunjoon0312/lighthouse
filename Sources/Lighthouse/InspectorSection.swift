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
    /// 보정 묶음이면 저장 이름. 한 묶음만 펴기가 켜져 있을 때 이 묶음을 펴면 다른 보정 묶음을 접는다.
    private let soloKey: String?
    @AppStorage private var expanded: Bool
    @AppStorage(InspectorSolo.settingKey) private var solo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `storageKey`는 접은 상태를 기억하는 이름이다. 묶음마다 달라야 한다. `soloGroup`은 보정 묶음이다.
    init(_ title: String, storageKey: String, expandedByDefault: Bool = true, modified: Bool = false,
         soloGroup: Bool = false, reset: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.modified = modified
        self.reset = reset
        self.accessory = accessory()
        self.content = content()
        soloKey = soloGroup ? storageKey : nil
        if soloGroup { InspectorSolo.register(storageKey) }
        _expanded = AppStorage(wrappedValue: expandedByDefault, storageKey)
    }

    private var soloing: Bool { soloKey != nil && solo }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        expanded.toggle()
                        if expanded, let soloKey { InspectorSolo.expand(soloKey) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        // 묶음 제목은 안의 슬라이더 이름(caption)보다 한 단계 크게 해 위계를 둔다.
                        Text(title).font(.subheadline.weight(.semibold))
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
                .accessibilityHint(soloing ? "펼치면 다른 보정 묶음을 접습니다" : "눌러서 펼치거나 접습니다")
                // 켜 둔 것을 잊어도 다른 묶음이 왜 접히는지 알 수 있게 한다.
                .help(soloing ? "한 묶음만 펴기: 펼치면 다른 보정 묶음을 접습니다. 오른쪽 클릭으로 끕니다" : "")
                .contextMenu {
                    if let reset {
                        Button("‘\(title)’ 초기화", action: reset).disabled(!modified)
                    }
                    if let soloKey {
                        Divider()
                        Toggle("한 묶음만 펴기", isOn: Binding(get: { solo }, set: { on in
                            solo = on
                            // 켜면 이 묶음만 남기고 접어 바로 달라진 것을 보인다.
                            if on { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { InspectorSolo.expand(soloKey) } }
                        }))
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

/// 보정 묶음의 "한 묶음만 펴기"(Lightroom의 Solo Mode). 켜 두면 보정 묶음 하나를 펼 때 다른 보정 묶음을 접어
/// 긴 오른쪽 패널을 짧게 쓴다. 표시·키워드, 프리셋, 스냅숏, 파일 정보 묶음은 따로 둔다.
@MainActor
enum InspectorSolo {
    static let settingKey = "inspector.soloMode"
    /// 그린 적 있는 보정 묶음의 저장 이름.
    private(set) static var sectionKeys: Set<String> = []

    static func register(_ key: String) { sectionKeys.insert(key) }

    /// 보정 묶음 `key`를 편다. 한 묶음만 펴기가 켜져 있으면 `keys`의 다른 묶음을 접는다.
    static func expand(_ key: String, among keys: Set<String> = sectionKeys, defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: settingKey) {
            for other in keys where other != key { defaults.set(false, forKey: other) }
        }
        defaults.set(true, forKey: key)
    }
}
