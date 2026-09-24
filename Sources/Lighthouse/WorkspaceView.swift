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
    @State private var folderToDelete: PhotoFolder?
    @State private var zoomPosition = ScrollPosition(edge: .top)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                selectionToolbar
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                if model.filter == .bursts {
                    BurstBar()
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
                mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                filmstrip
            }
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            inspector.frame(width: 300)
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .sheet(isPresented: $model.showBatchEdit) { BatchEditSheet() }
        .sheet(isPresented: $model.showCardImport) { CardImportSheet() }
        .sheet(item: $model.presetSheet) { request in PresetSheet(request: request) }
        .sheet(item: $model.cropSource) { source in CropSheet(source: source) }
        .sheet(item: $model.referenceMatchSource) { source in
            ReferenceMatchSheet(source: source) { adjustment, apply in
                model.finishReferenceMatch(adjustment, apply: apply, source: source)
            }
        }
        .sheet(item: $model.folderSheetRequest) { request in PhotoFolderSheet(request: request) }
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
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil } }
        .onChange(of: model.filter) { _, _ in model.ensureSelectionVisible() }
        .onChange(of: model.search) { _, _ in model.ensureSelectionVisible() }
        .onChange(of: model.minimumRating) { _, _ in model.ensureSelectionVisible() }
        .onChange(of: model.hasModalPresentation) { _, presented in
            if presented { model.cancelDraft(); model.cancelRetouchDraft() }
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
            sidebarRow("전체 사진", icon: "square.grid.2x2", count: model.photos.count, selected: model.filter == .all) { model.filter = .all }
            sidebarRow("선택됨", icon: "checkmark.circle", count: model.counts.picks, selected: model.filter == .picks) { model.filter = .picks }
            sidebarRow("제외됨", icon: "xmark.circle", count: model.counts.rejects, selected: model.filter == .rejects) { model.filter = .rejects }
            sidebarRow("보정됨", icon: "slider.horizontal.3", count: model.counts.edited, selected: model.filter == .edited) { model.filter = .edited }
            sidebarRow("연속 촬영", icon: "square.stack.3d.down.right", count: model.burstIndex.positions.count, selected: model.filter == .bursts) { model.filter = .bursts }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack {
                        sectionLabel("내 폴더")
                        Spacer()
                        Button { model.presentCreateFolder() } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("새 폴더 만들기")
                            .disabled(!model.foldersLoaded)
                            .padding(.trailing, 18)
                    }.padding(.top, 24)
                    if let error = model.folderLoadError {
                        Text("폴더 오류: \(error)").font(.caption2).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
                    } else if model.photoFolders.isEmpty {
                        Text("내 폴더가 없습니다").font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 20)
                    }
                    ForEach(model.photoFolders) { folder in
                        HStack(spacing: 0) {
                            sidebarRow(folder.name, icon: "folder.fill",
                                       count: folder.photoIDs.intersection(model.counts.ids).count,
                                       selected: model.filter == .collection(folder.id)) {
                                model.filter = .collection(folder.id)
                            }
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
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("사진 라이브러리").font(.system(size: 18, weight: .semibold))
                Text("\(model.visiblePhotos.count)장 표시").font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 20)
            HStack(spacing: 5) {
                ForEach(WorkspaceMode.allCases, id: \.self) { mode in
                    Button { model.setMode(mode) } label: {
                        Image(systemName: mode == .grid ? "square.grid.2x2" : mode == .edit ? "photo" : "rectangle.split.2x1")
                            .frame(width: 34, height: 28)
                            .background(model.mode == mode ? Palette.accent.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).help(mode.rawValue)
                    .accessibilityLabel("\(mode.rawValue) 보기")
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
            }
            .padding(3).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            TextField("파일명 검색", text: $model.search)
                .textFieldStyle(.roundedBorder).frame(width: 165)
            Picker("별점", selection: $model.minimumRating) {
                Text("모든 별점").tag(0)
                ForEach(1...5, id: \.self) { Text("\($0)★ 이상").tag($0) }
            }
            .labelsHidden().frame(width: 112)
            Button { model.showExport = true } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                .accessibilityLabel("JPEG 내보내기")
                .disabled(model.selection == nil || model.isExporting || !model.catalogLoaded)
        }
        .padding(.horizontal, 20).frame(height: 67).background(Palette.panel)
    }

    private var selectionToolbar: some View {
        ScrollView(.horizontal) { HStack(spacing: 12) {
            Text("\(model.selectedPhotoIDs.count)장 선택")
                .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
            if let name = model.selection?.filename {
                Text("기준: \(name)").font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Button("전체 선택") { model.selectAllVisible() }
                .accessibilityLabel("보이는 사진 전체 선택")
                .disabled(model.visiblePhotos.isEmpty)
            Toggle("표시 후 다음 사진", isOn: $model.autoAdvance)
                .toggleStyle(.checkbox)
                .help("P·X·U·0–5 키로 표시하면 다음 사진으로 넘어갑니다")
                .accessibilityLabel("표시 후 자동으로 다음 사진")
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
            .disabled(model.selectedPhotoIDs.isEmpty || !model.foldersLoaded)
            .accessibilityLabel("선택한 사진을 폴더에 추가")
            if case .collection = model.filter {
                Button("이 폴더에서 빼기") { model.removeSelectedPhotosFromCurrentFolder() }
                    .disabled(model.selectedPhotoIDs.isEmpty || !model.foldersLoaded)
                    .accessibilityLabel("선택한 사진을 현재 폴더에서 빼기")
            }
        }.padding(.horizontal, 20) }
        .scrollIndicators(.hidden)
        .buttonStyle(.borderless)
        .frame(height: 36).background(Palette.panel)
    }

    @ViewBuilder private var mainContent: some View {
        if let error = model.loadError {
            emptyState("카탈로그 오류", icon: "exclamationmark.triangle", detail: error)
        } else if !model.catalogLoaded {
            ProgressView("카탈로그 여는 중…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
        } else if model.photos.isEmpty {
            emptyState("사진을 가져오세요", icon: "photo.on.rectangle.angled", detail: "폴더나 파일을 선택해 시작하세요. JPEG, HEIC, TIFF와 RAW 파일을 지원합니다.")
        } else if model.visiblePhotos.isEmpty {
            if case .collection = model.filter, model.search.isEmpty, model.minimumRating == 0 {
                emptyState("폴더가 비어 있습니다", icon: "folder", detail: "사진은 전체 라이브러리에서 선택해 이 폴더에 추가하세요.")
            } else {
                emptyState("검색 결과가 없습니다", icon: "magnifyingglass", detail: "검색어나 필터를 바꿔 보세요.")
            }
        } else if model.mode == .grid {
            grid
        } else {
            editorCanvas
        }
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
                model.gridColumnCount = Self.gridColumns(for: width)
            }
        }
        .background(Palette.canvas)
    }

    private var gridContent: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)], spacing: 14) {
            ForEach(model.visiblePhotos) { photo in
                PhotoTile(photo: photo,
                          selected: model.selectedPhotoIDs.contains(photo.id),
                          active: model.selectedID == photo.id)
                    .id(photo.id)
            }
        }
        .padding(22)
    }

    private static func gridColumns(for width: CGFloat) -> Int {
        max(1, Int((width - 44 + 14) / (180 + 14)))
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
                Text(model.selection?.filename ?? "").lineLimit(1).font(.subheadline.weight(.medium))
                Spacer()
                if model.mode == .compare, let pinned = model.pinned { Text("기준: \(pinned.filename)").font(.caption).foregroundStyle(Palette.muted).lineLimit(1) }
                Button(model.actualSize ? "화면 맞춤" : "100%") { model.toggleActualSize() }
                Button(model.isOriginal ? "보정 보기" : "원본 보기") { model.toggleOriginal() }
            }
            .buttonStyle(.borderless).padding(.horizontal, 20).frame(height: 44)
            HStack(spacing: 1) {
                if model.mode == .compare {
                    imagePane(model.pinnedImage, error: model.pinnedError, caption: "기준 · 원본", overlay: nil,
                              zoomable: false)
                }
                imagePane(model.rendered, error: model.imageError, caption: model.isOriginal ? "현재 · 원본" : "현재 · 보정",
                          overlay: model.showsClipping ? model.clippingOverlay : nil, zoomable: true)
            }
            .background(Palette.canvas)
        }
    }

    private func imagePane(_ image: NSImage?, error: String?, caption: String, overlay: NSImage?,
                           zoomable: Bool) -> some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    if model.actualSize {
                        let scale = NSApp.keyWindow?.backingScaleFactor ?? 1
                        let content = CGSize(width: image.size.width / scale, height: image.size.height / scale)
                        if zoomable {
                            actualSizeScroll(image, overlay: overlay, content: content, viewport: geometry.size)
                                .scrollPosition($zoomPosition)
                                .onAppear { scrollToZoomAnchor(content: content, viewport: geometry.size) }
                                .onChange(of: content) { _, size in scrollToZoomAnchor(content: size, viewport: geometry.size) }
                        } else {
                            actualSizeScroll(image, overlay: overlay, content: content, viewport: geometry.size)
                        }
                    } else {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(20)
                        if zoomable {
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
                        if model.mode == .edit, let photo = model.selection {
                            BrushCanvasView(canvas: model.canvas, photo: photo, imageSize: image.size,
                                            availableSize: geometry.size)
                        }
                    }
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
        }
    }

    private func actualSizeScroll(_ image: NSImage, overlay: NSImage?, content: CGSize,
                                  viewport: CGSize) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack {
                Image(nsImage: image).resizable().interpolation(.high)
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
        let width = max(1, available.width - 40), height = max(1, available.height - 40)
        let scale = min(width / max(1, imageSize.width), height / max(1, imageSize.height))
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (available.width - fitted.width) / 2, y: (available.height - fitted.height) / 2)
        let anchor = CGPoint(x: (location.x - origin.x) / fitted.width, y: (location.y - origin.y) / fitted.height)
        guard (0...1).contains(anchor.x), (0...1).contains(anchor.y) else { return }
        model.toggleActualSize(at: anchor)
    }

    private func scrollToZoomAnchor(content: CGSize, viewport: CGSize) {
        zoomPosition.scrollTo(point: CGPoint(
            x: max(0, min(content.width - viewport.width, model.zoomAnchor.x * content.width - viewport.width / 2)),
            y: max(0, min(content.height - viewport.height, model.zoomAnchor.y * content.height - viewport.height / 2))
        ))
    }

    private var filmstrip: some View {
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
                HStack { Text(message).lineLimit(2); Spacer(); Button { model.operationMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 16).padding(.top, 6)
            }
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
            }
        }
        .frame(height: (model.operationMessage == nil ? 106 : 129) + (model.isImporting || model.isExporting ? 22 : 0))
        .background(Palette.panel)
    }

    @ViewBuilder private var inspector: some View {
        if let photo = model.selection {
            InspectorView(photo: photo)
        } else {
            VStack { Text("사진을 선택하세요").foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.panel)
        }
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.modalWindow != nil || model.hasModalPresentation { return event }
            if event.keyCode == 53, NSApp.keyWindow?.firstResponder is NSTextView {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
                model.selectAllVisible()
                return nil
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "0", "1", "2", "3", "4", "5":
                    model.markFromKeyboard(rating: Int(event.charactersIgnoringModifiers!)!); return nil
                case "p": model.markFromKeyboard(flag: .pick); return nil
                case "x": model.markFromKeyboard(flag: .reject); return nil
                case "u": model.markFromKeyboard(flag: PhotoFlag.none); return nil
                case "z" where model.mode != .grid: model.toggleActualSize(); return nil
                case "g": model.setMode(.grid); return nil
                case "e": model.setMode(.edit); return nil
                case "c": model.setMode(.compare); return nil
                case "\\": model.toggleOriginal(); return nil
                case "j": model.showsClipping.toggle(); return nil
                default: break
                }
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06))
                    if let image = model.thumbnail(for: photo) {
                        Image(nsImage: image).resizable().scaledToFit().padding(4)
                    } else {
                        Image(systemName: "photo").font(.title).foregroundStyle(Palette.muted)
                    }
                    VStack {
                        HStack {
                            if photo.isRAW { Text("RAW").font(.system(size: 9, weight: .bold)).padding(5).background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4)) }
                            Spacer()
                            if photo.flag != .none { Image(systemName: photo.flag == .pick ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(photo.flag == .pick ? Palette.accent : .red) }
                        }
                        Spacer()
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
                                Spacer()
                            }
                        }
                    }.padding(8)
                }
                .frame(height: 150)
                HStack {
                    Text(photo.filename).lineLimit(1).font(.system(size: 12, weight: .medium))
                    if active { Text("기준").font(.caption2.weight(.bold)).foregroundStyle(Palette.accent) }
                }
                Text(photo.rating == 0 ? "별점 없음" : String(repeating: "★", count: photo.rating)).font(.caption).foregroundStyle(photo.rating == 0 ? Palette.muted : Palette.accent)
            }
            .padding(8)
            .background(selected ? Palette.accent.opacity(0.14) : Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Palette.accent : selected ? Palette.accent.opacity(0.48) : .clear, lineWidth: active ? 2 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { tileClicked(model, photo) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(photo.filename), 별점 \(photo.rating), \(active ? "기준 사진" : selected ? "선택됨" : "선택 안 됨")" + burstAccessibility)
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

    private var burstAccessibility: String {
        guard let burst = model.burstBadge(for: photo) else { return "" }
        return ", 연속 촬영 \(burst.count)컷 중 \(burst.shot)번째" + (burst.isBest == true ? ", 추천 컷" : "")
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
                if photo.flag == .pick { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent).padding(5) }
                if photo.flag == .reject { Image(systemName: "xmark.circle.fill").foregroundStyle(.red).padding(5) }
                if active { Text("기준").font(.system(size: 9, weight: .bold)).padding(3).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(4) }
            }
            .frame(width: 92, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Palette.accent : selected ? Palette.accent.opacity(0.5) : .clear, lineWidth: active ? 2 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onTapGesture { tileClicked(model, photo) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(photo.filename), \(active ? "기준 사진" : selected ? "선택됨" : "선택 안 됨")")
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
        .help(photo.filename)
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
                        .help("컷마다 초점 선명도와 얼굴 촬영 품질(눈 감음·흔들림)을 Mac 안에서 비교합니다")
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
