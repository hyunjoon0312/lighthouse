import SwiftUI
import LighthouseCore

/// 히스토그램을 끌어 바꾸는 밝기 구간(Lightroom처럼 왼쪽부터 검정·섀도·노출·하이라이트·흰색).
/// 범위와 값 표시는 오른쪽 패널 빛 묶음의 슬라이더와 같다.
enum HistogramZone: CaseIterable {
    case blacks, shadows, exposure, highlights, whites

    /// 구간 경계(히스토그램 너비에 대한 비율).
    private static let edges: [Double] = [0, 0.1, 0.33, 0.67, 0.9, 1]

    static func at(_ fraction: Double) -> HistogramZone {
        allCases.first { fraction < edges[$0.index + 1] } ?? .whites
    }

    private var index: Int { Self.allCases.firstIndex(of: self)! }
    var start: Double { Self.edges[index] }
    var end: Double { Self.edges[index + 1] }

    var title: String {
        switch self {
        case .blacks: "검정"
        case .shadows: "섀도"
        case .exposure: "노출"
        case .highlights: "하이라이트"
        case .whites: "흰색"
        }
    }

    var keyPath: WritableKeyPath<EditSettings, Double> {
        switch self {
        case .blacks: \.blacks
        case .shadows: \.shadows
        case .exposure: \.exposure
        case .highlights: \.highlights
        case .whites: \.whites
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -4...4
        case .highlights: 0...2
        case .blacks, .shadows, .whites: -1...1
        }
    }

    /// 히스토그램 너비만큼 끌면 슬라이더 범위의 절반만큼 바뀐다.
    func value(from start: Double, dragged distance: Double, width: Double) -> Double {
        let changed = start + distance / max(width, 1) * (range.upperBound - range.lowerBound) / 2
        return min(range.upperBound, max(range.lowerBound, changed))
    }

    func valueText(_ value: Double) -> String {
        if self == .exposure { return String(format: "%.2f EV", value) }
        let amount = ((value - EditSettings.neutral[keyPath: keyPath]) * 100).rounded()
        return amount == 0 ? "0" : String(format: "%+.0f", amount)
    }
}

/// 히스토그램 끌기를 시작한 구간과 그때의 값. 끄는 동안 이 값에서 끈 거리만큼 바꾼다(누적하지 않는다).
struct HistogramDrag: Equatable {
    let zone: HistogramZone
    let start: Double
}

extension LibraryModel {
    /// 원본 보기·원본 없음에서는 바뀐 값이 화면에 보이지 않으므로 히스토그램을 끌어 바꾸지 않는다.
    var canAdjustFromHistogram: Bool {
        guard let photo = selection else { return false }
        return !isOriginal && !isMissing(photo)
    }

    /// `fraction`은 히스토그램 너비에 대한 누른 곳의 비율이다.
    func beginHistogramDrag(at fraction: Double) -> HistogramDrag? {
        guard canAdjustFromHistogram, let edits = selection?.edits else { return nil }
        let zone = HistogramZone.at(fraction)
        return HistogramDrag(zone: zone, start: edits[keyPath: zone.keyPath])
    }

    /// 끄는 동안의 변경은 `endHistogramDrag()`까지 실행 취소 한 단계로 묶인다.
    func dragHistogram(_ drag: HistogramDrag, distance: Double, width: Double) {
        guard var edits = selection?.edits else { return }
        edits[keyPath: drag.zone.keyPath] = drag.zone.value(from: drag.start, dragged: distance, width: width)
        updateEdits(edits, continuous: true)
    }

    func endHistogramDrag() { endContinuousEdit() }

    /// 두 번 누른 구간의 값만 기본값으로 돌린다(실행 취소 한 단계).
    func resetHistogramZone(at fraction: Double) {
        guard canAdjustFromHistogram, var edits = selection?.edits else { return }
        let zone = HistogramZone.at(fraction)
        edits[keyPath: zone.keyPath] = EditSettings.neutral[keyPath: zone.keyPath]
        updateEdits(edits)
    }
}

struct HistogramView: View {
    @EnvironmentObject private var model: LibraryModel
    /// 포인터가 올라간 구간. 끄는 동안에는 끌기 시작한 구간을 유지한다.
    @State private var hovered: HistogramZone?
    @State private var drag: HistogramDrag?

    private var activeZone: HistogramZone? { drag?.zone ?? (model.canAdjustFromHistogram ? hovered : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
                if let histogram = model.histogram {
                    Canvas { context, size in
                        let scale = Self.scale(for: histogram)
                        for (bins, color) in [(histogram.red, Color.red), (histogram.green, Color.green),
                                              (histogram.blue, Color.blue)] {
                            context.fill(Self.path(bins, scale: scale, in: size), with: .color(color.opacity(0.45)))
                        }
                        context.stroke(Self.path(histogram.luminance, scale: scale, in: size, closed: false),
                                       with: .color(.white.opacity(0.7)), lineWidth: 1)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    if model.canAdjustFromHistogram { dragSurface.padding(.horizontal, 4).padding(.vertical, 3) }
                    HStack {
                        clipButton(fraction: histogram.shadowClipped, color: .blue, label: "섀도")
                        Spacer()
                        clipButton(fraction: histogram.highlightClipped, color: .red, label: "하이라이트")
                    }
                    .padding(4)
                } else {
                    Text(!model.showsSingleImage ? "사진 보기에서 표시됩니다" :
                            model.imageError != nil || model.selection.map(model.isMissing) == true ? "표시할 수 없음" : "계산 중…")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
            }
            // 그리드처럼 히스토그램을 계산하지 않는 화면에서는 안내 한 줄 높이로 줄여 아래 항목을 올린다.
            .frame(height: model.histogram == nil && !model.showsSingleImage ? 30 : 78)
            if let histogram = model.histogram {
                // 구간 위에서는 그 구간의 이름과 값을, 아니면 잘린 비율을 보인다.
                if let zone = activeZone, let edits = model.selection?.edits {
                    Text("\(zone.title) \(zone.valueText(edits[keyPath: zone.keyPath])) · 좌우로 끌어 조절")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(String(format: "하이라이트 %.1f%% · 섀도 %.1f%% 잘림", histogram.highlightClipped * 100,
                                histogram.shadowClipped * 100))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("히스토그램")
    }

    /// 히스토그램을 좌우로 끌어 포인터 아래 구간(검정·섀도·노출·하이라이트·흰색)의 값을 바꾼다. 한 번 끈 것은 실행 취소 한 단계이고,
    /// 두 번 누르면 그 구간 값만 기본값으로 돌아간다.
    private var dragSurface: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                if let zone = activeZone {
                    Rectangle().fill(.white.opacity(0.08))
                        .frame(width: width * (zone.end - zone.start))
                        .offset(x: width * zone.start)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase { hovered = HistogramZone.at(location.x / width) } else { hovered = nil }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if drag == nil { drag = model.beginHistogramDrag(at: value.startLocation.x / width) }
                if let drag { model.dragHistogram(drag, distance: value.translation.width, width: width) }
            }.onEnded { _ in
                if drag != nil { model.endHistogramDrag() }
                drag = nil
            })
            .onTapGesture(count: 2, coordinateSpace: .local) { location in model.resetHistogramZone(at: location.x / width) }
            .pointerStyle(.columnResize)
            .help("좌우로 끌어 검정·섀도·노출·하이라이트·흰색을 조절합니다. 두 번 누르면 그 값을 기본으로 돌립니다")
        }
    }

    private func clipButton(fraction: Double, color: Color, label: String) -> some View {
        let clipped = fraction >= 0.0005
        return Button { model.showsClipping.toggle() } label: {
            Image(systemName: model.showsClipping ? "triangle.fill" : "triangle")
                .font(.system(size: 9))
                .foregroundStyle(clipped ? color : .gray)
        }
        .buttonStyle(.plain)
        .help("잘린 부분 표시 (J)")
        .accessibilityLabel("\(label) 잘림 표시 \(model.showsClipping ? "끄기" : "켜기")")
    }

    /// 가장 많이 쌓인 양 끝 칸이 그래프를 납작하게 만들지 않도록 1…254칸 기준으로 맞춘다.
    private static func scale(for histogram: ImageHistogram) -> Double {
        let peak = [histogram.red, histogram.green, histogram.blue, histogram.luminance]
            .map { $0[1...254].max() ?? 0 }.max() ?? 0
        return Double(max(1, peak)) * 1.05
    }

    private static func path(_ bins: [Int], scale: Double, in size: CGSize, closed: Bool = true) -> Path {
        var path = Path()
        let step = size.width / 255
        let point = { (index: Int) in
            CGPoint(x: Double(index) * step, y: size.height * (1 - min(1, Double(bins[index]) / scale)))
        }
        if closed {
            path.move(to: CGPoint(x: 0, y: size.height))
            for index in 0..<256 { path.addLine(to: point(index)) }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        } else {
            path.move(to: point(0))
            for index in 1..<256 { path.addLine(to: point(index)) }
        }
        return path
    }
}
