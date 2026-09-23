import AppKit
import SwiftUI
import LighthouseCore

struct CropSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let source: PhotoAsset
    @StateObject private var preview = CropPreviewModel()
    @State private var angle: Double
    @State private var crop: NormalizedCrop
    @State private var ratio: CropRatio = .free
    @State private var interaction: CropInteraction?
    @State private var interactionStart = NormalizedCrop.full

    init(source: PhotoAsset) {
        self.source = source
        let geometry = PhotoGeometry(sourceWidth: Double(source.metadata.width),
                                     sourceHeight: Double(source.metadata.height), edits: source.edits)
        let canvas = geometry.canvasSize
        let bounds = geometry.cropBounds
        let initial = NormalizedCrop(
            x: bounds.minX / max(1, canvas.width), y: bounds.minY / max(1, canvas.height),
            width: bounds.width / max(1, canvas.width), height: bounds.height / max(1, canvas.height)
        ).clamped
        _angle = State(initialValue: source.edits.straightenDegrees)
        _crop = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("자유 크롭 및 수평").font(.title2.weight(.semibold))
                Spacer()
                if preview.isRendering { ProgressView().controlSize(.small) }
            }
            GeometryReader { geometry in
                let rect = fittedRect(imageSize: preview.image?.size ?? fallbackSize, in: geometry.size)
                ZStack {
                    Color.black.opacity(0.32)
                    if let image = preview.image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    cropOverlay(in: rect)
                        .opacity(preview.isReady(for: angle) ? 1 : 0.45)
                        .allowsHitTesting(preview.isReady(for: angle))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .coordinateSpace(name: "cropCanvas")
            }
            .frame(minWidth: 700, minHeight: 470)
            if let error = preview.error {
                Text("크롭 미리보기 오류: \(error)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 5) {
                HStack {
                    Text("수평").font(.caption)
                    Spacer()
                    Text(String(format: "%+.1f°", angle)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $angle, in: -20...20).accessibilityLabel("수평 보정 각도")
            }
            HStack {
                Picker("크롭 비율", selection: $ratio) {
                    ForEach(CropRatio.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("크롭 비율")
                Spacer()
                Button("초기화") { angle = 0; ratio = .free; crop = .full }
                    .accessibilityLabel("크롭과 수평 초기화")
                Button("취소") { dismiss() }
                Button("적용") {
                    model.applyCrop(source: source, crop: crop, straightenDegrees: angle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!preview.isReady(for: angle) || preview.error != nil)
            }
        }
        .padding(20).frame(minWidth: 760, minHeight: 660)
        .onAppear { preview.request(source: source, angle: angle) }
        .onDisappear { preview.cancel() }
        .onChange(of: angle) { _, newValue in
            interaction = nil
            preview.request(source: source, angle: newValue)
        }
        .onChange(of: ratio) { _, newValue in applyRatio(newValue) }
    }

    @ViewBuilder
    private func cropOverlay(in imageRect: CGRect) -> some View {
        let rect = CGRect(x: imageRect.minX + crop.x * imageRect.width,
                          y: imageRect.minY + crop.y * imageRect.height,
                          width: crop.width * imageRect.width,
                          height: crop.height * imageRect.height)
        ZStack {
            Path { path in
                path.addRect(imageRect)
                path.addRect(rect)
            }
            .fill(.black.opacity(0.58), style: FillStyle(eoFill: true))
            Path { path in
                path.addRect(rect)
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                }
            }
            .stroke(.white.opacity(0.85), lineWidth: 1)
            ForEach(CropCorner.allCases) { corner in
                Circle().fill(.white).frame(width: 12, height: 12).position(corner.point(in: rect))
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cropCanvas"))
                    .onChanged { value in updateCropDrag(value, imageRect: imageRect, cropRect: rect) }
                    .onEnded { _ in interaction = nil })
                .accessibilityLabel("크롭 영역 이동 및 크기 조절")
        }
    }

    private func updateCropDrag(_ value: DragGesture.Value, imageRect: CGRect, cropRect: CGRect) {
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        if interaction == nil {
            interactionStart = crop
            let startLocation = value.startLocation
            if let corner = CropCorner.allCases.first(where: {
                let point = $0.point(in: cropRect)
                return hypot(startLocation.x - point.x, startLocation.y - point.y) < 26
            }) {
                interaction = .corner(corner)
            } else if cropRect.contains(startLocation) {
                interaction = .move
            } else {
                return
            }
        }
        let dx = Double(value.translation.width / imageRect.width)
        let dy = Double(value.translation.height / imageRect.height)
        switch interaction {
        case .move:
            crop = NormalizedCrop(x: interactionStart.x + dx, y: interactionStart.y + dy,
                                  width: interactionStart.width, height: interactionStart.height).clamped
        case .corner(let corner):
            crop = resized(from: interactionStart, corner: corner, dx: dx, dy: dy)
        case nil:
            break
        }
    }

    private func resized(from start: NormalizedCrop, corner: CropCorner, dx: Double, dy: Double) -> NormalizedCrop {
        let oppositeX = corner.isLeft ? start.x + start.width : start.x
        let oppositeY = corner.isTop ? start.y + start.height : start.y
        var movingX = (corner.isLeft ? start.x : start.x + start.width) + dx
        var movingY = (corner.isTop ? start.y : start.y + start.height) + dy
        movingX = min(1, max(0, movingX)); movingY = min(1, max(0, movingY))
        if let target = ratio.value {
            let canvasAspect = max(0.0001, preview.canvasAspect)
            let normalizedAspect = target / canvasAspect
            var width = max(0.02, abs(movingX - oppositeX))
            var height = max(0.02, abs(movingY - oppositeY))
            if width / height > normalizedAspect { width = height * normalizedAspect }
            else { height = width / normalizedAspect }
            movingX = oppositeX + (corner.isLeft ? -width : width)
            movingY = oppositeY + (corner.isTop ? -height : height)
        }
        return NormalizedCrop(x: min(oppositeX, movingX), y: min(oppositeY, movingY),
                              width: abs(movingX - oppositeX), height: abs(movingY - oppositeY)).clamped
    }

    private func applyRatio(_ value: CropRatio) {
        guard let target = value.value else { return }
        let normalizedAspect = target / max(0.0001, preview.canvasAspect)
        let centerX = crop.x + crop.width / 2
        let centerY = crop.y + crop.height / 2
        var width = crop.width
        var height = width / normalizedAspect
        if height > crop.height { height = crop.height; width = height * normalizedAspect }
        crop = NormalizedCrop(x: centerX - width / 2, y: centerY - height / 2,
                              width: width, height: height).clamped
    }

    private var fallbackSize: CGSize {
        CGSize(width: CGFloat(max(1, source.metadata.width)),
               height: CGFloat(max(1, source.metadata.height)))
    }

    private func fittedRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        let scale = min(available.width / max(1, imageSize.width), available.height / max(1, imageSize.height))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

@MainActor
private final class CropPreviewModel: ObservableObject {
    @Published var image: NSImage?
    @Published var error: String?
    @Published var isRendering = false
    @Published private var renderedAngle: Double?
    @Published var canvasAspect = 1.0
    private let pipeline = ImagePipeline()
    private let queue = DispatchQueue(label: "com.rian.lighthouse.crop-preview", qos: .userInitiated)
    private var generation = 0
    private var workItem: DispatchWorkItem?

    func request(source: PhotoAsset, angle: Double) {
        workItem?.cancel()
        generation += 1
        let token = generation
        isRendering = true
        error = nil
        var edits = source.edits
        edits.straightenDegrees = angle
        edits.cropRect = nil
        edits.cropAspect = nil
        let geometry = PhotoGeometry(sourceWidth: Double(source.metadata.width),
                                     sourceHeight: Double(source.metadata.height), edits: edits)
        canvasAspect = Double(geometry.canvasSize.width / max(1, geometry.canvasSize.height))
        let job = DispatchWorkItem { [weak self, pipeline] in
            let result = Result { try pipeline.render(url: source.url, edits: edits, maxPixel: 2200) }
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.isRendering = false
                switch result {
                case .success(let image):
                    self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.renderedAngle = angle
                case .failure(let error):
                    self.image = nil
                    self.renderedAngle = nil
                    self.error = error.localizedDescription
                }
            }
        }
        workItem = job
        queue.asyncAfter(deadline: .now() + 0.15, execute: job)
    }

    func isReady(for angle: Double) -> Bool { !isRendering && renderedAngle == angle && image != nil }
    func cancel() { workItem?.cancel(); generation += 1; isRendering = false }
}

private enum CropRatio: String, CaseIterable, Identifiable {
    case free, square, portrait, classic, wide
    var id: String { rawValue }
    var title: String {
        switch self { case .free: "자유"; case .square: "1:1"; case .portrait: "4:5"; case .classic: "3:2"; case .wide: "16:9" }
    }
    var value: Double? {
        switch self { case .free: nil; case .square: 1; case .portrait: 4.0 / 5.0; case .classic: 3.0 / 2.0; case .wide: 16.0 / 9.0 }
    }
}

private enum CropCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
    }
}

private enum CropInteraction { case move, corner(CropCorner) }
