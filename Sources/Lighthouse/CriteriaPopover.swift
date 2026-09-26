import SwiftUI
import LighthouseCore

/// 표시·카메라·렌즈·초점거리·ISO·촬영일 조건. 바꾸는 즉시 목록에 걸리며, 검색어·별점과 함께 스마트 폴더로 저장할 수 있다.
struct CriteriaPopover: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var name = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("조건으로 거르기").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("표시")
                    Picker("표시", selection: $model.criteria.flag) {
                        Text("모두").tag(PhotoFlag?.none)
                        Text("선택됨").tag(PhotoFlag?.some(.pick))
                        Text("제외됨").tag(PhotoFlag?.some(.reject))
                        Text("표시 없음").tag(PhotoFlag?.some(PhotoFlag.none))
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("라벨")
                    Picker("라벨", selection: $model.criteria.colorLabel) {
                        Text("모두").tag(PhotoColorLabel?.none)
                        ForEach(PhotoColorLabel.allCases, id: \.self) { Text($0.title).tag(PhotoColorLabel?.some($0)) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("카메라")
                    Picker("카메라", selection: $model.criteria.camera) {
                        Text("모두").tag(String?.none)
                        ForEach(model.cameraChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("렌즈")
                    Picker("렌즈", selection: $model.criteria.lens) {
                        Text("모두").tag(String?.none)
                        ForEach(model.lensChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("초점거리")
                    HStack {
                        numberField("최소", value: $model.criteria.minimumFocalLength)
                        Text("–")
                        numberField("최대", value: $model.criteria.maximumFocalLength)
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("ISO")
                    HStack {
                        numberField("최소", value: integer($model.criteria.minimumISO))
                        Text("–")
                        numberField("최대", value: integer($model.criteria.maximumISO))
                    }
                }
                GridRow {
                    Toggle("시작일", isOn: dayEnabled(\.firstDay, fallback: model.captureDateRange?.lowerBound))
                    DatePicker("시작일", selection: day(\.firstDay), displayedComponents: .date)
                        .labelsHidden().disabled(model.criteria.firstDay == nil)
                }
                GridRow {
                    Toggle("마지막 날", isOn: dayEnabled(\.lastDay, fallback: model.captureDateRange?.upperBound))
                    DatePicker("마지막 날", selection: day(\.lastDay), displayedComponents: .date)
                        .labelsHidden().disabled(model.criteria.lastDay == nil)
                }
            }
            .font(.callout)
            HStack {
                Button("조건 지우기") { model.criteria = PhotoCriteria() }
                    .disabled(model.criteria.isEmpty)
                Spacer()
                Text("범위 조건이 있으면 그 정보가 없는 사진은 빠집니다.").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Text("스마트 폴더로 저장").font(.subheadline.weight(.semibold))
            HStack {
                TextField("폴더 이름", text: $name).onSubmit(save)
                Button("저장", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.combinedCriteria.isEmpty)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("위의 조건과 함께 지금 검색어·별점 조건도 저장합니다. 사진을 담지 않고 열 때마다 조건에 맞는 사진을 보여 줍니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func save() {
        saveError = model.saveSmartFolder(name: name)
        if saveError == nil { name = "" }
    }

    /// 빈칸이면 조건 없음. 숫자가 아닌 글자는 무시한다.
    private func numberField(_ title: String, value: Binding<Double?>) -> some View {
        TextField(title, text: Binding(
            get: {
                guard let number = value.wrappedValue else { return "" }
                return number.rounded() == number ? String(Int(number)) : String(number)
            },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                value.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
        ))
        .frame(width: 70)
        .accessibilityLabel(title)
    }

    private func integer(_ binding: Binding<Int?>) -> Binding<Double?> {
        Binding(get: { binding.wrappedValue.map(Double.init) },
                set: { binding.wrappedValue = $0.map { Int($0.rounded()) } })
    }

    private func dayEnabled(_ keyPath: WritableKeyPath<PhotoCriteria, Date?>, fallback: Date?) -> Binding<Bool> {
        Binding(get: { model.criteria[keyPath: keyPath] != nil },
                set: { model.criteria[keyPath: keyPath] = $0 ? (fallback ?? Date()) : nil })
    }

    private func day(_ keyPath: WritableKeyPath<PhotoCriteria, Date?>) -> Binding<Date> {
        Binding(get: { model.criteria[keyPath: keyPath] ?? Date() },
                set: { model.criteria[keyPath: keyPath] = $0 })
    }
}
