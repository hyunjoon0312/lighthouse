import AppKit
import SwiftUI

struct CardImportSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cardImportDestination") private var destinationPath = CardImportSheet.defaultDestination
    @AppStorage("cardImportOrganizeByDate") private var organizeByDate = true
    @State private var source: URL?
    @State private var foundCount: Int?
    @State private var scanCancellation: CancellationFlag?

    static var defaultDestination: String {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lighthouse", isDirectory: true).path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sdcard").font(.title2).foregroundStyle(Palette.accent)
                Text("카드에서 복사해 가져오기").font(.title2.weight(.semibold))
            }
            Text("카드의 원본은 그대로 두고 사진을 아래 폴더로 복사한 뒤 가져옵니다. 카드를 빼도 계속 보고 보정할 수 있습니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("가져올 카드·폴더", value: source?.path ?? "선택하세요") { chooseSource() }
            if let source {
                if let foundCount {
                    Text(foundCount == 0 ? "가져올 수 있는 사진이 없습니다." : "사진 \(foundCount)장을 찾았습니다.")
                        .font(.caption).foregroundStyle(foundCount == 0 ? .red : .secondary)
                } else {
                    ProgressView("\(source.lastPathComponent)에서 사진을 찾는 중…").controlSize(.small)
                }
            }
            row("복사할 위치", value: destinationPath) { chooseDestination() }
            Toggle("촬영 날짜별 폴더로 정리 (연도/연-월-일)", isOn: $organizeByDate)
            Text("같은 이름의 파일이 이미 있으면 내용을 비교해 같으면 다시 복사하지 않고, 다르면 이름 뒤에 번호를 붙입니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("복사해서 가져오기") {
                    guard let source else { return }
                    model.importByCopying(from: source, to: URL(fileURLWithPath: destinationPath, isDirectory: true),
                                          organizeByDate: organizeByDate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(source == nil || foundCount == nil || foundCount == 0 || model.isImporting || model.isExporting)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onDisappear { scanCancellation?.cancel() }
    }

    private func row(_ title: String, value: String, choose: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("선택…", action: choose).accessibilityLabel("\(title) 선택")
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = "선택"
        panel.message = "메모리 카드나 사진이 있는 폴더를 선택하세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanCancellation?.cancel()
        let cancellation = CancellationFlag()
        scanCancellation = cancellation
        source = url
        foundCount = nil
        Task.detached {
            let count = LibraryModel.supportedFiles(in: [url], cancellation: cancellation).count
            await MainActor.run {
                if source == url, scanCancellation === cancellation, !cancellation.isCancelled { foundCount = count }
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationPath = url.path
    }
}
