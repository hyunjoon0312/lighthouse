import SwiftUI
import LighthouseCore

struct AdvancedColorControls: View {
    @EnvironmentObject private var model: LibraryModel
    let edits: EditSettings
    @State private var channel: CurveChannel = .master
    @State private var selectedPoint: Int?
    @State private var draggingPoint: Int?
    @State private var band: ColorBand = .red

    var body: some View {
        Group {
            Divider()
            HStack {
                Text("RGB 곡선").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Picker("곡선 채널", selection: $channel) {
                    ForEach(CurveChannel.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 96)
                .accessibilityLabel("곡선 채널")
            }
            CurveGraph(points: points, tint: channel.color, selectedIndex: $selectedPoint,
                       draggingIndex: $draggingPoint, update: updatePoints)
                .frame(height: 150)
                .accessibilityLabel("\(channel.title) 톤 곡선")
            HStack {
                Button("점 삭제") { deleteSelectedPoint() }
                    .disabled(!canDeleteSelectedPoint)
                    .accessibilityLabel("선택한 곡선 점 삭제")
                Spacer()
                Button("채널 초기화") { updatePoints(ToneCurves.identityPoints); selectedPoint = nil }
                    .disabled(points == ToneCurves.identityPoints)
                    .accessibilityLabel("\(channel.title) 곡선 초기화")
            }
            .buttonStyle(.bordered)

            Divider()
            Text("색상 범위 HSL").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Picker("색상 범위", selection: $band) {
                ForEach(ColorBand.allCases, id: \.self) { Text($0.koreanName).tag($0) }
            }
            .accessibilityLabel("HSL 색상 범위")
            advancedSlider("색조", value: rangeAdjustment.hue, range: -30...30, format: "%+.0f°") {
                updateRange(\.hue, value: $0)
            }
            advancedSlider("채도", value: rangeAdjustment.saturation * 100, range: -100...100, format: "%+.0f%%") {
                updateRange(\.saturation, value: $0 / 100)
            }
            advancedSlider("명도", value: rangeAdjustment.lightness * 100, range: -100...100, format: "%+.0f%%") {
                updateRange(\.lightness, value: $0 / 100)
            }
            Button("이 색상 초기화") { resetRange() }
                .disabled(rangeAdjustment == ColorRangeAdjustment(band: band))
                .accessibilityLabel("\(band.koreanName) HSL 초기화")

            Divider()
            Text("필름 입자").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            advancedSlider("양", value: edits.grain.amount * 100, range: 0...100, format: "%.0f%%") {
                let value = $0 / 100
                updateGrain { $0.amount = value.isFinite ? min(1, max(0, value)) : 0 }
            }
            advancedSlider("크기", value: edits.grain.size, range: 0.5...8, format: "%.1f px") {
                let value = $0
                updateGrain { $0.size = value.isFinite ? min(8, max(0.5, value)) : 1.5 }
            }
            HStack {
                Text("패턴 \(edits.grain.seed)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("패턴 새로 만들기") {
                    updateGrain { $0.seed = UInt32.random(in: 1...UInt32.max) }
                }
                .accessibilityLabel("필름 입자 패턴 새로 만들기")
            }
        }
        .onChange(of: channel) { _, _ in selectedPoint = nil; draggingPoint = nil }
    }

    private var points: [CurvePoint] {
        switch channel {
        case .master: edits.curves.master
        case .red: edits.curves.red
        case .green: edits.curves.green
        case .blue: edits.curves.blue
        }
    }

    private var canDeleteSelectedPoint: Bool {
        guard let selectedPoint else { return false }
        return selectedPoint > 0 && selectedPoint < points.count - 1
    }

    private var rangeAdjustment: ColorRangeAdjustment {
        edits.colorRanges.first(where: { $0.band == band }) ?? ColorRangeAdjustment(band: band)
    }

    private func updatePoints(_ newPoints: [CurvePoint]) {
        guard newPoints.count >= 2, newPoints.count <= 16 else { return }
        var next = edits
        switch channel {
        case .master: next.curves.master = newPoints
        case .red: next.curves.red = newPoints
        case .green: next.curves.green = newPoints
        case .blue: next.curves.blue = newPoints
        }
        model.updateEdits(next)
    }

    private func deleteSelectedPoint() {
        guard let selectedPoint, canDeleteSelectedPoint else { return }
        var next = points
        next.remove(at: selectedPoint)
        updatePoints(next)
        self.selectedPoint = nil
    }

    private func updateRange(_ keyPath: WritableKeyPath<ColorRangeAdjustment, Double>, value: Double) {
        var next = edits
        var adjustment = rangeAdjustment
        adjustment[keyPath: keyPath] = value
        next.colorRanges.removeAll { $0.band == band }
        if adjustment.hue != 0 || adjustment.saturation != 0 || adjustment.lightness != 0 {
            next.colorRanges.append(adjustment)
            next.colorRanges.sort { $0.band.order < $1.band.order }
        }
        model.updateEdits(next)
    }

    private func resetRange() {
        var next = edits
        next.colorRanges.removeAll { $0.band == band }
        model.updateEdits(next)
    }

    private func updateGrain(_ change: (inout GrainSettings) -> Void) {
        var next = edits
        change(&next.grain)
        model.updateEdits(next)
    }

    private func advancedSlider(_ title: String, value: Double, range: ClosedRange<Double>, format: String,
                                set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range).accessibilityLabel(title)
        }
    }
}

private enum CurveChannel: String, CaseIterable, Identifiable {
    case master, red, green, blue
    var id: String { rawValue }
    var title: String { self == .master ? "RGB" : rawValue.uppercased() }
    var color: Color {
        switch self {
        case .master: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }
}

private struct CurveGraph: View {
    let points: [CurvePoint]
    let tint: Color
    @Binding var selectedIndex: Int?
    @Binding var draggingIndex: Int?
    let update: ([CurvePoint]) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.28))
                Path { path in
                    for fraction in [0.25, 0.5, 0.75] {
                        path.move(to: CGPoint(x: size.width * fraction, y: 0))
                        path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * fraction))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    }
                }.stroke(.white.opacity(0.1), lineWidth: 1)
                Path { path in
                    for sample in 0...128 {
                        let x = Double(sample) / 128
                        let y = (try? AdvancedColorProcessor.curveValue(x, points: points)) ?? x
                        let point = screenPoint(CurvePoint(x: x, y: y), size: size)
                        if sample == 0 { path.move(to: point) }
                        else { path.addLine(to: point) }
                    }
                }.stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle().fill(index == selectedIndex ? Color.orange : tint)
                        .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 1))
                        .frame(width: 10, height: 10).position(screenPoint(point, size: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in handle(value.location, size: size) }
                .onEnded { _ in draggingIndex = nil })
        }
    }

    private func handle(_ location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var next = points
        if draggingIndex == nil {
            let nearest = next.indices.min { distance(location, next[$0], size) < distance(location, next[$1], size) }
            if let nearest, distance(location, next[nearest], size) <= 18 {
                draggingIndex = nearest
                selectedIndex = nearest
            } else if next.count < 16 {
                let point = curvePoint(location, size: size)
                guard !next.contains(where: { abs($0.x - point.x) <= 0.001 }) else { return }
                let insertion = next.firstIndex(where: { $0.x > point.x }) ?? next.count
                guard insertion > 0, insertion < next.count else { return }
                next.insert(point, at: insertion)
                draggingIndex = insertion
                selectedIndex = insertion
                update(next)
                return
            }
        }
        guard let index = draggingIndex, next.indices.contains(index) else { return }
        var point = curvePoint(location, size: size)
        if index == 0 { point.x = 0 }
        else if index == next.count - 1 { point.x = 1 }
        else { point.x = min(next[index + 1].x - 0.001, max(next[index - 1].x + 0.001, point.x)) }
        next[index] = point
        update(next)
    }

    private func curvePoint(_ point: CGPoint, size: CGSize) -> CurvePoint {
        CurvePoint(x: min(1, max(0, point.x / size.width)),
                   y: min(1, max(0, 1 - point.y / size.height)))
    }

    private func screenPoint(_ point: CurvePoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    private func distance(_ location: CGPoint, _ point: CurvePoint, _ size: CGSize) -> CGFloat {
        let screen = screenPoint(point, size: size)
        return hypot(location.x - screen.x, location.y - screen.y)
    }
}

private extension ColorBand {
    var order: Int { ColorBand.allCases.firstIndex(of: self) ?? 0 }
    var koreanName: String {
        switch self {
        case .red: "빨강"
        case .orange: "주황"
        case .yellow: "노랑"
        case .green: "초록"
        case .aqua: "아쿠아"
        case .blue: "파랑"
        case .purple: "보라"
        case .magenta: "마젠타"
        }
    }
}
