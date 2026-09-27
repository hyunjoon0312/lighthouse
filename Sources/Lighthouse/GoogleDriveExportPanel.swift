import AppKit
import LighthouseCore
import SwiftUI
import UniformTypeIdentifiers

struct GoogleDriveExportPanel: View {
    @ObservedObject var upload: GoogleDriveUploadModel
    let photos: [PhotoAsset]
    let options: ExportOptions
    @Binding var content: GoogleDriveUploadContent
    @State private var folderName = "Lighthouse"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !upload.isConfigured { setup }
            else if !upload.isConnected { connect }
            else { connected }
            if upload.isBusy && !upload.isConnected { activity }
            if let error = upload.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let report = upload.report {
                Text(report).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !upload.uploadFailures.isEmpty {
                DisclosureGroup("실패한 파일 \(upload.uploadFailures.count)개") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(upload.uploadFailures) { failure in
                            Text("\(failure.name): \(failure.reason)")
                                .font(.caption2).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .onAppear { upload.prepare() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Google Drive 설정").font(.headline)
            Text("1. Google Cloud에서 Desktop 앱 OAuth 클라이언트를 만듭니다.\n2. JSON을 내려받아 이 Mac에 가져옵니다. 자격 증명은 Keychain에만 저장됩니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Google Cloud Console 열기", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
            Button("OAuth JSON 가져오기…") { importConfiguration() }
                .disabled(upload.isBusy)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Google 계정 연결").font(.headline)
            Text("시스템 브라우저에서 로그인합니다. Lighthouse는 이 앱으로 만든 파일과 폴더에만 접근하는 drive.file 권한을 요청합니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Google 계정 연결…") { upload.signIn() }.disabled(upload.isBusy)
                Button("OAuth JSON 다시 선택…") { importConfiguration() }.disabled(upload.isBusy)
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(upload.account?.displayName ?? "Google 계정").font(.subheadline.weight(.semibold))
                    if let email = upload.account?.emailAddress { Text(email).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("새로 고침") { upload.loadAccountAndFolders() }.disabled(upload.isBusy)
            }
            Picker("업로드", selection: $content) {
                ForEach(GoogleDriveUploadContent.allCases) { Text($0.title).tag($0) }
            }
            .disabled(upload.isBusy)
            Picker("Drive 폴더", selection: $upload.selectedFolderID) {
                Text("폴더 선택").tag(String?.none)
                ForEach(upload.folders) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(upload.isBusy)
            Text("이 목록에는 Lighthouse가 만든 폴더만 표시됩니다.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                TextField("새 폴더 이름", text: $folderName).textFieldStyle(.roundedBorder)
                    .disabled(upload.isBusy)
                Button("폴더 만들기") { upload.createFolder(name: folderName) }
                    .disabled(upload.isBusy || folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if content.includesOriginal {
                Text("원본은 바꾸지 않고 그대로 올립니다. 원본에 위치 정보가 있으면 그 정보도 포함됩니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("새 파일은 선택한 폴더의 기존 공유 상태를 따릅니다. 자동 동기화·덮어쓰기·공유 설정 변경은 하지 않습니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if upload.isBusy {
                activity
            } else {
                HStack {
                    Button("이 Mac에서 연결 해제") { upload.disconnect() }
                    Spacer()
                    Button("Drive로 업로드") { upload.upload(photos: photos, content: content, options: options) }
                        .buttonStyle(.borderedProminent)
                        .disabled(photos.isEmpty || upload.selectedFolderID == nil)
                }
                Text("연결 해제는 이 Mac의 토큰만 지웁니다. Google 계정의 권한은 계정 설정에서 별도로 취소할 수 있습니다.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let url = upload.resultFolderURL, upload.report != nil {
                Button("Drive 폴더 열기") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            if upload.totalPhotos > 0 {
                ProgressView(value: upload.progress)
                Text("사진 \(upload.completedPhotos)/\(upload.totalPhotos)" +
                     (upload.currentFileName.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                ProgressView()
                if let status = upload.currentFileName {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(upload.isCancelling ? "중지하는 중…" : "작업 중지") { upload.cancel() }
                .disabled(upload.isCancelling)
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "가져오기"
        if panel.runModal() == .OK, let url = panel.url {
            upload.configure(fileURL: url)
        }
    }
}
