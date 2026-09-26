import AppKit
import SwiftUI
import LighthouseCore

private enum Palette {
    static let background = Color(red: 0.105, green: 0.112, blue: 0.122)
    static let panel = Color(red: 0.145, green: 0.152, blue: 0.164)
    static let canvas = Color(red: 0.085, green: 0.09, blue: 0.10)
    static let accent = Color(red: 1, green: 0.67, blue: 0.30)
    static let muted = Color.white.opacity(0.52)
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var keyMonitor: Any?
    @State private var pinchMonitor: Any?
    /// 사진 보기 칸들의 창 안 위치(왼쪽 위 기준). 키는 확대할 수 있는 현재 사진 칸인지다. 트랙패드 핀치를 받을 곳이다.
    @State private var paneFrames: [Bool: CGRect] = [:]
    /// 벌리거나 오므리기 시작한 곳과 지금까지 바뀐 배율의 합.
    @State private var pinch: (start: CGPoint, total: CGFloat)?
    @State private var folderToDelete: PhotoFolder?
    @State private var zoomPosition = ScrollPosition(edge: .top)
    @State private var pinnedZoomPosition = ScrollPosition(edge: .top)
    @State private var zoomSync = ZoomSync()
    /// 그리드 칸의 최소 너비. 썸네일 크기 슬라이더로 바꾸며 다음 실행에도 기억한다.
    @AppStorage("gridTileWidth") private var tileWidth = 180.0
    @State private var gridWidth: CGFloat = 0
    @State private var fullScreen = FocusFullScreen()
    @State private var fileDropTargeted = false
    @State private var showsCriteria = false
    @State private var smartRenameTarget: SmartFolder?
    @State private var smartRenameText = ""
    @State private var dropFolderID: UUID?

    var body: some View {
        Group {
            if model.isFocusView { focusView } else { workspace }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .onChange(of: model.isFocusView) { syncFullScreen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            fullScreen.willTransition()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            fullScreen.willTransition()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            fullScreen.didEnter()
            syncFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if fullScreen.didExit(focused: model.isFocusView) { model.isFocusView = false }
            syncFullScreen()
        }
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .sheet(isPresented: $model.showBatchEdit) { BatchEditSheet() }
        .sheet(isPresented: $model.showCardImport) { CardImportSheet() }
        .sheet(isPresented: $model.showShortcuts) { ShortcutHelpSheet() }
        .sheet(item: $model.presetSheet) { request in PresetSheet(request: request) }
        .sheet(item: $model.cropSource) { source in CropSheet(source: source) }
        .confirmationDialog(removalTitle, isPresented: Binding(
            get: { model.catalogRemoval != nil },
            set: { if !$0 { model.catalogRemoval = nil } }
        )) {
            Button(model.catalogRemoval?.isCopiesOnly == true ? "사본 삭제" : "카탈로그에서 빼기", role: .destructive) {
                if let removal = model.catalogRemoval { model.removeFromCatalog(Set(removal.photos.map(\.id))) }
                model.catalogRemoval = nil
            }
            Button("취소", role: .cancel) { model.catalogRemoval = nil }
        } message: {
            Text(removalMessage)
        }
        .sheet(item: $model.referenceMatchSource) { source in
            ReferenceMatchSheet(source: source) { adjustment, apply in
                model.finishReferenceMatch(adjustment, apply: apply, source: source)
            }
        }
        .sheet(item: $model.folderSheetRequest) { request in PhotoFolderSheet(request: request) }
        .alert("스마트 폴더 이름", isPresented: Binding(
            get: { smartRenameTarget != nil },
            set: { if !$0 { smartRenameTarget = nil } }
        )) {
            TextField("이름", text: $smartRenameText)
            Button("변경") {
                if let target = smartRenameTarget, let error = model.renameSmartFolder(target.id, to: smartRenameText) {
                    model.operationMessage = error
                }
                smartRenameTarget = nil
            }
            Button("취소", role: .cancel) { smartRenameTarget = nil }
        }
        .alert("폴더 삭제", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        )) {
            Button("폴더 삭제", role: .destructive) {
                if let id = folderToDelete?.id { model.deleteFolder(id) }
                folderToDelete = nil
            }
            Button("취소", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("폴더만 삭제하며 사진과 보정은 보관됩니다.")
        }
        .onAppear {
            installKeys()
            installPinch()
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            if let pinchMonitor { NSEvent.removeMonitor(pinchMonitor); self.pinchMonitor = nil }
        }
        .onChange(of: model.filter) { _, _ in model.ensureSelectionVisible() }
        .onChange(of: model.search) { _, _ in model.ensureSelectionVisible() }
        .onChange(of: model.minimumRating) { _, _ in model.ensureSelectionVisible() }
        // 회색 찍기 칸이 사라져도 SwiftUI가 십자 커서를 되돌리지 않아, 찍기가 끝나면 보통 커서로 돌린다.
        .onChange(of: model.isPickingWhiteBalance) { _, picking in if !picking { NSCursor.arrow.set() } }
        .onChange(of: model.criteria) { _, _ in model.ensureSelectionVisible() }
        .onChange(of: model.hasModalPresentation) { _, presented in
            if presented { model.cancelDraft(); model.cancelRetouchDraft() }
        }
    }

    /// 사진만 보기. 이동·별점·표시 키는 그대로 쓴다.
    private var focusView: some View {
        canvasPanes
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    Text(model.selection?.displayName ?? "").lineLimit(1)
                    if let summary = model.selection?.metadata.shootingSummary, !summary.isEmpty {
                        Text(summary).foregroundStyle(Palette.muted)
                    }
                    if let rating = model.selection?.rating, rating > 0 {
                        Text(String(repeating: "★", count: rating)).foregroundStyle(Palette.accent)
                    }
                    Text("F 또는 Esc로 나가기").foregroundStyle(Palette.muted)
                }
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.bottom, 14)
            }
    }

    private func syncFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if fullScreen.sync(focused: model.isFocusView, isFullScreen: window.styleMask.contains(.fullScreen)) {
            window.toggleFullScreen(nil)
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                if !model.photos.isEmpty {
                    selectionToolbar
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
                if model.filter == .bursts {
                    BurstBar()
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
                mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
                // 그리드는 같은 사진을 이미 모두 보여 주므로 필름 스트립을 두지 않는다.
                if model.mode != .grid && !model.visiblePhotos.isEmpty { filmstrip }
            }
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            inspector.frame(width: 300)
        }
        .dropDestination(for: URL.self) { urls, _ in model.importDropped(urls) } isTargeted: { fileDropTargeted = $0 }
        .overlay {
            if fileDropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Palette.accent, lineWidth: 3).padding(6)
                    .overlay(Text("놓으면 가져옵니다 · 원본은 그 자리에 둡니다").font(.headline).padding(12)
                        .background(.black.opacity(0.7), in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "camera.aperture").font(.title2).foregroundStyle(Palette.accent)
                Text("LIGHTHOUSE").font(.system(size: 14, weight: .bold, design: .rounded)).tracking(2)
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 30)
            sectionLabel("라이브러리")
            sidebarRow("전체 사진", icon: "square.grid.2x2", count: model.counts.total, selected: model.filter == .all) { model.filter = .all }
            sidebarRow("선택됨", icon: "flag", count: model.counts.picks, selected: model.filter == .picks) { model.filter = .picks }
            sidebarRow("제외됨", icon: "xmark.circle", count: model.counts.rejects, selected: model.filter == .rejects) { model.filter = .rejects }
            sidebarRow("보정됨", icon: "slider.horizontal.3", count: model.counts.edited, selected: model.filter == .edited) { model.filter = .edited }
            sidebarRow("연속 촬영", icon: "square.stack.3d.down.right", count: model.counts.bursts, selected: model.filter == .bursts) { model.filter = .bursts }
            if model.counts.missing > 0 || model.filter == .missing {
                sidebarRow("원본 없음", icon: "exclamationmark.triangle", count: model.counts.missing, selected: model.filter == .missing) { model.filter = .missing }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionLabel("스마트 폴더").padding(.top, 24)
                    if let error = model.smartFolderLoadError {
                        Text("스마트 폴더 오류: \(error)").font(.caption2).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
                    } else if model.smartFolders.isEmpty {
                        Text("위쪽 조건 단추에서 조건을 정해 저장하면 생깁니다").font(.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20)
                    }
                    ForEach(model.smartFolders) { folder in
                        HStack(spacing: 0) {
                            sidebarRow(folder.name, icon: "folder.badge.gearshape",
                                       count: model.counts.smart[folder.id] ?? 0,
                                       selected: model.filter == .smart(folder.id)) {
                                model.filter = .smart(folder.id)
                            }
                            .help(folder.criteria.summary().joined(separator: " · "))
                            Menu {
                                Button("이름 변경…") { smartRenameText = folder.name; smartRenameTarget = folder }
                                Button("삭제", role: .destructive) { model.deleteSmartFolder(folder.id) }
                            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel("\(folder.name) 관리")
                                .padding(.trailing, 8)
                        }
                    }
                    HStack {
                        sectionLabel("내 폴더")
                        Spacer()
                        Button { model.presentCreateFolder() } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("새 폴더 만들기")
                            .disabled(!model.foldersLoaded)
                            .padding(.trailing, 18)
                    }.padding(.top, 20)
                    if let error = model.folderLoadError {
                        Text("폴더 오류: \(error)").font(.caption2).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
                    } else if model.photoFolders.isEmpty {
                        Text("내 폴더가 없습니다").font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 20)
                    }
                    ForEach(model.photoFolders) { folder in
                        HStack(spacing: 0) {
                            sidebarRow(folder.name, icon: "folder.fill",
                                       count: model.counts.folders[folder.id] ?? 0,
                                       selected: model.filter == .collection(folder.id) || dropFolderID == folder.id) {
                                model.filter = .collection(folder.id)
                            }
                            .dropDestination(for: PhotoDragItem.self) { items, _ in
                                let ids = LibraryModel.draggedPhotoIDs(items)
                                return !ids.isEmpty && model.addPhotos(ids, to: folder.id)
                            } isTargeted: { dropFolderID = $0 ? folder.id : (dropFolderID == folder.id ? nil : dropFolderID) }
                            Menu {
                                Button("이름 변경…") { model.presentRenameFolder(folder) }
                                Button("폴더 삭제…", role: .destructive) { folderToDelete = folder }
                            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel("\(folder.name) 관리")
                                .disabled(!model.foldersLoaded)
                                .padding(.trailing, 8)
                        }
                    }
                    sectionLabel("원본 위치").padding(.top, 24)
                    ForEach(model.folders, id: \.self) { path in
                        sidebarRow(URL(fileURLWithPath: path).lastPathComponent, icon: "folder", count: nil, selected: model.filter == .folder(path)) { model.filter = .folder(path) }
                            .help(path)
                    }
                }
            }
            Spacer(minLength: 12)
            Button(action: model.presentImport) {
                Label("사진 가져오기", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("사진 가져오기")
            .disabled(!model.catalogLoaded || model.isImporting)
            .padding(.horizontal, 16).padding(.top, 16)
            Button { model.showCardImport = true } label: {
                Label("카드에서 복사…", systemImage: "sdcard").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("카드에서 복사해 가져오기")
            .disabled(!model.catalogLoaded || model.isImporting)
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
        }
        .background(Palette.panel)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.5)
            .foregroundStyle(Palette.muted).padding(.horizontal, 20).padding(.bottom, 9)
    }

    private func sidebarRow(_ title: String, icon: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 17)
                Text(title).lineLimit(1)
                Spacer()
                if let count { Text("\(count)").font(.caption).foregroundStyle(Palette.muted) }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Palette.accent : Color.white.opacity(0.82))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? Palette.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padding(.horizontal, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.filterTitle).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Text(toolbarSubtitle).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
            .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            .help(model.filterTitle + " · " + toolbarSubtitle)
            // 창이 좁으면 별점·정렬을 아이콘 메뉴로 줄여 모든 단추가 보이게 한다.
            ViewThatFits(in: .horizontal) {
                toolbarControls(compact: false)
                toolbarControls(compact: true)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16).frame(height: 67).background(Palette.panel)
    }

    private func toolbarControls(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 5) {
                ForEach(WorkspaceMode.allCases, id: \.self) { mode in
                    Button { model.setMode(mode) } label: {
                        Image(systemName: mode.icon)
                            .frame(width: compact ? 30 : 34, height: 28)
                            .background(model.mode == mode ? Palette.accent.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).help(mode.rawValue)
                    .accessibilityLabel("\(mode.rawValue) 보기")
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
            }
            .padding(3).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            TextField("파일명·키워드 검색", text: $model.search)
                .textFieldStyle(.roundedBorder).frame(width: compact ? 120 : 165)
            if compact {
                Menu {
                    Picker("별점", selection: $model.minimumRating) { ratingChoices }.pickerStyle(.inline)
                } label: {
                    Image(systemName: model.minimumRating > 0 ? "star.fill" : "star")
                        .foregroundStyle(model.minimumRating > 0 ? Palette.accent : Color.white.opacity(0.82))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .tint(model.minimumRating > 0 ? Palette.accent : Color.white.opacity(0.82))
                .help(model.minimumRating > 0 ? "\(model.minimumRating)★ 이상만 보기" : "별점으로 거르기")
                .accessibilityLabel("별점으로 거르기")
            } else {
                Picker("별점", selection: $model.minimumRating) { ratingChoices }
                    .labelsHidden().frame(width: 112)
            }
            Button { showsCriteria.toggle() } label: {
                Image(systemName: model.criteria.isEmpty ? "line.3.horizontal.decrease.circle"
                                                         : "line.3.horizontal.decrease.circle.fill")
                    .font(.title3)
                    .foregroundStyle(model.criteria.isEmpty ? Color.white.opacity(0.82) : Palette.accent)
            }
            .buttonStyle(.plain)
            .help("카메라·렌즈·초점거리·ISO·촬영일로 거르고 스마트 폴더로 저장")
            .accessibilityLabel(model.criteria.isEmpty ? "조건으로 거르기" : "조건으로 거르기, 조건 걸림")
            .popover(isPresented: $showsCriteria, arrowEdge: .bottom) { CriteriaPopover().environmentObject(model) }
            if compact {
                Menu {
                    Picker("정렬", selection: $model.sortOrder) { sortChoices }.pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .tint(Color.white.opacity(0.82))
                    .help("정렬: \(model.sortOrder.title)")
                    .accessibilityLabel("정렬")
            } else {
                Picker("정렬", selection: $model.sortOrder) { sortChoices }
                    .labelsHidden().frame(width: 118)
                    .help("보이는 목록의 순서. 같은 값끼리는 촬영 시각 순입니다.")
            }
            Button { model.showExport = true } label: {
                if compact { Image(systemName: "square.and.arrow.up") } else { Label("내보내기", systemImage: "square.and.arrow.up") }
            }
            .help("내보내기 (⇧⌘E)")
            .accessibilityLabel("내보내기")
            .disabled(model.selection == nil || model.isExporting || !model.catalogLoaded)
        }
        .fixedSize()
    }

    @ViewBuilder private var ratingChoices: some View {
        Text("모든 별점").tag(0)
        ForEach(1...5, id: \.self) { Text("\($0)★ 이상").tag($0) }
    }

    @ViewBuilder private var sortChoices: some View {
        ForEach(PhotoSortOrder.allCases) { Text($0.title).tag($0) }
    }

    /// 보이는 장수와, 걸린 조건(스마트 폴더·조건 창)의 요약.
    private var toolbarSubtitle: String {
        var parts = ["\(model.visiblePhotos.count)장 표시"]
        if let smart = model.smartFolderCriteria { parts += smart.summary() }
        parts += model.criteria.summary()
        return parts.joined(separator: " · ")
    }

    private var removalTitle: String {
        guard let removal = model.catalogRemoval else { return "" }
        let photos = removal.photos
        if removal.isCopiesOnly {
            return photos.count == 1 ? "\(photos[0].displayName)을 삭제할까요?" : "가상 사본 \(photos.count)개를 삭제할까요?"
        }
        return photos.count == 1 ? "\(photos[0].displayName)을 카탈로그에서 뺄까요?" : "사진 \(photos.count)장을 카탈로그에서 뺄까요?"
    }

    private var removalMessage: String {
        guard let removal = model.catalogRemoval else { return "" }
        if removal.isCopiesOnly { return "사본의 보정·별점만 지웁니다. 원본 파일과 원래 항목은 그대로이며 ⌘Z로 되돌릴 수 있습니다." }
        let companions = removal.hiddenCompanions > 0 ? " 한 장으로 묶여 있던 JPEG \(removal.hiddenCompanions)장도 함께 뺍니다." : ""
        return "원본 파일은 지우거나 옮기지 않고, 보정·별점·폴더 정보만 카탈로그에서 지웁니다. ⌘Z로 되돌릴 수 있습니다(앱을 다시 열면 되돌릴 수 없고, 다시 가져오면 보정 없이 새로 들어옵니다)." + companions
    }

    /// 선택한 사진에 쓰는 단추. 창이 좁으면 보기 설정을 "보기" 메뉴로 접고, 더 좁으면 기준 사진 이름을 뺀다.
    private var selectionToolbar: some View {
        ViewThatFits(in: .horizontal) {
            selectionControls(collapsesOptions: false, showsActiveName: true)
            selectionControls(collapsesOptions: true, showsActiveName: true)
            selectionControls(collapsesOptions: true, showsActiveName: false)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 36).background(Palette.panel)
    }

    private func selectionControls(collapsesOptions: Bool, showsActiveName: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(model.selectedPhotoIDs.count)장 선택")
                .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
            if showsActiveName, let name = model.selection?.displayName {
                Text("기준: \(name)").font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Button("전체 선택") { model.selectAllVisible() }
                .accessibilityLabel("보이는 사진 전체 선택")
                .disabled(model.visiblePhotos.isEmpty)
            if model.mode == .grid {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3").font(.caption2).foregroundStyle(Palette.muted)
                    Slider(value: $tileWidth, in: 130...260).frame(width: collapsesOptions ? 70 : 90)
                    Image(systemName: "square.grid.2x2").font(.caption).foregroundStyle(Palette.muted)
                }
                .help("썸네일 크기")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("썸네일 크기")
            }
            if collapsesOptions {
                Menu("보기") {
                    Toggle("RAW+JPEG 한 장으로", isOn: $model.collapsesRAWJPEGPairs)
                    Toggle("표시 후 다음 사진", isOn: $model.autoAdvance)
                }
                .fixedSize()
                .help("RAW+JPEG 한 장으로 · 표시 후 다음 사진")
                .accessibilityLabel("보기 설정")
            } else {
                Toggle("RAW+JPEG 한 장으로", isOn: $model.collapsesRAWJPEGPairs)
                    .toggleStyle(.checkbox)
                    .help("RAW와 함께 찍힌 JPEG를 숨기고 RAW만 보여 줍니다. JPEG는 카탈로그에 남아 있으며 끄면 다시 보입니다.")
                    .accessibilityLabel("RAW와 JPEG를 한 장으로 보기")
                Toggle("표시 후 다음 사진", isOn: $model.autoAdvance)
                    .toggleStyle(.checkbox)
                    .help("P·X·U·0–5 키로 표시하면 다음 사진으로 넘어갑니다")
                    .accessibilityLabel("표시 후 자동으로 다음 사진")
            }
            Button("선택 해제") { model.clearPhotoSelection() }
                .accessibilityLabel("사진 선택 해제")
                .disabled(model.selectedPhotoIDs.isEmpty)
            Button("일괄 적용…") { model.showBatchEdit = true }
                .accessibilityLabel("선택한 사진에 보정 일괄 적용")
                .disabled(model.selectedPhotoIDs.count < 2 || model.selection == nil)
            Menu("폴더에 추가") {
                if model.photoFolders.isEmpty { Text("내 폴더가 없습니다") }
                ForEach(model.photoFolders) { folder in
                    Button(folder.name) { model.addSelectedPhotos(to: folder.id) }
                }
                Divider()
                Button("새 폴더에 추가…") { model.presentCreateFolder() }
            }
            .fixedSize()
            .disabled(model.selectedPhotoIDs.isEmpty || !model.foldersLoaded)
            .accessibilityLabel("선택한 사진을 폴더에 추가")
            if case .collection = model.filter {
                Button("이 폴더에서 빼기") { model.removeSelectedPhotosFromCurrentFolder() }
                    .disabled(model.selectedPhotoIDs.isEmpty || !model.foldersLoaded)
                    .accessibilityLabel("선택한 사진을 현재 폴더에서 빼기")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var mainContent: some View {
        if let error = model.loadError {
            emptyState("카탈로그 오류", icon: "exclamationmark.triangle", detail: error)
        } else if !model.catalogLoaded {
            ProgressView("카탈로그 여는 중…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
        } else if model.photos.isEmpty {
            emptyState("사진을 가져오세요", icon: "photo.on.rectangle.angled", detail: "폴더나 파일을 선택해 시작하세요. JPEG, HEIC, TIFF와 RAW 파일을 지원합니다.")
        } else if model.visiblePhotos.isEmpty {
            emptyListState
        } else if model.mode == .grid {
            grid
        } else if model.mode == .survey {
            SurveyView()
        } else {
            editorCanvas
        }
    }

    /// 원본이 없는 사진은 저장해 둔 마지막 썸네일을 흐리게 보여 주고 위치를 다시 찾게 한다.
    private func missingOriginal(_ photo: PhotoAsset) -> some View {
        VStack(spacing: 14) {
            if let thumbnail = model.thumbnail(for: photo) {
                Image(nsImage: thumbnail).resizable().interpolation(.medium).scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 320).opacity(0.55)
            }
            Label("원본 파일을 찾을 수 없습니다", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(Palette.accent)
            Text("저장해 둔 작은 미리보기입니다. 드라이브를 연결하면 다시 확인하고, 파일을 옮겼다면 새 위치를 알려 주세요.")
                .font(.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("위치 다시 찾기…") { model.presentRelocate(for: photo) }.buttonStyle(.bordered)
        }
        .padding(20)
    }

    /// 목록에 사진이 없을 때의 안내. 검색어·조건이 걸려 있으면 그것을 바꾸라고 하고, 아니면 목록마다 채우는 방법을 알린다.
    private var emptyListState: some View {
        let narrowed = !model.search.trimmingCharacters(in: .whitespaces).isEmpty || model.minimumRating > 0 ||
            !model.criteria.isEmpty
        if narrowed {
            return emptyState("검색 결과가 없습니다", icon: "magnifyingglass", detail: "검색어나 별점·조건을 바꿔 보세요.")
        }
        let detail: String = switch model.filter {
        case .picks: "P 키나 오른쪽 패널의 선택 단추로 표시한 사진이 여기에 모입니다."
        case .rejects: "X 키로 제외한 사진이 여기에 모입니다."
        case .edited: "보정한 사진이 여기에 모입니다."
        case .bursts: "1초 안에 이어 찍은 사진이 없습니다."
        case .missing: "모든 원본을 찾았습니다."
        case .collection: "사진은 전체 라이브러리에서 선택해 이 폴더에 추가하세요."
        case .smart: "조건에 맞는 사진이 없습니다. 사이드바의 … 메뉴에서 이름을 바꾸거나 지울 수 있습니다."
        case .all, .folder: "이 목록에 사진이 없습니다."
        }
        return emptyState("‘\(model.filterTitle)’에 사진이 없습니다", icon: "photo.on.rectangle", detail: detail)
    }

    private func emptyState(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 50, weight: .ultraLight)).foregroundStyle(Palette.accent)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 440)
            if model.photos.isEmpty && model.loadError == nil {
                Button("파일 또는 폴더 선택") { model.presentImport() }.buttonStyle(.borderedProminent).accessibilityLabel("파일 또는 폴더 가져오기").padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
    }

    private var grid: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView { gridContent }
                    .onChange(of: model.selectedID) { _, id in scroll(proxy, to: id) }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                gridWidth = width
                model.gridColumnCount = gridColumns(for: width)
            }
            .onChange(of: tileWidth) { _, _ in model.gridColumnCount = gridColumns(for: gridWidth) }
        }
        .background(Palette.canvas)
    }

    private var gridContent: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth + 80), spacing: 14)], spacing: 14) {
            ForEach(model.visiblePhotos) { photo in
                PhotoTile(photo: photo,
                          selected: model.selectedPhotoIDs.contains(photo.id),
                          active: model.selectedID == photo.id,
                          imageHeight: (tileWidth * 0.83).rounded())
                    .id(photo.id)
            }
        }
        .padding(22)
    }

    private func gridColumns(for width: CGFloat) -> Int {
        max(1, Int((width - 44 + 14) / (tileWidth + 14)))
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: UUID?) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
    }

    private var editorCanvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("이전 사진").disabled(model.visiblePhotos.first?.id == model.selectedID)
                Button { model.move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("다음 사진").disabled(model.visiblePhotos.last?.id == model.selectedID)
                Text(model.selection?.displayName ?? "").lineLimit(1).font(.subheadline.weight(.medium))
                    .truncationMode(.middle)
                if let summary = model.selection?.metadata.shootingSummary, !summary.isEmpty {
                    Text(summary).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted).lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer()
                if model.mode == .compare, let pinned = model.pinned {
                    Text("기준: \(pinned.displayName)").font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                        .truncationMode(.middle).layoutPriority(-1)
                    Button(model.compareShowsPinnedEdits ? "기준 원본 보기" : "기준 보정 보기") {
                        model.compareShowsPinnedEdits.toggle()
                    }
                    .accessibilityLabel(model.compareShowsPinnedEdits ? "기준 사진을 보정 전 원본으로 보기" : "기준 사진을 보정한 모습으로 보기")
                    Button("이 사진을 기준으로") { model.makeCurrentPinned() }
                        .disabled(model.selectedID == pinned.id)
                        .help("지금 사진을 왼쪽 기준으로 옮기고 다음 사진과 비교합니다")
                        .accessibilityLabel("지금 사진을 비교 기준으로 삼기")
                }
                if model.mode == .edit {
                    Button(model.showsSplit ? "나눠 보기 끄기" : "전·후 나눠 보기") { model.toggleSplit() }
                        .help("왼쪽은 보정 전, 오른쪽은 보정 후 (Y). 선을 끌어 옮깁니다.")
                }
                Button(model.actualSize ? "화면 맞춤" : "100%") { model.toggleActualSize() }
                Button(model.isOriginal ? "보정 보기" : "원본 보기") { model.toggleOriginal() }
            }
            // 단추 글자는 줄바꿈하지 않고, 좁으면 파일 이름·기준 이름·촬영 정보가 먼저 줄어든다.
            .lineLimit(1)
            .buttonStyle(.borderless).padding(.horizontal, 20).frame(height: 44)
            canvasPanes
        }
    }

    private var canvasPanes: some View {
            HStack(spacing: 1) {
                if model.mode == .compare {
                    imagePane(model.pinnedImage, error: model.pinnedError,
                              caption: model.compareShowsPinnedEdits ? "기준 · 보정" : "기준 · 원본", overlay: nil,
                              zoomable: false, photo: model.pinned)
                }
                imagePane(model.rendered, error: model.imageError, caption: model.isOriginal ? "현재 · 원본" : "현재 · 보정",
                          overlay: model.showsClipping ? model.clippingOverlay : nil, zoomable: true, photo: model.selection)
            }
            .background(Palette.canvas)
    }

    private func imagePane(_ image: NSImage?, error: String?, caption: String, overlay: NSImage?,
                           zoomable: Bool, photo: PhotoAsset?) -> some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    if model.actualSize {
                        let scale = NSApp.keyWindow?.backingScaleFactor ?? 1
                        let content = CGSize(width: image.size.width / scale, height: image.size.height / scale)
                        // 비교 보기의 두 칸은 같은 곳(사진 안 비율 위치)을 보이고 함께 스크롤한다.
                        actualSizeScroll(image, overlay: overlay, content: content, viewport: geometry.size)
                            .scrollPosition(zoomable ? $zoomPosition : $pinnedZoomPosition)
                            .onAppear { scrollToZoomAnchor(zoomable, content: content, viewport: geometry.size) }
                            .onChange(of: content) { _, size in scrollToZoomAnchor(zoomable, content: size, viewport: geometry.size) }
                            .onChange(of: geometry.size) { _, size in scrollToZoomAnchor(zoomable, content: content, viewport: size) }
                            .onScrollGeometryChange(for: CGPoint.self) { scroll in
                                CGPoint(x: (scroll.contentOffset.x + scroll.containerSize.width / 2) / max(1, scroll.contentSize.width),
                                        y: (scroll.contentOffset.y + scroll.containerSize.height / 2) / max(1, scroll.contentSize.height))
                            } action: { _, anchor in followZoom(from: zoomable, anchor: anchor) }
                            .onScrollPhaseChange { _, phase in
                                // 스크롤을 멈춘 곳을 기억해 다음 사진도 같은 곳을 100%로 연다.
                                if phase == .idle, let anchor = zoomSync.anchors[zoomable], anchor != model.zoomAnchor {
                                    model.zoomAnchor = anchor
                                }
                            }
                    } else {
                        let splitting = zoomable && model.isSplitActive
                        Image(nsImage: image).resizable().interpolation(.high).allowedDynamicRange(.high)
                            .scaledToFit().padding(20)
                        if zoomable && !splitting {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { location in
                                    zoomIn(at: location, imageSize: image.size, available: geometry.size)
                                }
                                .accessibilityLabel("클릭한 위치를 100%로 확대")
                        }
                        if let overlay {
                            Image(nsImage: overlay).resizable().interpolation(.none).scaledToFit().padding(20)
                                .allowsHitTesting(false)
                        }
                        if splitting {
                            if let before = model.splitBefore {
                                SplitBeforeOverlay(before: before, imageSize: image.size, available: geometry.size,
                                                   position: $model.splitPosition)
                            } else {
                                ProgressView("보정 전 모습 그리는 중…").controlSize(.small)
                            }
                        } else if model.mode == .edit, let photo = model.selection {
                            BrushCanvasView(canvas: model.canvas, photo: photo, imageSize: image.size,
                                            availableSize: geometry.size)
                        }
                        if zoomable && model.isPickingWhiteBalance {
                            whiteBalancePicker(imageSize: image.size, available: geometry.size)
                        }
                    }
                } else if let photo, model.isMissing(photo) {
                    missingOriginal(photo)
                } else if let error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text("이미지를 열 수 없습니다").font(.headline)
                        Text(error).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 300)
                    }.foregroundStyle(Palette.muted)
                } else if model.rendering {
                    ProgressView("렌더링 중…")
                }
                if model.rendering && image != nil {
                    VStack { HStack { Spacer(); ProgressView().controlSize(.small).padding(12) }; Spacer() }
                }
                VStack { Spacer(); HStack { Text(caption).font(.caption).foregroundStyle(Palette.muted); Spacer() }.padding(14) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { paneFrames[zoomable] = $0 }
            .onDisappear { paneFrames[zoomable] = nil }
        }
    }

    private func actualSizeScroll(_ image: NSImage, overlay: NSImage?, content: CGSize,
                                  viewport: CGSize) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack {
                Image(nsImage: image).resizable().interpolation(.high).allowedDynamicRange(.high)
                if let overlay {
                    Image(nsImage: overlay).resizable().interpolation(.none).allowsHitTesting(false)
                }
            }
            .frame(width: content.width, height: content.height)
            .frame(minWidth: viewport.width, minHeight: viewport.height)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleActualSize() }
        }
    }

    /// 화면 맞춤 사진의 클릭 위치를 사진 안의 0…1 좌표로 바꿔 그 위치를 100%로 연다.
    private func zoomIn(at location: CGPoint, imageSize: NSSize, available: CGSize) {
        guard let anchor = imagePoint(at: location, imageSize: imageSize, available: available) else { return }
        model.toggleActualSize(at: anchor)
    }

    /// 화면 맞춤(여백 20)으로 그린 사진 안의 위치를 0…1 좌표(위쪽이 0)로 바꾼다. 사진 밖이면 nil.
    private func imagePoint(at location: CGPoint, imageSize: NSSize, available: CGSize) -> CGPoint? {
        let width = max(1, available.width - 40), height = max(1, available.height - 40)
        let scale = min(width / max(1, imageSize.width), height / max(1, imageSize.height))
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (available.width - fitted.width) / 2, y: (available.height - fitted.height) / 2)
        let point = CGPoint(x: (location.x - origin.x) / fitted.width, y: (location.y - origin.y) / fitted.height)
        return (0...1).contains(point.x) && (0...1).contains(point.y) ? point : nil
    }

    /// 흰색 기준 찍기 중에는 사진 위를 십자 커서로 누르게 한다.
    private func whiteBalancePicker(imageSize: NSSize, available: CGSize) -> some View {
        ZStack(alignment: .top) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    if let point = imagePoint(at: location, imageSize: imageSize, available: available) {
                        model.pickWhiteBalance(at: point)
                    }
                }
                .pointerStyle(.rectSelection)
                .accessibilityLabel("누른 곳을 흰색 기준으로")
            Label("회색·흰색이어야 할 곳을 누르세요 · Esc 취소", systemImage: "eyedropper")
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule()).padding(.top, 14)
                .allowsHitTesting(false)
        }
    }

    private func scrollToZoomAnchor(_ zoomable: Bool, content: CGSize, viewport: CGSize) {
        zoomSync.sizes[zoomable] = (content, viewport)
        zoomSync.anchors[zoomable] = nil
        scroll(zoomable, to: model.zoomAnchor)
    }

    /// 100% 칸을 사진 안 비율 위치 `anchor`가 가운데 오게 스크롤한다(끝에서는 멈춘다).
    private func scroll(_ zoomable: Bool, to anchor: CGPoint) {
        guard let (content, viewport) = zoomSync.sizes[zoomable] else { return }
        let point = CGPoint(
            x: max(0, min(content.width - viewport.width, anchor.x * content.width - viewport.width / 2)),
            y: max(0, min(content.height - viewport.height, anchor.y * content.height - viewport.height / 2))
        )
        if zoomable { zoomPosition.scrollTo(point: point) } else { pinnedZoomPosition.scrollTo(point: point) }
    }

    /// 비교 보기 100%에서 한 칸을 스크롤하면 다른 칸도 같은 곳을 보이게 따라 스크롤한다.
    /// 따라간 칸이 알려 오는 위치가 1pt 안이면 되돌려 보내지 않는다.
    private func followZoom(from zoomable: Bool, anchor: CGPoint) {
        zoomSync.anchors[zoomable] = anchor
        guard model.mode == .compare, let (content, _) = zoomSync.sizes[!zoomable] else { return }
        if let other = zoomSync.anchors[!zoomable],
           abs(other.x - anchor.x) * content.width < 1, abs(other.y - anchor.y) * content.height < 1 { return }
        scroll(!zoomable, to: anchor)
    }

    /// 가져오기·내보내기 진행과 안내. 필름 스트립이 없는 그리드에서도 보인다.
    @ViewBuilder private var statusBar: some View {
        if model.isImporting || model.isExporting || model.operationMessage != nil {
            VStack(spacing: 0) {
                if model.isImporting || model.isExporting {
                    HStack {
                        ProgressView(value: model.operationProgress).tint(Palette.accent)
                        if model.isImporting && model.canCancelImport {
                            Button(model.isCancellingImport ? "중지하는 중…" : "중지") { model.cancelImport() }
                                .disabled(model.isCancellingImport)
                                .controlSize(.small)
                                .accessibilityLabel("카드 복사 중지")
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 4)
                }
                if let message = model.operationMessage {
                    HStack { Text(message).lineLimit(2); Spacer(); Button { model.operationMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("안내 닫기") }
                        .font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Palette.panel)
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.visiblePhotos) { photo in
                        FilmstripTile(photo: photo,
                                      selected: model.selectedPhotoIDs.contains(photo.id),
                                      active: photo.id == model.selectedID)
                            .id(photo.id)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onChange(of: model.selectedID) { _, id in scroll(proxy, to: id) }
            .onAppear { scroll(proxy, to: model.selectedID) }
        }
        .frame(height: 106)
        .background(Palette.panel)
    }

    @ViewBuilder private var inspector: some View {
        if let photo = model.selection {
            InspectorView(photo: photo)
        } else {
            VStack { Text("사진을 선택하세요").foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.panel)
        }
    }

    /// 트랙패드로 사진의 한 곳을 벌리면(1.15배 넘게) 그곳을 100%로 열고, 100%에서 오므리면(0.87배 아래) 화면 맞춤으로
    /// 돌아간다. 손을 떼기 전에 기준을 넘는 순간 바꾼다. SwiftUI 확대 제스처 대신 앱에 오는 확대 이벤트를 받아, 합성한 이벤트로도 같은 경로를 확인할 수 있다.
    private func installPinch() {
        guard pinchMonitor == nil else { return }
        pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            handlePinch(event)
            return event
        }
    }

    private func handlePinch(_ event: NSEvent) {
        // 시트·팝오버 같은 딸린 창의 핀치는 받지 않는다.
        guard let window = event.window, window.canBecomeMain,
              model.showsSingleImage, !model.hasModalPresentation, !model.isPickingWhiteBalance else {
            pinch = nil
            return
        }
        // 사진 칸 위치(`.global`)와 같은 기준인 창 왼쪽 위 기준 좌표로 바꾼다.
        let point = CGPoint(x: event.locationInWindow.x, y: window.frame.height - event.locationInWindow.y)
        switch event.phase {
        case .began:
            pinch = (point, 0)
        case .changed:
            // 손을 떼기 전에 기준을 넘는 순간 바꾼다. 한 번 핀치에 한 번만 바꾼다.
            guard var current = pinch else { return }
            current.total += event.magnification
            pinch = current
            let start = current.start
            if model.actualSize {
                if current.total < -0.13, paneFrames.values.contains(where: { $0.contains(start) }) {
                    pinch = nil
                    model.toggleActualSize()
                }
            } else if current.total > 0.15, !model.isSplitActive, let frame = paneFrames[true], frame.contains(start),
                      let image = model.rendered {
                pinch = nil
                zoomIn(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY), imageSize: image.size,
                       available: frame.size)
            }
        default:
            pinch = nil
        }
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 글자 칸에서는 ⌘Z·⇧⌘Z가 사진 보정이 아니라 입력한 글자를 되돌리게 메뉴 단축키보다 먼저 보낸다.
            if NSApp.keyWindow?.firstResponder is NSTextView,
               event.modifierFlags.intersection([.command, .control, .option]) == .command,
               ShortcutKey.resolve(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode) == "z" {
                let action = event.modifierFlags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
                NSApp.sendAction(action, to: nil, from: nil)
                return nil
            }
            if NSApp.modalWindow != nil || model.hasModalPresentation { return event }
            if event.keyCode == 53, NSApp.keyWindow?.firstResponder is NSTextView {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if event.keyCode == 53, model.isPickingWhiteBalance { model.isPickingWhiteBalance = false; return nil }
            if event.keyCode == 53, model.isFocusView { model.isFocusView = false; return nil }
            // ?(⇧/)는 자판 배열과 입력 상태에 관계없이 같은 자리의 키로 읽는다.
            if event.keyCode == 44, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift {
                model.showShortcuts = true
                return nil
            }
            // 한글 입력 상태에서도 같은 키로 동작하도록 글자 대신 키 위치로 읽는다.
            let key = ShortcutKey.resolve(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode)
            if event.modifierFlags.contains(.command), key == "a" {
                model.selectAllVisible()
                return nil
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch key {
                case "0", "1", "2", "3", "4", "5":
                    model.markFromKeyboard(rating: Int(key!)!); return nil
                case "6", "7", "8", "9":
                    model.markFromKeyboard(toggleLabel: PhotoColorLabel.forKey(key!)); return nil
                case "p": model.markFromKeyboard(flag: .pick); return nil
                case "x": model.markFromKeyboard(flag: .reject); return nil
                case "u": model.markFromKeyboard(flag: PhotoFlag.none); return nil
                case "z" where model.showsSingleImage: model.toggleActualSize(); return nil
                case "g": model.setMode(.grid); return nil
                case "e": model.setMode(.edit); return nil
                case "c": model.setMode(.compare); return nil
                case "n": model.setMode(.survey); return nil
                case "\\": model.toggleOriginal(); return nil
                case "j": model.showsClipping.toggle(); return nil
                case "f": model.toggleFocusView(); return nil
                case "y": model.toggleSplit(); return nil
                case "w": model.beginWhiteBalancePick(); return nil
                case "r": model.presentCrop(); return nil
                default: break
                }
                // Delete: 내 폴더에서는 그 폴더에서만 빼고, 그 밖에서는 카탈로그에서 뺄지 묻는다.
                if event.keyCode == 51 || event.keyCode == 117 {
                    if case .collection = model.filter { model.removeSelectedPhotosFromCurrentFolder() } else { model.requestRemoveFromCatalog() }
                    return nil
                }
                if model.mode == .grid, event.modifierFlags.contains(.shift),
                   let offset = [123: -1, 124: 1, 125: model.gridColumnCount, 126: -model.gridColumnCount][event.keyCode] {
                    model.extendSelection(offset)
                    return nil
                }
                if model.mode == .survey, event.keyCode == 123 { model.moveInSurvey(-1); return nil }
                if model.mode == .survey, event.keyCode == 124 { model.moveInSurvey(1); return nil }
                if event.keyCode == 123 { model.move(-1); return nil }
                if event.keyCode == 124 { model.move(1); return nil }
                if model.mode == .grid, event.keyCode == 125 { model.move(model.gridColumnCount); return nil }
                if model.mode == .grid, event.keyCode == 126 { model.move(-model.gridColumnCount); return nil }
            }
            return event
        }
    }
}

@MainActor
private func tileClicked(_ model: LibraryModel, _ photo: PhotoAsset) {
    let event = NSApp.currentEvent
    model.handleTileClick(photo, clickCount: event?.clickCount ?? 1, modifiers: event?.modifierFlags ?? [])
}

private struct PhotoTile: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset
    let selected: Bool
    let active: Bool
    let imageHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06))
                    if let image = model.thumbnail(for: photo) {
                        // 제외한 사진은 흐리게 보여 고른 사진이 눈에 띄게 한다.
                        Image(nsImage: image).resizable().scaledToFit().padding(4)
                            .opacity(photo.flag == .reject ? 0.4 : 1)
                    } else {
                        Image(systemName: "photo").font(.title).foregroundStyle(Palette.muted)
                    }
                    VStack {
                        HStack {
                            if photo.isRAW { Text(model.hidesCompanion(of: photo) ? "RAW+JPEG" : "RAW").font(.system(size: 9, weight: .bold)).padding(5).background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4)) }
                            if let copyName = photo.copyName {
                                Label(copyName, systemImage: "square.on.square").font(.system(size: 9, weight: .bold)).padding(5)
                                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
                            }
                            Spacer()
                        }
                        Spacer()
                        if model.isMissing(photo) {
                            HStack {
                                Label("원본 없음", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.black).padding(5)
                                    .background(.orange, in: RoundedRectangle(cornerRadius: 4))
                                Spacer()
                            }
                        }
                        if let burst = model.burstBadge(for: photo) {
                            HStack(spacing: 4) {
                                Text("연속 \(burst.shot)/\(burst.count)")
                                    .font(.system(size: 9, weight: .bold)).padding(5)
                                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
                                if burst.isBest == true {
                                    Label("추천", systemImage: "star.fill")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.black).padding(5)
                                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 4))
                                }
                                if burst.eyesClosed {
                                    Label("눈 감음", systemImage: "eye.slash")
                                        .font(.system(size: 9, weight: .bold)).padding(5)
                                        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
                                }
                                Spacer()
                            }
                        }
                    }.padding(8)
                }
                .frame(height: imageHeight)
                HStack {
                    Text(photo.displayName).lineLimit(1).font(.system(size: 12, weight: .medium))
                    if active { Text("기준").font(.caption2.weight(.bold)).foregroundStyle(Palette.accent) }
                }
                HStack(spacing: 6) {
                    Text(photo.rating == 0 ? "별점 없음" : String(repeating: "★", count: photo.rating)).font(.caption).foregroundStyle(photo.rating == 0 ? Palette.muted : Palette.accent)
                    Spacer()
                    // 오른쪽 위는 다중 선택 단추 자리라, 선택·제외 표시는 별점 줄에 둔다.
                    if photo.flag != .none {
                        Label(photo.flag == .pick ? "선택" : "제외",
                              systemImage: photo.flag == .pick ? "flag.fill" : "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(photo.flag == .pick ? Palette.accent : .red)
                    }
                    if let label = photo.colorLabel {
                        Circle().fill(label.color).frame(width: 10, height: 10).help("\(label.title) 라벨")
                    }
                }
            }
            .padding(8)
            .background(selected ? Palette.accent.opacity(0.14) : Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Palette.accent : selected ? Palette.accent.opacity(0.48) : .clear, lineWidth: active ? 2 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { tileClicked(model, photo) }
            .contextMenu { PhotoContextMenu(photo: photo) }
            .draggable(model.dragPayload(for: photo)) { dragPreview }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.focusPhoto(photo) }
            .accessibilityAction(named: Text("선택 토글")) { model.togglePhotoSelection(photo) }
            .accessibilityAction(named: Text("기준 사진으로 보기")) { model.focusPhoto(photo); model.setMode(.edit) }
            Button { model.togglePhotoSelection(photo) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Palette.accent : .white)
                    .padding(6).background(.black.opacity(0.64), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(photo.filename) 다중 선택 토글")
            .padding(11)
        }
        .onAppear { model.requestThumbnail(for: photo) }
        .onChange(of: photo.edits) { _, _ in model.requestThumbnail(for: photo) }
    }

    /// 끄는 동안 보이는 썸네일. 선택한 여러 장을 끌면 장수를 붙인다.
    private var dragPreview: some View {
        let count = selected ? model.selectedPhotoIDs.count : 1
        return ZStack(alignment: .topTrailing) {
            if let image = model.thumbnail(for: photo) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 96, height: 72)
            } else {
                Image(systemName: "photo").font(.title).frame(width: 96, height: 72)
            }
            if count > 1 {
                Text("\(count)").font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.accent, in: Capsule()).foregroundStyle(.black)
            }
        }
    }

    private var accessibilityText: String {
        let state = active ? "기준 사진" : selected ? "선택됨" : "선택 안 됨"
        let label = photo.colorLabel.map { ", \($0.title) 라벨" } ?? ""
        let flag = photo.flag == .pick ? ", 선택 표시" : photo.flag == .reject ? ", 제외 표시" : ""
        return "\(photo.displayName), 별점 \(photo.rating), \(state)" + flag + label + burstAccessibility
    }

    private var burstAccessibility: String {
        guard let burst = model.burstBadge(for: photo) else { return "" }
        return ", 연속 촬영 \(burst.count)컷 중 \(burst.shot)번째" + (burst.isBest == true ? ", 추천 컷" : "") +
            (burst.eyesClosed ? ", 눈 감음" : "")
    }
}

private struct FilmstripTile: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset
    let selected: Bool
    let active: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                if let image = model.thumbnail(for: photo) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 92, height: 76).clipped()
                } else {
                    Rectangle().fill(.white.opacity(0.06)).overlay(Image(systemName: "photo").foregroundStyle(Palette.muted))
                }
                // 오른쪽 위는 다중 선택 단추, 왼쪽 아래는 "기준" 자리라 선택·제외 표시는 왼쪽 위에 둔다.
                if photo.flag != .none {
                    VStack {
                        HStack {
                            Image(systemName: photo.flag == .pick ? "flag.fill" : "xmark.circle.fill")
                                .font(.caption).foregroundStyle(photo.flag == .pick ? Palette.accent : .red)
                                .padding(4).background(.black.opacity(0.6), in: Circle())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(4)
                }
                if active { Text("기준").font(.system(size: 9, weight: .bold)).padding(3).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(4) }
                if let label = photo.colorLabel {
                    VStack { Spacer(); Rectangle().fill(label.color).frame(height: 4) }
                }
            }
            .frame(width: 92, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Palette.accent : selected ? Palette.accent.opacity(0.5) : .clear, lineWidth: active ? 2 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onTapGesture { tileClicked(model, photo) }
            .contextMenu { PhotoContextMenu(photo: photo) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(photo.displayName), \(active ? "기준 사진" : selected ? "선택됨" : "선택 안 됨")")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.focusPhoto(photo) }
            .accessibilityAction(named: Text("선택 토글")) { model.togglePhotoSelection(photo) }
            Button { model.togglePhotoSelection(photo) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Palette.accent : .white)
                    .padding(4).background(.black.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(photo.filename) 다중 선택 토글")
            .padding(3)
        }
        .help(photo.displayName)
        .onAppear { model.requestThumbnail(for: photo) }
        .onChange(of: photo.edits) { _, _ in model.requestThumbnail(for: photo) }
    }
}

/// 연속 촬영 목록 위의 분석·추천 도구. 분석은 Mac 안에서만 하고 원본을 바꾸지 않는다.
private struct BurstBar: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("연속 촬영 \(model.burstIndex.groups.count)묶음")
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                if model.isAnalyzingBursts {
                    ProgressView(value: model.burstAnalysisProgress).frame(width: 120)
                    Button("중지") { model.cancelBurstAnalysis() }
                        .accessibilityLabel("연속 촬영 분석 중지")
                } else {
                    Button("베스트 컷 분석") { model.analyzeBursts() }
                        .accessibilityLabel("연속 촬영 베스트 컷 분석")
                        .help("컷마다 초점 선명도, 얼굴 촬영 품질, 눈 감음을 Mac 안에서 비교합니다. 눈 감은 컷은 추천하지 않습니다")
                }
                Button("추천 컷 선택") { model.selectBurstRecommendations() }
                    .accessibilityLabel("추천 컷만 선택")
                    .disabled(model.isAnalyzingBursts || model.burstRecommendations.isEmpty)
                Button("추천 P · 나머지 X 표시") { model.markBurstRecommendations() }
                    .accessibilityLabel("추천 컷은 선택, 나머지는 제외로 표시")
                    .help("표시가 없는 사진에만 적용하고 한 번에 실행 취소됩니다")
                    .disabled(model.isAnalyzingBursts || model.burstRecommendations.isEmpty)
                Spacer()
            }
            if let message = model.burstMessage {
                Text(message).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Palette.panel)
    }
}

extension WorkspaceMode {
    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .edit: "photo"
        case .compare: "rectangle.split.2x1"
        case .survey: "square.grid.3x2"
        }
    }
}

/// 여러 장 보기: 선택한 사진을 화면을 나눠 크게 놓는다. 누르면 기준 사진이 되어 별점·표시 키가 그 사진에 붙고,
/// ×는 그 사진을 선택에서 빼 비교에서 뺀다. 두 번 누르면 사진 보기로 연다.
private struct SurveyView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        let photos = model.surveyPhotos
        GeometryReader { geometry in
            if photos.count < 2 {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.3x2").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Palette.accent)
                    Text("두 장 이상 선택하세요").font(.title3.weight(.semibold))
                    Text("⌘클릭·⇧클릭으로 고른 사진을 한 화면에 나란히 놓고 비교합니다. 칸의 ×를 누르면 그 사진을 비교에서 뺍니다.")
                        .font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let columns = photos.count <= 2 ? photos.count : photos.count <= 4 ? 2 : photos.count <= 9 ? 3 : 4
                let rows = (photos.count + columns - 1) / columns
                let spacing: CGFloat = 10
                let cellWidth = max(80, (geometry.size.width - 24 - spacing * CGFloat(columns - 1)) / CGFloat(columns))
                let cellHeight = max(80, (geometry.size.height - 24 - spacing * CGFloat(rows - 1)) / CGFloat(rows))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns),
                          spacing: spacing) {
                    ForEach(photos) { photo in
                        SurveyCell(photo: photo, active: photo.id == model.selectedID)
                            .frame(width: cellWidth, height: cellHeight)
                    }
                }
                .padding(12)
            }
        }
        .background(Palette.canvas)
        .overlay(alignment: .bottom) {
            if model.selectedPhotoIDs.count > LibraryModel.surveyLimit {
                Text("선택한 \(model.selectedPhotoIDs.count)장 중 앞의 \(LibraryModel.surveyLimit)장만 보입니다")
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule()).padding(.bottom, 8)
            }
        }
        .onAppear { model.requestSurveyImages() }
        .onChange(of: model.selectedPhotoIDs) { _, _ in model.requestSurveyImages() }
    }
}

private struct SurveyCell: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = model.surveyImages[photo.id] ?? model.thumbnail(for: photo) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button { model.togglePhotoSelection(photo) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(6)
                .help("비교에서 빼기")
                .accessibilityLabel("\(photo.displayName) 비교에서 빼기")
            }
            HStack(spacing: 6) {
                Text(photo.displayName).lineLimit(1)
                Spacer()
                if photo.flag != .none {
                    Image(systemName: photo.flag == .pick ? "flag.fill" : "xmark.circle.fill")
                        .foregroundStyle(photo.flag == .pick ? Palette.accent : .red)
                }
                if photo.rating > 0 { Text(String(repeating: "★", count: photo.rating)).foregroundStyle(Palette.accent) }
                if let label = photo.colorLabel { Circle().fill(label.color).frame(width: 9, height: 9) }
            }
            .font(.caption)
        }
        .padding(6)
        .background(active ? Palette.accent.opacity(0.14) : Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Palette.accent : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { model.focusPhoto(photo); model.setMode(.edit) }
        .onTapGesture { model.focusPhoto(photo) }
        .contextMenu { PhotoContextMenu(photo: photo) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(photo.displayName), 별점 \(photo.rating)\(active ? ", 기준 사진" : "")")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// 나눠 보기: 사진이 그려진 자리에 보정 전 모습을 겹쳐 나누는 선 왼쪽만 보인다. 사진 위 어디를 끌어도 선이 따라온다.
private struct SplitBeforeOverlay: View {
    let before: NSImage
    let imageSize: NSSize
    let available: CGSize
    @Binding var position: Double

    var body: some View {
        let width = max(1, available.width - 40), height = max(1, available.height - 40)
        let scale = min(width / max(1, imageSize.width), height / max(1, imageSize.height))
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (available.width - fitted.width) / 2, y: (available.height - fitted.height) / 2)
        let lineX = fitted.width * position
        ZStack(alignment: .topLeading) {
            Image(nsImage: before).resizable().interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .mask(alignment: .leading) { Rectangle().frame(width: lineX) }
            Rectangle().fill(.white).frame(width: 2, height: fitted.height).offset(x: lineX - 1)
            Image(systemName: "arrow.left.and.right.circle.fill").font(.title2).foregroundStyle(.white, .black.opacity(0.6))
                .offset(x: lineX - 12, y: fitted.height / 2 - 12)
            HStack {
                Text("보정 전"); Spacer(); Text("보정 후")
            }
            .font(.caption.weight(.semibold)).padding(6)
            .background(.black.opacity(0.001))
            .frame(width: fitted.width)
        }
        .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            position = min(1, max(0, value.location.x / max(1, fitted.width)))
        })
        .position(x: origin.x + fitted.width / 2, y: origin.y + fitted.height / 2)
        .accessibilityElement()
        .accessibilityLabel("보정 전후 나누는 선")
        .accessibilityValue("\(Int((position * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            position = min(1, max(0, position + (direction == .increment ? 0.05 : -0.05)))
        }
    }
}

/// 사진만 보기와 창의 전체 화면을 맞춘다. AppKit은 전환 애니메이션 중의 전환 요청을 무시하므로
/// 그동안의 요청은 미뤘다가 전환이 끝나면 마지막 상태에 맞춘다. F를 빠르게 여러 번 눌러도 어긋나지 않는다.
struct FocusFullScreen {
    /// 사진만 보기가 전체 화면으로 들어갔는지. 이미 전체 화면이던 창은 나갈 때 그대로 둔다.
    private(set) var entered = false
    private(set) var transitioning = false
    private var exitRequested = false

    /// 창의 전체 화면을 켜거나 꺼야 하면 true.
    mutating func sync(focused: Bool, isFullScreen: Bool) -> Bool {
        guard !transitioning else { return false }
        if focused, !isFullScreen {
            entered = true
            transitioning = true
            return true
        }
        if !focused, entered {
            entered = false
            guard isFullScreen else { return false }
            exitRequested = true
            transitioning = true
            return true
        }
        return false
    }

    mutating func willTransition() { transitioning = true }

    mutating func didEnter() { transitioning = false }

    /// 앱이 요청하지 않은 종료(초록 버튼·⌃⌘F)로 사진만 보기를 끝내야 하면 true.
    mutating func didExit(focused: Bool) -> Bool {
        defer { exitRequested = false }
        transitioning = false
        entered = false
        return focused && !exitRequested
    }
}

/// 100% 보기에서 두 칸(키: 확대할 수 있는 현재 사진 칸인지)의 내용·보이는 크기와 지금 가운데 있는 사진 안 비율 위치.
/// 스크롤마다 바뀌므로 화면을 다시 그리지 않도록 관찰하지 않는 객체에 둔다.
private final class ZoomSync {
    var sizes: [Bool: (content: CGSize, viewport: CGSize)] = [:]
    var anchors: [Bool: CGPoint] = [:]
}
