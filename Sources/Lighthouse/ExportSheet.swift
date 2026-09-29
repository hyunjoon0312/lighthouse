import AppKit
import SwiftUI
import LighthouseCore

private enum ExportDestination: String, CaseIterable, Identifiable {
    case mac, drive
    var id: Self { self }
    var title: String { self == .mac ? "Mac" : "Google Drive" }
}

struct ExportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @StateObject private var previewModel: JPEGPreviewModel
    @State private var scope: ExportScope = .current
    @State private var destination: ExportDestination = .mac
    @State private var driveContent: GoogleDriveUploadContent = .edited
    @State private var driveBusy = false
    @State private var options = ExportPresetLibrary.lastOptions
    @State private var userPresets = ExportPresetLibrary.userPresets
    @State private var directory: URL? = ExportPresetLibrary.lastDirectory
    @State private var actualSize = false
    @State private var savingPreset = false
    @State private var newPresetName = ""
    /// 마지막으로 내보낸 뒤 바뀐 사진. 창을 열 때와 다시 내보낸 뒤에 센다.
    @State private var changed: [PhotoAsset] = []
    @AppStorage("reexportTrashesPrevious") private var trashPrevious = false

    init(lutDirectory: URL = LUTStore.defaultDirectory) {
        _previewModel = StateObject(wrappedValue: JPEGPreviewModel(lutDirectory: lutDirectory))
    }

    private var targets: [PhotoAsset] { model.exportTargets(for: scope) }
    private var representative: PhotoAsset? { targets.first }
    /// 파일 이름 규칙은 파일 데이터에 영향이 없으므로 미리보기를 다시 만들 때 빼고 비교한다.
    private var renderOptions: ExportOptions {
        var copy = options
        copy.filenameTemplate = ""
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 18) {
                ScrollView { settings.padding(.trailing, 6) }
                    .frame(width: 320)
                previewColumn
            }
            footer
        }
        .padding(24).frame(minWidth: 940, minHeight: 680)
        .interactiveDismissDisabled(model.isExporting || driveBusy)
        .onAppear {
            model.exportReport = nil
            scope = model.selectedPhotos.count >= 2 ? .selected : .current
            changed = model.changedSinceExport
            requestPreview(debounce: false)
        }
        .onChange(of: model.isExporting) { _, exporting in if !exporting { changed = model.changedSinceExport } }
        .onReceive(model.driveUpload.$isBusy) { driveBusy = $0 }
        .onDisappear { previewModel.cancel() }
        .onChange(of: representative) { _, _ in requestPreview() }
        .onChange(of: destination) { _, _ in requestPreview() }
        .onChange(of: driveContent) { _, _ in requestPreview() }
        .onChange(of: renderOptions) { _, _ in requestPreview() }
        .onChange(of: options) { _, value in ExportPresetLibrary.lastOptions = value }
        .alert("내보내기 프리셋 저장", isPresented: $savingPreset) {
            TextField("프리셋 이름", text: $newPresetName)
            Button("저장") { savePreset() }
            Button("취소", role: .cancel) { }
        } message: {
            Text("형식·색 공간·긴 변·품질·위치 정보·파일 이름·워터마크 설정을 저장합니다.")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.up").font(.title2).foregroundStyle(.orange)
            Text("내보내기").font(.title2.weight(.semibold))
            Spacer()
            if showsEditedPreview && previewModel.isPreparing { ProgressView().controlSize(.small) }
            if showsEditedPreview { presetMenu }
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsEditedPreview {
                HStack {
                    if destination == .drive { Text("보정본 미리보기").font(.headline) }
                    Spacer()
                    Toggle(actualSize ? "100%" : "화면 맞춤", isOn: $actualSize)
                        .toggleStyle(.button).accessibilityLabel("내보내기 미리보기 100퍼센트")
                }
                previewPane.frame(minWidth: 560, minHeight: 420)
                if targets.count > 1 {
                    Text("미리보기와 파일 크기는 대표 사진 1장의 결과입니다. 같은 설정으로 \(targets.count)장을 내보냅니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                originalSummary.frame(minWidth: 560, minHeight: 420)
            }
        }
    }

    private var showsEditedPreview: Bool { destination == .mac || driveContent.includesEdited }

    private var originalSummary: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.arrow.up").font(.system(size: 42)).foregroundStyle(.secondary)
            Text("원본 파일을 그대로 업로드합니다").font(.headline)
            Text("\(targets.count)장 · 원본 바이트와 기존 메타데이터를 바꾸지 않습니다.\n원본에 위치 정보가 있으면 그대로 포함됩니다.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var footer: some View {
        if destination == .drive {
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.disabled(driveBusy)
            }
        } else {
            localFooter
        }
    }

    private var localFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(directory?.path ?? "저장 폴더를 선택하세요").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("폴더 선택…") { chooseDirectory() }
                    .disabled(model.isImporting || model.isExporting).accessibilityLabel("내보내기 저장 폴더 선택")
            }
            if model.isExporting {
                HStack {
                    ProgressView(value: model.operationProgress)
                    Button(model.isCancellingExport ? "중지하는 중…" : "중지") { model.cancelExport() }
                        .disabled(model.isCancellingExport)
                        .accessibilityLabel("내보내기 중지")
                }
            }
            if let report = model.exportReport {
                HStack(alignment: .top) {
                    Text(report).font(.caption).textSelection(.enabled)
                    Spacer()
                    if !model.lastExportedFiles.isEmpty {
                        Button("Finder에서 보기") { model.revealInFinder(model.lastExportedFiles) }
                            .accessibilityLabel("내보낸 파일을 Finder에서 보기")
                    }
                }
            }
            HStack {
                Spacer()
                Button(model.exportReport == nil ? "취소" : "닫기") { dismiss() }
                    .disabled(model.isExporting)
                Button("내보내기") {
                    guard let directory else { return }
                    model.export(scope: scope, options: options, directory: directory, prepared: previewModel.preview)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartLocalExport)
            }
        }
    }

    /// 보정이 바뀐 사진을 그때의 설정·폴더로 다시 내보낸다. 위 설정과 폴더는 쓰지 않는다.
    @ViewBuilder private var reexportBox: some View {
        if !changed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("보정이 바뀐 사진 \(changed.count)장").font(.subheadline.weight(.semibold))
                Text("마지막으로 내보낸 뒤 보정·키워드·설명이 바뀐 사진을 그때의 설정과 폴더, 같은 이름으로 다시 내보냅니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("이전 파일은 휴지통으로 (앱이 쓴 그대로일 때만)", isOn: $trashPrevious)
                    .font(.caption)
                    .help("끄면 이전 파일을 두고 이름 뒤에 번호를 붙입니다. 켜도 그 뒤 편집한 파일은 옮기지 않습니다.")
                Button("\(changed.count)장 다시 내보내기") { model.reexport(changed, trashPrevious: trashPrevious) }
                    .disabled(model.isImporting || model.isExporting)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("보낼 곳", selection: $destination) {
                ForEach(ExportDestination.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isExporting || driveBusy)
            if destination == .mac { reexportBox.disabled(model.isImporting || model.isExporting) }
            Picker("대상", selection: $scope) {
                Text("현재 사진").tag(ExportScope.current)
                Text("선택한 사진 (\(model.selectedPhotos.count)장)").tag(ExportScope.selected)
                Text("현재 필터 결과 (\(model.visiblePhotos.count)장)").tag(ExportScope.visible)
            }
            .accessibilityLabel("내보내기 대상")
            .disabled(model.isExporting || driveBusy)
            if destination == .drive {
                GoogleDriveExportPanel(upload: model.driveUpload, photos: targets,
                                       options: options, content: $driveContent)
                    .disabled(targets.contains(where: model.isMissing))
                if targets.contains(where: model.isMissing) {
                    Text("원본이 없는 사진은 내보내거나 Drive에 업로드할 수 없습니다. 스마트 미리보기는 최종 파일로 사용하지 않습니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if driveContent.includesEdited {
                    Divider()
                    Text(driveContent == .both ? "보정본 설정" : "편집본 설정").font(.headline)
                    exportSettings
                }
            } else {
                exportSettings
            }
        }
    }

    private var exportSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("형식", selection: $options.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("파일 형식")
            if targets.contains(where: { $0.isRAW && $0.edits.hdrAmount > 0 }) {
                Toggle("HDR 하이라이트를 쓴 사진은 HDR로 저장", isOn: $options.includesHDR)
                    .help("SDR 이미지에 게인 맵을 더해 HDR 화면에서는 밝은 부분이 더 밝게, 그 밖에서는 SDR로 보입니다")
                if options.includesHDR && !options.format.supportsHDR {
                    Text("TIFF는 SDR로만 저장합니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("색 공간", selection: $options.colorSpace) {
                ForEach(ExportColorSpace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityLabel("색 공간")
            if options.colorSpace == .displayP3 {
                Text("넓은 색을 남깁니다. 웹이나 P3를 모르는 프로그램에서는 색이 옅게 보일 수 있어 공유용은 sRGB가 안전합니다.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("긴 변", selection: $options.maxPixel) {
                Text("원본 크기").tag(Int?.none)
                ForEach([3840, 2048, 1080], id: \.self) { Text("\($0) px").tag(Optional($0)) }
            }
            .accessibilityLabel("긴 변")
            if options.format.usesQuality {
                HStack {
                    Text("품질")
                    Slider(value: $options.quality, in: 0.4...1).accessibilityLabel("압축 품질")
                    Text("\(Int(options.quality * 100))%").monospacedDigit().frame(width: 40)
                }
            } else {
                Text("TIFF는 압축하지 않은 16비트라 품질 설정이 없고 파일이 큽니다(2400만 화소 약 140MB).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("위치(GPS) 정보 포함", isOn: $options.includeLocation)
                .help("촬영일·카메라·렌즈 정보와 키워드·설명은 항상 넣습니다. 위치는 켠 경우에만 포함합니다.")
                .accessibilityLabel("내보낸 파일에 위치 정보 포함")
            Divider()
            filenameSettings
            Divider()
            watermarkSettings
        }
        .disabled(model.isExporting || driveBusy)
    }

    private var filenameSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("파일 이름").font(.caption.weight(.semibold))
            TextField("파일 이름 규칙", text: $options.filenameTemplate)
                .textFieldStyle(.roundedBorder).accessibilityLabel("파일 이름 규칙")
            HStack(spacing: 4) {
                ForEach(["{원본}", "{날짜}", "{시간}", "{번호}", "{사본}"], id: \.self) { token in
                    Button(token) { options.filenameTemplate += token }
                        .controlSize(.small).accessibilityLabel("\(token) 넣기")
                }
            }
            Text("예: \(exampleName).\(options.format.fileExtension)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("가상 사본은 {사본}이 없어도 이름 끝에 ‘-사본1’처럼 붙습니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var watermarkSettings: some View {
        Toggle("워터마크", isOn: Binding(
            get: { options.watermark != nil },
            set: { options.watermark = $0 ? Watermark(text: "© \(NSFullUserName())") : nil }
        ))
        if let watermark = options.watermark {
            TextField("워터마크 글자", text: Binding(
                get: { watermark.text },
                set: { options.watermark?.text = $0 }
            )).textFieldStyle(.roundedBorder).accessibilityLabel("워터마크 글자")
            Picker("위치", selection: Binding(
                get: { watermark.position },
                set: { options.watermark?.position = $0 }
            )) {
                Text("오른쪽 아래").tag(WatermarkPosition.bottomRight)
                Text("왼쪽 아래").tag(WatermarkPosition.bottomLeft)
                Text("오른쪽 위").tag(WatermarkPosition.topRight)
                Text("왼쪽 위").tag(WatermarkPosition.topLeft)
                Text("가운데").tag(WatermarkPosition.center)
            }
            HStack {
                Text("크기").font(.caption)
                Slider(value: Binding(get: { watermark.size }, set: { options.watermark?.size = $0 }),
                       in: 0.01...0.1).accessibilityLabel("워터마크 크기")
            }
            HStack {
                Text("불투명도").font(.caption)
                Slider(value: Binding(get: { watermark.opacity }, set: { options.watermark?.opacity = $0 }),
                       in: 0.2...1).accessibilityLabel("워터마크 불투명도")
            }
        }
    }

    private var presetMenu: some View {
        Menu("프리셋") {
            ForEach(ExportPresetLibrary.builtIn + userPresets) { preset in
                Button(preset.name) { options = preset.options }
            }
            Divider()
            Button("현재 설정 저장…") { newPresetName = ""; savingPreset = true }
            if !userPresets.isEmpty {
                Menu("삭제") {
                    ForEach(userPresets) { preset in
                        Button(preset.name, role: .destructive) { deletePreset(preset.id) }
                    }
                }
            }
        }
        .fixedSize()
        .disabled(model.isExporting || driveBusy)
        .accessibilityLabel("내보내기 프리셋")
    }

    private var exampleName: String {
        guard let photo = representative else { return options.filenameTemplate }
        return ExportOptions.baseName(template: options.filenameTemplate, sourceURL: photo.url,
                                      capturedAt: photo.metadata.capturedAt, sequence: 1, copyName: photo.copyName)
    }

    @ViewBuilder private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.34))
            if let prepared = previewModel.preview {
                preparedPreview(prepared)
            } else if let error = previewModel.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("미리보기를 만들 수 없습니다")
                    Text(error).font(.caption).multilineTextAlignment(.center)
                    if targets.count > 1 {
                        Text("대표 사진의 미리보기를 만들 수 없습니다. 내보내면 각 사진을 처리하고 실패한 항목을 결과에 표시합니다.")
                            .font(.caption).multilineTextAlignment(.center)
                    }
                    Button("미리보기 다시 시도") { requestPreview(debounce: false) }
                        .disabled(model.isExporting || driveBusy)
                        .accessibilityLabel("내보내기 미리보기 다시 시도")
                }.foregroundStyle(.secondary).padding()
            } else if previewModel.isPreparing {
                ProgressView("실제 파일로 저장해 확인 중…")
            } else {
                Text("미리볼 사진이 없습니다.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func preparedPreview(_ prepared: PreparedJPEGExport) -> some View {
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
                Text("\(prepared.options.format.title) · \(prepared.result.width) × \(prepared.result.height) · \(formattedBytes(prepared.result.data.count))")
                    .font(.caption.monospacedDigit()).padding(6)
                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 5))
                Spacer()
            }.padding(10)
        }
    }

    private func requestPreview(debounce: Bool = true) {
        previewModel.request(photo: representative, options: options, debounce: debounce)
    }

    private var canStartLocalExport: Bool {
        directory != nil && !model.isImporting && !model.isExporting && !targets.isEmpty &&
            !targets.contains(where: model.isMissing) &&
            !previewModel.isPreparing &&
            (previewModel.preview != nil || (targets.count > 1 && previewModel.error != nil))
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        userPresets.removeAll { $0.name == name }
        userPresets.append(ExportPreset(name: name, options: options))
        ExportPresetLibrary.userPresets = userPresets
    }

    private func deletePreset(_ id: UUID) {
        userPresets.removeAll { $0.id == id }
        ExportPresetLibrary.userPresets = userPresets
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
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
            ExportPresetLibrary.lastDirectory = url
        }
    }
}

/// 내보내기 설정은 앱 설정이므로 카탈로그가 아니라 사용자 기본 설정에 둔다.
enum ExportPresetLibrary {
    static let builtIn = [
        ExportPreset(id: UUID(uuidString: "6C1F7F0E-0000-4000-8000-000000000001")!, name: "블로그 (긴 변 2048px · 85%)",
                     options: ExportOptions(maxPixel: 2048, quality: 0.85)),
        ExportPreset(id: UUID(uuidString: "6C1F7F0E-0000-4000-8000-000000000002")!, name: "원본 크기 · 95%",
                     options: ExportOptions(maxPixel: nil, quality: 0.95))
    ]

    static var userPresets: [ExportPreset] {
        get { decode([ExportPreset].self, key: "exportPresets") ?? [] }
        set { encode(newValue, key: "exportPresets") }
    }

    /// 마지막으로 고른 저장 폴더. 폴더가 사라졌으면 nil이다.
    static var lastDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "lastExportDirectory") else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "lastExportDirectory") }
    }

    static var lastOptions: ExportOptions {
        get {
            if let saved = decode(ExportOptions.self, key: "lastExportOptions") { return saved }
            return ExportOptions(includeLocation: UserDefaults.standard.bool(forKey: "exportIncludesLocation"))
        }
        set { encode(newValue, key: "lastExportOptions") }
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
