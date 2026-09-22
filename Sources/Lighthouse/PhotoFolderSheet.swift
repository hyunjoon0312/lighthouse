import SwiftUI

struct PhotoFolderSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let request: PhotoFolderSheetRequest
    @State private var name = ""
    @State private var includeSelected = false
    @State private var validationError: String?

    private var isCreate: Bool {
        if case .create = request.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isCreate ? "새 폴더" : "폴더 이름 변경").font(.title2.weight(.semibold))
            TextField("폴더 이름", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("폴더 이름")
                .onSubmit(commit)
            if isCreate {
                Toggle("선택한 \(request.selectedIDs.count)장 포함", isOn: $includeSelected)
                    .disabled(request.selectedIDs.isEmpty)
                    .accessibilityLabel("선택한 사진을 새 폴더에 포함")
            }
            Text("원본 사진은 이동하거나 복사하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(isCreate ? "만들기" : "이름 변경", action: commit)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear {
            name = request.initialName
            includeSelected = !request.selectedIDs.isEmpty
        }
    }

    private func commit() {
        validationError = model.commitFolderSheet(request, name: name, includeSelected: includeSelected)
        if validationError == nil { dismiss() }
    }
}
