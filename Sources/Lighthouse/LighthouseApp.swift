import SwiftUI
import AppKit
import LighthouseCore

@main
struct LighthouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(library)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.library = library
                    library.start()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("사진 가져오기…") { library.presentImport() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(library.hasModalPresentation)
                Button("카드에서 복사해 가져오기…") { library.showCardImport = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!library.catalogLoaded || library.isImporting || library.hasModalPresentation)
                Button("LUT 추가…") { library.presentLUTImport() }
                    .disabled(!library.catalogLoaded || library.isLUTImporting || library.isLUTLibraryLoading || library.hasModalPresentation)
                Button("참조 사진 색감 맞추기…") { library.presentReferenceMatch() }
                    .disabled(library.selection == nil || library.hasModalPresentation)
            }
            CommandGroup(after: .saveItem) {
                Button("내보내기…") { library.showExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(library.selection == nil || library.isExporting || library.hasModalPresentation)
                Divider()
                Button("카탈로그 보관본 보기") { library.revealBackups() }
            }
            // 한 글자 단축키는 글자 칸 입력을 가로채지 않도록 메뉴에 등록하지 않고 이름에만 적는다.
            CommandGroup(before: .toolbar) {
                Button("그리드 (G)") { library.setMode(.grid) }
                    .disabled(library.hasModalPresentation)
                Button("사진 (E)") { library.setMode(.edit) }
                    .disabled(library.hasModalPresentation)
                Button("비교 (C)") { library.setMode(.compare) }
                    .disabled(library.hasModalPresentation)
                Divider()
                Button(library.isOriginal ? "보정 보기 (\\)" : "원본 보기 (\\)") { library.toggleOriginal() }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Button(library.actualSize ? "화면 맞춤 (Z)" : "100% 보기 (Z)") { library.toggleActualSize() }
                    .disabled(library.selection == nil || library.mode == .grid || library.hasModalPresentation)
                Button(library.showsClipping ? "잘림 표시 끄기 (J)" : "하이라이트·섀도 잘림 표시 (J)") { library.showsClipping.toggle() }
                    .disabled(library.hasModalPresentation)
                Button(library.isFocusView ? "사진만 보기 끝내기 (F)" : "사진만 보기 (F)") { library.toggleFocusView() }
                    .disabled(library.selection == nil || library.hasModalPresentation)
                Divider()
            }
            CommandMenu("사진") {
                Button("선택 표시 (P)") { library.markFromKeyboard(flag: .pick) }
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
                        Button(label.title + (label.keyHint.map { " (\($0))" } ?? "")) { library.markFromKeyboard(toggleLabel: label) }
                    }
                    Divider()
                    Button("라벨 떼기") { library.setColorLabel(nil) }
                }
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
                Button("단축키 보기 (?)") { library.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
                    .disabled(library.hasModalPresentation)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try library?.flushSave()
            return .terminateNow
        } catch {
            AppLog.catalog.fault("save on quit failed: \(error.localizedDescription, privacy: .private)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "사진 또는 폴더 정보를 저장하지 못했습니다"
            alert.informativeText = "\(error.localizedDescription)\n문제를 해결한 뒤 다시 종료하세요."
            alert.addButton(withTitle: "앱으로 돌아가기")
            alert.runModal()
            return .terminateCancel
        }
    }
}
