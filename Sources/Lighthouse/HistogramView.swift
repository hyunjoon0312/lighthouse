import SwiftUI
import LighthouseCore

struct HistogramView: View {
    @EnvironmentObject private var model: LibraryModel

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
            .frame(height: 78)
            if let histogram = model.histogram {
                Text(String(format: "하이라이트 %.1f%% · 섀도 %.1f%% 잘림", histogram.highlightClipped * 100,
                            histogram.shadowClipped * 100))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("히스토그램")
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
