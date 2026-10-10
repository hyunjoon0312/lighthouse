import SwiftUI
import LighthouseCore

struct PresetSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let request: PresetSheetRequest
    @State private var name: String
    @State private var includesGlobal = true
    @State private var includesLUT = true
    @State private var includesGeometry = false
    @State private var error: String?

    init(request: PresetSheetRequest) {
        self.request = request
        _name = State(initialValue: request.initialName)
    }

    private var isRename: Bool {
        if case .rename = request.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRename ? "프리셋 이름 변경" : "현재 보정을 프리셋으로 저장").font(.title2.weight(.semibold))
            TextField("프리셋 이름", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("프리셋 이름")
            if !isRename {
                Text("담을 항목").font(.caption.weight(.semibold))
                Toggle("전체 보정 (빛·색·곡선·HSL·입자·RAW 현상 등)", isOn: $includesGlobal)
                Toggle("LUT", isOn: $includesLUT)
                Toggle("구도 (회전·크롭·수평)", isOn: $includesGeometry)
                Text("부분 보정과 복구는 사진마다 위치가 달라 프리셋에 담지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(isRename ? "이름 변경" : "저장") { commit() }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              (!isRename && !includesGlobal && !includesLUT && !includesGeometry))
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func commit() {
        switch request.kind {
        case .save:
            var components: EditComponents = []
            if includesGlobal { components.insert(.global) }
            if includesLUT { components.insert(.lut) }
            if includesGeometry { components.insert(.geometry) }
            error = model.savePreset(name: name, components: components)
        case .rename(let id):
            error = model.renamePreset(id, to: name)
        }
        if error == nil { dismiss() }
    }
}
