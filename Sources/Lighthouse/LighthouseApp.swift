import SwiftUI
import AppKit
import LighthouseCore

@main
struct LighthouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session = LibrarySession()
    /// 작업 화면(`WorkspaceView`)과 같은 키로 사이드바·오른쪽 패널을 숨긴다.
    @AppStorage("showsSidebar") private var showsSidebar = true
    @AppStorage("showsInspector") private var showsInspector = true
    private var library: LibraryModel { session.library }

    var body: some Scene {
        WindowGroup {
            ZStack {
                WorkspaceView()
                    .environmentObject(session.library)
                    .environmentObject(session)
                    .id(session.library.dataDirectory.path)
                    .disabled(session.isSwitching)
                if session.isSwitching {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("라이브러리를 여는 중…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
                .alert("라이브러리 오류", isPresented: Binding(
                    get: { session.errorMessage != nil },
                    set: { if !$0 { session.errorMessage = nil } }
                )) { Button("확인") { session.errorMessage = nil } } message: {
                    Text(session.errorMessage ?? "라이브러리를 열 수 없습니다.")
                }
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.library = session.library
                    session.library.start()
                }
                .onChange(of: session.library.dataDirectory) { _, _ in delegate.library = session.library }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("사진 가져오기…") { session.library.presentImport() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(session.library.isImporting || session.library.isExporting || session.library.hasModalPresentation)
                Button("카드에서 복사해 가져오기…") { session.library.showCardImport = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!session.library.catalogLoaded || session.library.isImporting || session.library.isExporting || session.library.hasModalPresentation)
                Button("LUT 추가…") { library.presentLUTImport() }
                    .disabled(!library.catalogLoaded || library.isLUTImporting || library.isLUTLibraryLoading || library.hasModalPresentation)
                Button("Lightroom 프리셋 가져오기…") { library.presentLightroomPresetImport() }
                    .disabled(!library.catalogLoaded || library.presetLoadError != nil || library.isPresetImporting || library.hasModalPresentation)
                Button("참조 사진 색감 맞추기…") { library.presentReferenceMatch() }
                    .disabled(library.selection == nil || library.hasModalPresentation)
            }
            CommandGroup(after: .saveItem) {
                Button("내보내기…") { library.showExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(library.selection == nil || library.selection.map(library.isMissing) == true || library.isExporting || library.hasModalPresentation)
                Button("바뀐 사진 다시 내보내기…") { library.showExport = true }
                    .disabled(library.selection == nil || library.isExporting || library.hasModalPresentation)
                Divider()
                Button("카탈로그 보관본 보기") { library.revealBackups() }
                Divider()
                Button("라이브러리 백업…") { library.showLibraryBackup = true }
                    .disabled(library.hasConflictingWorkflow || library.hasModalPresentation)
                Button("라이브러리 복원…") { library.showLibraryRestore = true }
                    .disabled(library.hasConflictingWorkflow || library.hasModalPresentation)
                Button("라이브러리 열기…") { session.presentOpenLibrary() }
                    .disabled(library.hasConflictingWorkflow || library.hasModalPresentation || session.isSwitching)
            }
            // 한 글자 단축키는 글자 칸 입력을 가로채지 않도록 메뉴에 등록하지 않고 이름에만 적는다.
            CommandGroup(before: .toolbar) {
                Button(showsSidebar ? "사이드바 가리기" : "사이드바 보기") { showsSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .disabled(library.hasModalPresentation)
                Button(showsInspector ? "보정 패널 가리기" : "보정 패널 보기") { showsInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.option, .command])
                    .disabled(library.hasModalPresentation)
                Divider()
                Button("그리드 (G)") { library.setMode(.grid) }
                    .disabled(library.hasModalPresentation)
                Button("사진 (E)") { library.setMode(.edit) }
                    .disabled(library.hasModalPresentation)
                Button("비교 (C)") { library.setMode(.compare) }
                    .disabled(library.hasModalPresentation)
                Button("여러 장 보기 (N)") { library.setMode(.survey) }
                    .disabled(library.hasModalPresentation)
                Divider()
                Button(library.showsSplit ? "나눠 보기 끄기 (Y)" : "보정 전·후 나눠 보기 (Y)") { library.toggleSplit() }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                // 문자열 리터럴 이름은 Markdown으로 읽혀 `\)`의 \가 사라지므로 그대로 쓴다.
                Button { library.toggleOriginal() } label: {
                    Text(verbatim: library.isOriginal ? "보정 보기 (\\)" : "원본 보기 (\\)")
                }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button(library.actualSize ? "화면 맞춤 (Z)" : (library.selectionUsesSmartPreview ? "미리보기 확대 (Z)" : "100% 보기 (Z)")) { library.toggleActualSize() }
                    .disabled(library.selection == nil || !library.showsSingleImage || library.hasModalPresentation)
                Button(library.showsClipping ? "잘림 표시 끄기 (J)" : "하이라이트·섀도 잘림 표시 (J)") { library.showsClipping.toggle() }
                    .disabled(library.hasModalPresentation)
                Button(library.isFocusView ? "사진만 보기 끝내기 (F)" : "사진만 보기 (F)") { library.toggleFocusView() }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Toggle("얼굴 확대 보기", isOn: Binding(get: { library.showsFaceCloseups }, set: { library.showsFaceCloseups = $0 }))
                    .disabled(library.hasModalPresentation)
                Divider()
            }
            CommandMenu("사진") {
                Button("중복·유사 사진 찾기…") { library.showSimilarPhotos = true }
                    .disabled(!library.catalogLoaded || library.hasModalPresentation)
                Button("스마트 미리보기 관리…") { library.showSmartPreviews = true }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Divider()
                Button("얼굴 찾기 · 관리…") { library.showPeople = true }
                    .disabled(!library.catalogLoaded || library.hasModalPresentation)
                Divider()
                Button("채택 표시 (P)") { library.markFromKeyboard(flag: .pick) }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button("제외 표시 (X)") { library.markFromKeyboard(flag: .reject) }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button("표시 해제 (U)") { library.markFromKeyboard(flag: PhotoFlag.none) }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Menu("별점") {
                    ForEach(0...5, id: \.self) { rating in
                        Button(rating == 0 ? "별점 없음 (0)" : "\(String(repeating: "★", count: rating)) (\(rating))") {
                            library.markFromKeyboard(rating: rating)
                        }
                    }
                }
                .disabled(library.selection == nil || library.hasModalPresentation)
                Menu("색상 라벨") {
                    ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                        Button(library.labelMenuTitle(label) + (label.keyHint.map { " (\($0))" } ?? "")) { library.markFromKeyboard(toggleLabel: label) }
                            .disabled(library.selection == nil)
                    }
                    Divider()
                    Button("라벨 떼기") { library.setColorLabel(nil) }
                        .disabled(library.selection == nil)
                    Divider()
                    Button("라벨 이름 정하기…") { library.showColorLabelNames = true }
                }
                .disabled(library.hasModalPresentation)
                Divider()
                Button("자동 보정") { library.autoAdjust() }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(library.selection == nil || library.isAutoAdjusting || library.hasModalPresentation)
                Divider()
                Button("회색 찍기 (W)") { library.beginWhiteBalancePick() }
                    .disabled(library.selection == nil || library.isAutoAdjusting || library.hasModalPresentation)
                Button("자유 크롭… (R)") { library.presentCrop() }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button("왼쪽으로 회전") { library.rotate(clockwise: false) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button("오른쪽으로 회전") { library.rotate(clockwise: true) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button("Finder에서 원본 보기") { library.revealOriginals() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Divider()
                Button("가상 사본 만들기") { library.createVirtualCopy() }
                    .keyboardShortcut("'", modifiers: .command)
                    .disabled(library.selection == nil || !library.catalogLoaded || library.hasModalPresentation)
                Button("가상 사본 삭제…") { library.requestDeleteVirtualCopies() }
                    .disabled(library.selectedVirtualCopies.isEmpty || library.hasModalPresentation)
                Divider()
                Button("카탈로그에서 빼기… (Delete)") { library.requestRemoveFromCatalog() }
                    .disabled(library.selection == nil || !library.catalogLoaded || library.hasModalPresentation)
                Button("위치 다시 찾기…") { if let photo = library.selection { library.presentRelocate(for: photo) } }
                    .disabled(library.selection.map { !library.isMissing($0) } ?? true || library.hasModalPresentation)
                Divider()
                Toggle("별점·키워드를 XMP 사이드카로 쓰기", isOn: Binding(
                    get: { library.writesXMPSidecars }, set: { library.writesXMPSidecars = $0 }
                ))
                    .disabled(!library.catalogLoaded)
                Button("RAW의 XMP 사이드카 모두 다시 쓰기") { library.writeAllSidecars() }
                    .disabled(!library.writesXMPSidecars || !library.catalogLoaded)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { library.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!library.canUndo || library.hasModalPresentation)
                Button("다시 실행") { library.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!library.canRedo || library.hasModalPresentation)
                Divider()
                Button("보정 복사") { library.copyEdits() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button("보정 붙여넣기") { library.pasteEditsToSelection() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(library.clipboard == nil || library.selection == nil || library.hasModalPresentation)
            }
            CommandGroup(replacing: .help) {
                // ⌘?는 창의 키 감시가 받는다(SwiftUI가 이 메뉴 단축키를 붙이지 않는다). 한 글자 키처럼 이름에 적는다.
                Button("Lighthouse 도움말 (⌘?)") { library.showHelp = true }
                    .disabled(library.hasModalPresentation)
                Button("단축키 보기 (?)") { library.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
                    .disabled(library.hasModalPresentation)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryModel?
    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 라이브러리 창은 하나라 macOS가 붙이는 창 탭 메뉴(탭 막대 보기·모든 탭 보기 등)를 두지 않는다. 창을 만들기 전에 꺼야 한다.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        if let library, library.driveUpload.isBusy || library.isExporting || library.isImporting || library.isPresetImporting || library.isAnalyzingFaces || library.isRunningWorkflow || library.isAnalyzingFlicker {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "가져오기·내보내기 또는 얼굴 분석이 진행 중입니다"
            alert.informativeText = "지금 종료하면 진행 중인 작업을 중지하고 정리를 마친 뒤 종료합니다. 완료된 가져오기·얼굴 분석 결과와 카탈로그 항목은 유지되며, Drive로 전송 중이던 파일은 도착했을 수 있습니다."
            alert.addButton(withTitle: "앱으로 돌아가기")
            alert.addButton(withTitle: "작업 취소하고 종료")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            library.cancelExport()
            library.cancelImport()
            library.cancelPresetImport()
            library.cancelFaceAnalysis()
            library.driveUpload.cancel()
            library.cancelWorkflow()
            library.cancelFlickerAnalysis()
            terminationPending = true
            Task { @MainActor [weak self] in
                await library.driveUpload.cancelAndWait()
                await library.cancelExportAndWait()
                await library.cancelImportAndWait()
                await library.cancelFaceAnalysisAndWait()
                await library.cancelWorkflowAndWait()
                let shouldTerminate = self?.flushBeforeTermination() ?? false
                self?.terminationPending = false
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
            return .terminateLater
        }
        return flushBeforeTermination() ? .terminateNow : .terminateCancel
    }

    @MainActor
    private func flushBeforeTermination() -> Bool {
        do {
            try library?.flushSave()
            return true
        } catch {
            AppLog.catalog.fault("save on quit failed: \(error.localizedDescription, privacy: .private)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "사진·폴더·사람 정보 또는 XMP 사이드카를 저장하지 못했습니다"
            alert.informativeText = "\(error.localizedDescription)\n문제를 해결한 뒤 다시 종료하세요."
            alert.addButton(withTitle: "앱으로 돌아가기")
            alert.runModal()
            return false
        }
    }
}
