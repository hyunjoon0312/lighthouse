import AppKit
import SwiftUI
import LighthouseCore

struct RangeMaskSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let request: RangeMaskSheetRequest
    @State private var value: RangeSelection

    init(request: RangeMaskSheetRequest) {
        self.request = request
        _value = State(initialValue: request.initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(value.kind == .luminance ? "밝기 범위" : "색상 범위").font(.title2.weight(.semibold))
            if value.kind == .luminance {
                slider("어두운 경계", $value.lower)
                slider("밝은 경계", $value.upper)
            } else {
                ColorPicker("기준 색", selection: colorBinding, supportsOpacity: false)
                slider("색 허용 범위", $value.tolerance)
            }
            slider("경계 부드럽게", $value.softness)
            Text("원본을 분석해 마스크를 만듭니다. 기존 영역을 다시 설정하면 보정 효과와 브러시 흔적은 유지됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.workflowMessage { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("취소") { model.cancelWorkflow(); dismiss() }
                Button("적용") { model.applyRangeMask(request, selection: normalized) }
                    .buttonStyle(.borderedProminent).disabled(model.isRunningWorkflow || value.lower > value.upper)
            }
        }
        .padding(24).frame(width: 440)
        .interactiveDismissDisabled(model.isRunningWorkflow)
    }

    private var normalized: RangeSelection {
        RangeSelection(kind: value.kind, lower: min(value.lower, value.upper), upper: max(value.lower, value.upper),
                       softness: value.softness, red: value.red, green: value.green, blue: value.blue,
                       tolerance: value.tolerance)
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(red: value.red, green: value.green, blue: value.blue) }, set: { color in
            if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                value.red = Double(rgb.redComponent); value.green = Double(rgb.greenComponent); value.blue = Double(rgb.blueComponent)
            }
        })
    }

    private func slider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title).frame(width: 110, alignment: .leading); Slider(value: value, in: 0...1); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 42) }
    }
}

struct SimilarPhotosSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("중복·유사 사진 찾기").font(.title2.weight(.semibold)); Spacer(); Button("닫기") { dismiss() }.disabled(model.isRunningWorkflow) }
            Text(model.selectedPhotos.count >= 2 ? "선택한 사진을 분석합니다." : "현재 목록의 사진을 분석합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isRunningWorkflow {
                ProgressView(value: model.workflowProgress)
                HStack { Text("기기에서 사진을 비교하는 중…"); Spacer(); Button("취소") { model.cancelWorkflow() } }.font(.caption)
            } else if let result = model.similarPhotoResult {
                List(result.groups) { group in
                    HStack {
                        HStack(spacing: -8) {
                            ForEach(Array(group.photoIDs.prefix(3)), id: \.self) { id in
                                if let photo = model.photo(withID: id), let image = model.thumbnail(for: photo) {
                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped()
                                }
                            }
                        }
                        VStack(alignment: .leading) {
                            Text(group.kind == .exact ? "완전히 같은 파일" : "비슷한 사진").font(.headline)
                            Text(group.photoIDs.compactMap { model.photo(withID: $0)?.filename }.joined(separator: " · "))
                                .font(.caption).lineLimit(2)
                        }
                        Spacer(); Button("이 묶음 비교") { model.showSimilarGroup(group) }
                    }
                    .onAppear { group.photoIDs.compactMap(model.photo(withID:)).forEach(model.requestThumbnail(for:)) }
                }
                if result.isCancelled { Text("분석이 취소되었습니다.").font(.caption).foregroundStyle(.orange) }
                else if result.groups.isEmpty { Text("중복되거나 비슷한 사진 묶음을 찾지 못했습니다.").font(.caption).foregroundStyle(.secondary) }
                if !result.failures.isEmpty {
                    DisclosureGroup("읽지 못한 파일 \(result.failures.count)개") {
                        ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                            Text("\(URL(fileURLWithPath: failure.path).lastPathComponent): \(failure.message)").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Button("분석 시작") { model.findSimilarPhotos() }.buttonStyle(.borderedProminent)
            }
            if let message = model.workflowMessage { Text(message).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 700, height: 520)
            .interactiveDismissDisabled(model.isRunningWorkflow)
    }
}

struct SmartPreviewSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    private var targets: [PhotoAsset] { model.selectedPhotos.isEmpty ? Array(model.visiblePhotos.prefix(1)) : model.selectedPhotos }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("스마트 미리보기").font(.title2.weight(.semibold)); Spacer(); Button("닫기") { dismiss() }.disabled(model.isRunningWorkflow) }
            Text("선택한 \(targets.count)장의 사진에 원본이 연결되지 않았을 때 쓸 고해상도 미리보기를 로컬에 보관합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isRunningWorkflow { ProgressView(value: model.workflowProgress); Button("취소") { model.cancelWorkflow() } }
            ScrollView { VStack(alignment: .leading) { ForEach(targets) { photo in
                Label(photo.filename, systemImage: model.smartPreviewRecords[photo.id] == nil ? "circle" : "checkmark.circle.fill")
            } } }
            if !model.smartPreviewFailures.isEmpty {
                DisclosureGroup("실패 \(model.smartPreviewFailures.count)개") {
                    ForEach(model.smartPreviewFailures) { failure in
                        Text("\(failure.filename): \(failure.message)").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Button("삭제", role: .destructive) { model.deleteSmartPreviews(for: Set(targets.map(\.id))) }
                    .disabled(model.isRunningWorkflow)
                Spacer()
                Button("만들기") { model.createSmartPreviews(for: Set(targets.map(\.id))) }
                    .buttonStyle(.borderedProminent).disabled(model.isRunningWorkflow || targets.isEmpty)
            }
        }.padding(24).frame(width: 520, height: 420)
            .interactiveDismissDisabled(model.isRunningWorkflow)
            .onAppear { model.refreshSmartPreviewRecords() }
    }
}

struct LibraryArchiveSheet: View {
    enum Mode { case backup, restore }
    @EnvironmentObject private var model: LibraryModel
    @EnvironmentObject private var session: LibrarySession
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var includesOriginals = true
    @State private var archiveURL: URL?
    @State private var destinationURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode == .backup ? "라이브러리 백업" : "라이브러리 복원").font(.title2.weight(.semibold))
            if mode == .backup { backupBody } else { restoreBody }
            if model.isRunningWorkflow { ProgressView(value: model.workflowProgress); Button("취소") { model.cancelWorkflow() } }
            if let message = model.workflowMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("닫기") { dismiss() }.disabled(model.isRunningWorkflow) }
        }.padding(24).frame(width: 560)
            .interactiveDismissDisabled(model.isRunningWorkflow)
    }

    @ViewBuilder private var backupBody: some View {
        Toggle("원본 사진 포함", isOn: $includesOriginals)
        Text("원본을 포함하면 보관본 용량이 커집니다. Google Drive 인증 정보는 포함하지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
        Button("저장 위치 선택…") { chooseBackupDestination() }.disabled(model.isRunningWorkflow)
    }

    @ViewBuilder private var restoreBody: some View {
        Button(".lighthousebackup 선택…") { chooseArchive() }.disabled(model.isRunningWorkflow)
        if let archiveURL { Text(archiveURL.path).font(.caption).lineLimit(2) }
        if let summary = model.archiveSummary {
            Text("\(summary.createdAt.formatted()) · 사진 \(summary.photoCount)장 · 원본 \(summary.includesOriginals ? "포함" : "제외")")
            Button("새 복원 위치 선택 후 복원…") { chooseRestoreDestination() }.disabled(model.isRunningWorkflow)
        }
        if let restored = model.restoredLibraryDirectory {
            Button("복원한 라이브러리 열기") { Task { if await session.openLibrary(at: restored) { dismiss() } } }
        }
    }

    private func chooseBackupDestination() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Lighthouse-\(Date.now.formatted(.iso8601.year().month().day())).lighthousebackup"
        panel.canCreateDirectories = true
        panel.begin { response in if response == .OK, let url = panel.url { model.startLibraryBackup(to: url, includeOriginals: includesOriginals) } }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, let url = panel.url { archiveURL = url; model.inspectLibraryArchive(at: url) } }
    }

    private func chooseRestoreDestination() {
        guard let archiveURL else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "새 라이브러리 위치 선택"
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            let target = parent.appendingPathComponent("Lighthouse 복원 \(UUID().uuidString.prefix(6))", isDirectory: true)
            destinationURL = target; model.startLibraryRestore(from: archiveURL, to: target)
        }
    }
}
