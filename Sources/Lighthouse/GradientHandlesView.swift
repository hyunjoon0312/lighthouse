import SwiftUI
import LighthouseCore

/// 선택한 그라데이션 영역의 안내선과 조절점. 좌표는 원본 기준으로 저장하고 화면에는 회전·크롭을 거쳐 그린다.
struct GradientHandlesView: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset
    let gradient: MaskGradient
    let imageRect: CGRect
    let size: CGSize
    private static let space = "gradientHandles"

    private var geometry: LocalMaskGeometry {
        LocalMaskGeometry(sourceWidth: Double(photo.metadata.width), sourceHeight: Double(photo.metadata.height),
                          edits: photo.edits)
    }

    var body: some View {
        ZStack {
            Canvas { context, _ in
                context.clip(to: Path(imageRect))
                for (path, dashed) in guides {
                    context.stroke(path, with: .color(.black.opacity(0.45)), lineWidth: 3)
                    context.stroke(path, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
                }
            }
            .allowsHitTesting(false)
            ForEach(gradient.handles, id: \.handle) { item in
                Circle()
                    .fill(item.handle == .center ? Color.orange : Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                    .frame(width: 13, height: 13)
                    .contentShape(Circle().inset(by: -6))
                    .position(canvasPoint(item.point))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { value in model.moveGradientHandle(item.handle, toDisplay: normalized(value.location)) }
                        .onEnded { _ in model.endContinuousEdit() })
                    .accessibilityLabel(label(item.handle))
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.space)
    }

    private var guides: [(Path, Bool)] {
        switch gradient {
        case .linear(let start, let end):
            let s = canvasPoint(start), e = canvasPoint(end)
            let length = hypot(e.x - s.x, e.y - s.y)
            var axis = Path()
            axis.move(to: s)
            axis.addLine(to: e)
            guard length > 0.5 else { return [(axis, true)] }
            let reach = hypot(imageRect.width, imageRect.height)
            let normal = CGPoint(x: -(e.y - s.y) / length * reach, y: (e.x - s.x) / length * reach)
            func across(_ point: CGPoint) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: point.x - normal.x, y: point.y - normal.y))
                path.addLine(to: CGPoint(x: point.x + normal.x, y: point.y + normal.y))
                return path
            }
            return [(across(s), false), (across(e), true), (axis, true)]
        case .radial(let center, let radiusX, let radiusY, let softness):
            let inner = 1 - min(1, max(0, softness))
            var guides = [(ellipse(center: center, radiusX: radiusX, radiusY: radiusY), false)]
            if inner > 0.02 {
                guides.append((ellipse(center: center, radiusX: radiusX * inner, radiusY: radiusY * inner), true))
            }
            return guides
        }
    }

    /// 기울기 보정이 있으면 원본의 타원이 화면에서 기울어 보이므로 원본 둘레를 점으로 나눠 옮긴다.
    private func ellipse(center: MaskPoint, radiusX: Double, radiusY: Double) -> Path {
        var path = Path()
        for step in 0...72 {
            let angle = Double(step) / 72 * 2 * .pi
            let point = canvasPoint(MaskPoint(x: center.x + radiusX * cos(angle), y: center.y + radiusY * sin(angle)))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func canvasPoint(_ source: MaskPoint) -> CGPoint {
        let display = geometry.displayPoint(fromSource: source)
        return CGPoint(x: imageRect.minX + display.x * imageRect.width, y: imageRect.minY + display.y * imageRect.height)
    }

    private func normalized(_ point: CGPoint) -> MaskPoint {
        MaskPoint(x: min(1, max(0, Double((point.x - imageRect.minX) / imageRect.width))),
                  y: min(1, max(0, Double((point.y - imageRect.minY) / imageRect.height))))
    }

    private func label(_ handle: MaskGradientHandle) -> String {
        switch handle {
        case .start: "그라데이션 시작점 (효과 100%)"
        case .end: "그라데이션 끝점 (효과 0%)"
        case .center: "그라데이션 위치 이동"
        case .radiusX: "원형 영역 가로 크기"
        case .radiusY: "원형 영역 세로 크기"
        }
    }
}
