import SwiftUI
import LighthouseCore

/// 컬러 그레이딩: 영역 하나를 골라 색상 바퀴와 슬라이더로 조절한다. 혼합·균형은 모든 영역에 공통이다.
struct ColorGradingControls: View {
    @EnvironmentObject private var model: LibraryModel
    let edits: EditSettings
    @State private var region: ColorGradeRegion = .shadows

    var body: some View {
        Group {
            Divider()
            Text("컬러 그레이딩").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(ColorGradeRegion.allCases, id: \.self) { item in
                    regionButton(item)
                }
            }
            ColorWheel(hue: zone.hue, saturation: zone.saturation,
                       change: { hue, saturation in
                           updateZone(continuous: true) { $0.hue = hue; $0.saturation = saturation }
                       },
                       end: { model.endContinuousEdit() },
                       reset: { updateZone(continuous: true) { $0 = ColorGradeZone() } })
                .frame(width: 160, height: 160)
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel("\(region.title) 색상 바퀴")
                .accessibilityValue("색조 \(Int(zone.hue.rounded()))도, 채도 \(Int((zone.saturation * 100).rounded()))")
                .help("끌어서 색조와 채도를 고릅니다. 두 번 누르면 이 영역을 초기화합니다.")
            gradingSlider("색조", value: zone.hue, range: 0...359, format: "%.0f°", defaultValue: 0) { value in
                updateZone(continuous: true) { $0.hue = value.isFinite ? min(359, max(0, value)) : 0 }
            }
            gradingSlider("채도", value: zone.saturation * 100, range: 0...100, format: "%.0f", defaultValue: 0) { value in
                updateZone(continuous: true) { $0.saturation = value.isFinite ? min(1, max(0, value / 100)) : 0 }
            }
            gradingSlider("명도", value: zone.luminance * 100, range: -100...100, format: "%+.0f",
                          defaultValue: 0) { value in
                updateZone(continuous: true) { $0.luminance = value.isFinite ? min(1, max(-1, value / 100)) : 0 }
            }
            gradingSlider("혼합", value: grading.blending * 100, range: 0...100, format: "%.0f",
                          defaultValue: ColorGrading.neutral.blending * 100) { value in
                update(continuous: true) { $0.blending = value.isFinite ? min(1, max(0, value / 100)) : 0.5 }
            }
            gradingSlider("균형", value: grading.balance * 100, range: -100...100, format: "%+.0f",
                          defaultValue: 0) { value in
                update(continuous: true) { $0.balance = value.isFinite ? min(1, max(-1, value / 100)) : 0 }
            }
            Button("\(region.title) 초기화") { resetZone() }
                .disabled(zone == ColorGradeZone())
                .accessibilityLabel("\(region.title) 컬러 그레이딩 초기화")
        }
    }

    private var grading: ColorGrading { edits.colorGrading }
    private var zone: ColorGradeZone { grading[keyPath: region.keyPath] }

    /// 선택한 영역은 굵은 글씨와 강조색 테두리로 보여 준다(창이 비활성이어도 보이도록 직접 그린다).
    /// 채도나 명도가 있는 영역에는 색 점을 붙인다.
    private func regionButton(_ item: ColorGradeRegion) -> some View {
        let itemZone = grading[keyPath: item.keyPath]
        let selected = region == item
        return Button { region = item } label: {
            HStack(spacing: 3) {
                Text(item.title).font(.caption.weight(selected ? .bold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
                if !itemZone.isNeutral {
                    Circle().fill(Color(hue: itemZone.hue / 360, saturation: 1, brightness: 1))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: selected ? 1.5 : 0))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func update(continuous: Bool = false, _ change: (inout ColorGrading) -> Void) {
        var next = edits
        change(&next.colorGrading)
        model.updateEdits(next, continuous: continuous)
    }

    private func updateZone(continuous: Bool = false, _ change: (inout ColorGradeZone) -> Void) {
        let path = region.keyPath
        update(continuous: continuous) { change(&$0[keyPath: path]) }
    }

    private func resetZone() {
        updateZone { $0 = ColorGradeZone() }
    }

    /// 두 번 누르면 `defaultValue`로 돌아간다.
    private func gradingSlider(_ title: String, value: Double, range: ClosedRange<Double>, format: String,
                               defaultValue: Double, set: @escaping @MainActor (Double) -> Void) -> some View {
        SliderRow(title: title, value: value, range: range, valueText: String(format: format, value),
                  set: { set($0) }, end: { model.endContinuousEdit() },
                  reset: { set(defaultValue); model.endContinuousEdit() })
    }
}

extension ColorGradeRegion {
    var title: String {
        switch self {
        case .shadows: "그림자"
        case .midtones: "중간톤"
        case .highlights: "하이라이트"
        case .global: "전체"
        }
    }
}

/// 0°(빨강)가 오른쪽이고 반시계 방향으로 도는 바퀴. 중심에서의 거리가 채도다. 좌표는 SwiftUI처럼 y가 아래로 커진다.
enum ColorWheelGeometry {
    static func value(at location: CGPoint, size: CGFloat) -> (hue: Double, saturation: Double) {
        let radius = Double(size) / 2
        let dx = Double(location.x) - radius
        let dy = radius - Double(location.y)
        guard radius > 0, dx != 0 || dy != 0 else { return (0, 0) }
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        if hue >= 360 { hue = 0 }
        return (hue, min(1, (dx * dx + dy * dy).squareRoot() / radius))
    }

    static func point(hue: Double, saturation: Double, size: CGFloat) -> CGPoint {
        let radius = Double(size) / 2
        let angle = hue * .pi / 180
        return CGPoint(x: radius + cos(angle) * saturation * radius,
                       y: radius - sin(angle) * saturation * radius)
    }
}

/// 바퀴 클릭과 두 번 누르기를 한 실행 취소 단계로 묶는다. 제자리 클릭은 누른 색을 바로 보여 주되 연속 편집을 잠시 열어 두고,
/// 그 사이 두 번 누르기가 오면 초기화를 같은 단계에 합친다. 그래서 초기화 뒤 ⌘Z 한 번이면 클릭 전 값으로 돌아간다.
@MainActor
final class ColorWheelGestureState {
    private let settleDelay: Duration
    private var pendingEnd: Task<Void, Never>?

    init(settleDelay: Duration = .milliseconds(350)) {
        self.settleDelay = settleDelay
    }

    func dragEnded(moved: Bool, end: @escaping @MainActor () -> Void) {
        pendingEnd?.cancel()
        pendingEnd = nil
        guard !moved else { end(); return }
        pendingEnd = Task { [settleDelay] in
            try? await Task.sleep(for: settleDelay)
            if !Task.isCancelled { end() }
        }
    }

    func doubleTapped(reset: () -> Void, end: () -> Void) {
        pendingEnd?.cancel()
        pendingEnd = nil
        reset()
        end()
    }
}

private struct ColorWheel: View {
    let hue: Double
    let saturation: Double
    let change: (Double, Double) -> Void
    let end: @MainActor () -> Void
    /// 연속 편집으로 영역을 초기화한다. 끝내기는 `end`가 맡는다.
    let reset: () -> Void
    @State private var gesture = ColorWheelGestureState()

    /// AngularGradient는 화면에서 시계 방향으로 진행하므로 색조를 거꾸로 놓아 반시계 방향 바퀴를 만든다.
    private static let hueStops = stride(from: 360, through: 0, by: -30).map {
        Color(hue: Double($0 % 360) / 360, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let marker = ColorWheelGeometry.point(hue: hue, saturation: saturation, size: size)
            ZStack {
                Circle().fill(AngularGradient(colors: Self.hueStops, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: size / 2))
                Circle().stroke(Color.secondary.opacity(0.4))
                Circle().stroke(Color.white, lineWidth: 3)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .frame(width: 12, height: 12)
                    .position(marker)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let picked = ColorWheelGeometry.value(at: value.location, size: size)
                    change(picked.hue, picked.saturation)
                }
                .onEnded { value in
                    let moved = hypot(value.translation.width, value.translation.height) > 3
                    gesture.dragEnded(moved: moved, end: end)
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { gesture.doubleTapped(reset: reset, end: end) })
        }
    }
}
