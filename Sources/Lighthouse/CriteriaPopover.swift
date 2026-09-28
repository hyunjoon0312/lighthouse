import SwiftUI
import LighthouseCore

/// 표시·카메라·렌즈·초점거리·ISO·촬영일 조건. 바꾸는 즉시 목록에 걸리며, 검색어·별점과 함께 스마트 폴더로 저장할 수 있다.
struct CriteriaPopover: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var name = ""
    @State private var saveError: String?
    @State private var minimumFocalLengthIsValid = true
    @State private var maximumFocalLengthIsValid = true
    @State private var minimumISOIsValid = true
    @State private var maximumISOIsValid = true
    @State private var numericResetID = 0

    private var numericDraftsAreValid: Bool {
        minimumFocalLengthIsValid && maximumFocalLengthIsValid &&
            minimumISOIsValid && maximumISOIsValid
    }

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
                    HStack(alignment: .top) {
                        CriteriaNumberField("최소", accessibilityLabel: "최소 초점거리",
                                            value: $model.criteria.minimumFocalLength,
                                            isValid: $minimumFocalLengthIsValid, resetID: numericResetID)
                        Text("–")
                        CriteriaNumberField("최대", accessibilityLabel: "최대 초점거리",
                                            value: $model.criteria.maximumFocalLength,
                                            isValid: $maximumFocalLengthIsValid, resetID: numericResetID)
                        Text("mm").foregroundStyle(.secondary).fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                GridRow {
                    Text("ISO")
                    HStack(alignment: .top) {
                        CriteriaNumberField("최소", accessibilityLabel: "최소 ISO",
                                            value: $model.criteria.minimumISO,
                                            isValid: $minimumISOIsValid, resetID: numericResetID)
                        Text("–")
                        CriteriaNumberField("최대", accessibilityLabel: "최대 ISO",
                                            value: $model.criteria.maximumISO,
                                            isValid: $maximumISOIsValid, resetID: numericResetID)
                    }
                    .fixedSize(horizontal: true, vertical: false)
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
                Button("조건 지우기", action: clearCriteria)
                    .disabled(model.criteria.isEmpty && numericDraftsAreValid)
                Spacer()
                Text("범위 조건이 있으면 그 정보가 없는 사진은 빠집니다.").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Text("스마트 폴더로 저장").font(.subheadline.weight(.semibold))
            HStack {
                TextField("폴더 이름", text: $name).onSubmit(save)
                Button("저장", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              model.combinedCriteria.isEmpty || !numericDraftsAreValid)
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
        guard numericDraftsAreValid else {
            saveError = "숫자 조건을 확인하세요."
            return
        }
        saveError = model.saveSmartFolder(name: name)
        if saveError == nil { name = "" }
    }

    private func clearCriteria() {
        model.criteria = PhotoCriteria()
        minimumFocalLengthIsValid = true
        maximumFocalLengthIsValid = true
        minimumISOIsValid = true
        maximumISOIsValid = true
        numericResetID &+= 1
        saveError = nil
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
