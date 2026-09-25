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
                Button("JPEG 내보내기…") { library.showExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(library.selection == nil || library.isExporting || library.hasModalPresentation)
                Divider()
                Button("카탈로그 보관본 보기") { library.revealBackups() }
            }
            CommandMenu("사진") {
                Button(library.isFocusView ? "사진만 보기 끝내기 (F)" : "사진만 보기 (F)") { library.toggleFocusView() }
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
