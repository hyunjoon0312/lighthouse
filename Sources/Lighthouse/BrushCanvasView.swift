import AppKit
import SwiftUI
import LighthouseCore

struct BrushCanvasView: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var canvas: CanvasStrokeState
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
                                         edits: photo.edits)
        return CGFloat(geometry.displayRadius(fromSource: model.brushRadius)) * min(imageRect.width, imageRect.height)
    }

    private var retouchDisplayRadius: CGFloat {
        guard photo.metadata.width > 0, photo.metadata.height > 0 else { return 0 }
        let geometry = PhotoGeometry(sourceWidth: Double(photo.metadata.width),
                                     sourceHeight: Double(photo.metadata.height), edits: photo.edits)
        return CGFloat(geometry.displayRadius(fromSource: model.retouchRadius)) * min(imageRect.width, imageRect.height)
    }

    var body: some View {
        ZStack {
            if model.adjustmentPanel == .local, model.showsMask, let mask = model.maskImage, model.selectedLocal != nil {
                Color.orange.opacity(0.35)
                    .mask(Image(nsImage: mask).resizable().interpolation(.high).luminanceToAlpha())
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .allowsHitTesting(false)
            }
            Canvas { context, _ in
                context.clip(to: Path(imageRect))
                let radius = displayRadius
                let points = canvas.draftPoints
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
                if model.canDrawLocal, let cursor = canvas.brushCursor {
                    let center = CGPoint(x: imageRect.minX + cursor.x * imageRect.width,
                                         y: imageRect.minY + cursor.y * imageRect.height)
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
                    context.stroke(ring, with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
                if model.adjustmentPanel == .retouch {
                    let radius = retouchDisplayRadius
                    if !canvas.retouchDraftPoints.isEmpty {
                        var path = Path()
                        let first = canvasPoint(canvas.retouchDraftPoints[0])
                        if canvas.retouchDraftPoints.count == 1 {
                            path.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                                       width: radius * 2, height: radius * 2))
                            context.fill(path, with: .color(.orange.opacity(0.5)))
                        } else {
                            path.move(to: first)
                            for point in canvas.retouchDraftPoints.dropFirst() { path.addLine(to: canvasPoint(point)) }
                            context.stroke(path, with: .color(.orange.opacity(0.55)),
                                           style: StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round))
                        }
                    }
                    if let source = model.cloneSource, let display = model.displayPoint(fromSource: source) {
                        let center = canvasPoint(display)
                        var marker = Path()
                        marker.move(to: CGPoint(x: center.x - 9, y: center.y))
                        marker.addLine(to: CGPoint(x: center.x + 9, y: center.y))
                        marker.move(to: CGPoint(x: center.x, y: center.y - 9))
                        marker.addLine(to: CGPoint(x: center.x, y: center.y + 9))
                        marker.addEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                        context.stroke(marker, with: .color(.cyan), lineWidth: 1.5)
                    }
                    if model.canUseRetouchCanvas, let cursor = canvas.retouchCursor {
                        let center = canvasPoint(cursor)
                        var ring = Path()
                        ring.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
                        context.stroke(ring, with: .color(model.isPickingCloneSource ? .cyan : .white), lineWidth: 1)
                    }
                }
            }
            .allowsHitTesting(false)
            if model.canDrawLocal || model.canUseRetouchCanvas {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: imageRect.width, height: imageRect.height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            if model.adjustmentPanel == .local { canvas.brushCursor = normalized(point) }
                            else { canvas.retouchCursor = normalized(point) }
                        case .ended:
                            canvas.brushCursor = nil
                            canvas.retouchCursor = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = normalized(value.location)
                            if !dragging {
                                dragging = true
                                if model.adjustmentPanel == .local { model.beginStroke(at: point) }
                                else { model.beginRetouch(at: point) }
                            } else {
                                if model.adjustmentPanel == .local {
                                    model.extendStroke(to: point, shortSide: min(imageRect.width, imageRect.height))
                                } else {
                                    model.extendRetouch(to: point, shortSide: min(imageRect.width, imageRect.height))
                                }
                            }
                        }
                        .onEnded { _ in
                            if dragging {
                                if model.adjustmentPanel == .local { model.commitStroke() }
                                else { model.commitRetouch() }
                            }
                            dragging = false
                        })
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .accessibilityLabel(canvasAccessibilityLabel)
            }
        }
        .frame(width: availableSize.width, height: availableSize.height)
        .onChange(of: photo.id) { _, _ in dragging = false }
        .onChange(of: model.isLocalEditing) { _, editing in if !editing { dragging = false } }
        .onChange(of: model.adjustmentPanel) { _, _ in dragging = false }
    }

    private func normalized(_ point: CGPoint) -> MaskPoint {
        MaskPoint(x: min(1, max(0, Double(point.x / imageRect.width))),
                  y: min(1, max(0, Double(point.y / imageRect.height))))
    }

    private func canvasPoint(_ point: MaskPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * imageRect.width,
                y: imageRect.minY + point.y * imageRect.height)
    }

    private var canvasAccessibilityLabel: String {
        if model.adjustmentPanel == .retouch {
            if model.isPickingCloneSource { return "복제 소스 위치 선택" }
            return model.retouchMode == .heal ? "스팟 복구 그리기" : "복제 영역 그리기"
        }
        return model.brushTool == .eraser ? "부분 보정 영역 지우기" : "부분 보정 영역 칠하기"
    }
}
