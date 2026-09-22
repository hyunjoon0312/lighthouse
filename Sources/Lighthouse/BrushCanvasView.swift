import AppKit
import SwiftUI
import LighthouseCore

struct BrushCanvasView: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset
    let imageSize: NSSize
    let availableSize: CGSize
    @State private var dragging = false

    private var imageRect: CGRect {
        let width = max(1, availableSize.width - 40)
        let height = max(1, availableSize.height - 40)
        let scale = min(width / max(1, imageSize.width), height / max(1, imageSize.height))
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (availableSize.width - fitted.width) / 2,
                      y: (availableSize.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private var displayRadius: CGFloat {
        guard photo.metadata.width > 0, photo.metadata.height > 0 else { return 0 }
        let geometry = LocalMaskGeometry(sourceWidth: Double(photo.metadata.width),
                                         sourceHeight: Double(photo.metadata.height),
                                         rotationQuarterTurns: photo.edits.rotationQuarterTurns,
                                         cropAspect: photo.edits.cropAspect)
        return CGFloat(geometry.displayRadius(fromSource: model.brushRadius)) * min(imageRect.width, imageRect.height)
    }

    var body: some View {
        ZStack {
            if model.showsMask, let mask = model.maskImage, model.selectedLocal != nil {
                Color.orange.opacity(0.35)
                    .mask(Image(nsImage: mask).resizable().interpolation(.high).luminanceToAlpha())
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .allowsHitTesting(false)
            }
            Canvas { context, _ in
                context.clip(to: Path(imageRect))
                let radius = displayRadius
                let points = model.draftPoints
                if !points.isEmpty {
                    var path = Path()
                    let first = CGPoint(x: imageRect.minX + points[0].x * imageRect.width,
                                        y: imageRect.minY + points[0].y * imageRect.height)
                    if points.count == 1 {
                        path.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                                   width: radius * 2, height: radius * 2))
                        context.fill(path, with: .color(model.brushTool == .eraser ? .red.opacity(0.55) : .orange.opacity(0.55)))
                    } else {
                        path.move(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: CGPoint(x: imageRect.minX + point.x * imageRect.width,
                                                     y: imageRect.minY + point.y * imageRect.height))
                        }
                        context.stroke(path, with: .color(model.brushTool == .eraser ? .red.opacity(0.6) : .orange.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round))
                    }
                }
                if model.canDrawLocal, let cursor = model.brushCursor {
                    let center = CGPoint(x: imageRect.minX + cursor.x * imageRect.width,
                                         y: imageRect.minY + cursor.y * imageRect.height)
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
                    context.stroke(ring, with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            if model.canDrawLocal {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: imageRect.width, height: imageRect.height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): model.brushCursor = normalized(point)
                        case .ended: model.brushCursor = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = normalized(value.location)
                            if !dragging {
                                dragging = true
                                model.beginStroke(at: point)
                            } else {
                                model.extendStroke(to: point, shortSide: min(imageRect.width, imageRect.height))
                            }
                        }
                        .onEnded { _ in
                            if dragging { model.commitStroke() }
                            dragging = false
                        })
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .accessibilityLabel(model.brushTool == .eraser ? "부분 보정 영역 지우기" : "부분 보정 영역 칠하기")
            }
        }
        .frame(width: availableSize.width, height: availableSize.height)
        .onChange(of: photo.id) { _, _ in dragging = false }
        .onChange(of: model.isLocalEditing) { _, editing in if !editing { dragging = false } }
    }

    private func normalized(_ point: CGPoint) -> MaskPoint {
        MaskPoint(x: min(1, max(0, Double(point.x / imageRect.width))),
                  y: min(1, max(0, Double(point.y / imageRect.height))))
    }
}
