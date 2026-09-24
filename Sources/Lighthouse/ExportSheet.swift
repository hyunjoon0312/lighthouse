import AppKit
import SwiftUI
import LighthouseCore

struct ExportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @StateObject private var previewModel = JPEGPreviewModel()
    @State private var scope: ExportScope = .current
    @State private var size = "original"
    @State private var quality = 0.85
    @State private var directory: URL?
    @State private var actualSize = false
    @AppStorage("exportIncludesLocation") private var includeLocation = false

    private var maxPixel: Int? { Int(size) }
    private var targets: [PhotoAsset] { model.exportTargets(for: scope) }
    private var representative: PhotoAsset? { targets.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "square.and.arrow.up").font(.title2).foregroundStyle(.orange)
                Text("JPEG 내보내기").font(.title2.weight(.semibold))
                Spacer()
                if previewModel.isPreparing { ProgressView().controlSize(.small) }
            }
            Picker("대상", selection: $scope) {
                Text("현재 사진").tag(ExportScope.current)
                Text("선택한 사진 (\(model.selectedPhotos.count)장)").tag(ExportScope.selected)
                Text("현재 필터 결과 (\(model.visiblePhotos.count)장)").tag(ExportScope.visible)
            }
            .disabled(model.isExporting).accessibilityLabel("JPEG 내보내기 대상")
            HStack {
                Picker("긴 변", selection: $size) {
                    Text("원본 크기").tag("original")
                    Text("3840 px").tag("3840")
                    Text("2048 px").tag("2048")
                }
                .disabled(model.isExporting).accessibilityLabel("JPEG 긴 변")
                Spacer()
                Toggle(actualSize ? "100%" : "화면 맞춤", isOn: $actualSize)
                    .toggleStyle(.button).accessibilityLabel("JPEG 미리보기 100퍼센트")
            }
            HStack {
                Text("JPEG 품질")
                Slider(value: $quality, in: 0.4...1).accessibilityLabel("JPEG 품질")
                Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 44)
            }
            .disabled(model.isExporting)
            Toggle("위치(GPS) 정보 포함", isOn: $includeLocation)
                .disabled(model.isExporting)
                .help("촬영일·카메라·렌즈 정보는 항상 원본에서 옮깁니다. 위치는 켠 경우에만 포함합니다.")
                .accessibilityLabel("내보낸 JPEG에 위치 정보 포함")
            previewPane
                .frame(minWidth: 620, minHeight: 360)
            if targets.count > 1 {
                Text("미리보기와 파일 크기는 대표 사진 1장의 결과입니다. 같은 품질과 크기 옵션으로 \(targets.count)장을 내보냅니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(directory?.path ?? "저장 폴더를 선택하세요").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("폴더 선택…") { chooseDirectory() }
                    .disabled(model.isExporting).accessibilityLabel("JPEG 저장 폴더 선택")
            }
            if model.isExporting { ProgressView(value: model.operationProgress) }
            if let report = model.exportReport { Text(report).font(.caption).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(model.exportReport == nil ? "취소" : "닫기") { dismiss() }
                    .disabled(model.isExporting)
                Button("내보내기") {
                    guard let directory, let prepared = previewModel.preview else { return }
                    model.export(scope: scope, maxPixel: maxPixel, quality: quality,
                                 includeLocation: includeLocation, directory: directory, prepared: prepared)
                }
                .buttonStyle(.borderedProminent)
                .disabled(directory == nil || model.isExporting || targets.isEmpty ||
                          previewModel.isPreparing || previewModel.error != nil || previewModel.preview == nil)
            }
        }
        .padding(24).frame(minWidth: 680, minHeight: 650)
        .onAppear {
            model.exportReport = nil
            scope = model.selectedPhotos.count >= 2 ? .selected : .current
            requestPreview(debounce: false)
        }
        .onDisappear { previewModel.cancel() }
        .onChange(of: scope) { _, _ in requestPreview() }
        .onChange(of: size) { _, _ in requestPreview() }
        .onChange(of: quality) { _, _ in requestPreview() }
        .onChange(of: includeLocation) { _, _ in requestPreview(debounce: false) }
    }

    @ViewBuilder private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.34))
            if let prepared = previewModel.preview {
                let image = NSImage(cgImage: prepared.result.image,
                                    size: NSSize(width: prepared.result.width, height: prepared.result.height))
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: CGFloat(prepared.result.width) / displayScale,
                                   height: CGFloat(prepared.result.height) / displayScale)
                    }
                } else {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(12)
                }
                VStack {
                    Spacer()
                    HStack {
                        Text("\(prepared.result.width) × \(prepared.result.height) · \(formattedBytes(prepared.result.data.count))")
                            .font(.caption.monospacedDigit()).padding(6)
                            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 5))
                        Spacer()
                    }.padding(10)
                }
            } else if let error = previewModel.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("JPEG 미리보기를 만들 수 없습니다")
                    Text(error).font(.caption).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary).padding()
            } else if previewModel.isPreparing {
                ProgressView("실제 JPEG 압축 확인 중…")
            } else {
                Text("미리볼 사진이 없습니다.").foregroundStyle(.secondary)
            }
        }
    }

    private func requestPreview(debounce: Bool = true) {
        previewModel.request(photo: representative, maxPixel: maxPixel, quality: quality,
                             includeLocation: includeLocation, debounce: debounce)
    }

    private func formattedBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        if panel.runModal() == .OK { directory = panel.url }
    }
}
