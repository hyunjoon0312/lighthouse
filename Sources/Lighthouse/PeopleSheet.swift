import AppKit
import SwiftUI
import LighthouseCore

private enum PeopleTab: String, CaseIterable {
    case confirmed = "확인됨"
    case candidates = "같은 사람 후보"
}

struct PeopleSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPersonID: UUID?
    @State private var tab: PeopleTab = .confirmed
    @State private var selectedFaceIDs = Set<UUID>()
    @State private var newName = ""
    @State private var existingPersonID: UUID?
    @State private var renameText = ""
    @State private var displayedLimit = 100
    @State private var deletingPerson: PersonProfile?
    @State private var confirmsClear = false
    @State private var inlineError: String?

    private var person: PersonProfile? {
        selectedPersonID.flatMap { id in model.peopleCatalog.people.first { $0.id == id } }
    }

    private var allItems: [PeopleFaceItem] {
        guard let selectedPersonID else { return model.peopleFaces(personID: nil) }
        return tab == .confirmed
            ? model.peopleFaces(personID: selectedPersonID)
            : model.candidateFaces(for: selectedPersonID)
    }

    private var displayedItems: [PeopleFaceItem] { Array(allItems.prefix(displayedLimit)) }
    private var allItemIDs: Set<UUID> { Set(allItems.map(\.id)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                peopleList.frame(width: 210)
                Divider()
                content
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 560, idealHeight: 650)
        .background(Color(red: 0.105, green: 0.112, blue: 0.122))
        .confirmationDialog("사람 이름 삭제", isPresented: Binding(
            get: { deletingPerson != nil },
            set: { if !$0 { deletingPerson = nil } }
        )) {
            Button("이름 삭제", role: .destructive) {
                if let deletingPerson { model.deletePerson(deletingPerson.id) }
                self.deletingPerson = nil
                selectedPersonID = nil
                tab = .confirmed
                inlineError = nil
            }
            Button("취소", role: .cancel) { deletingPerson = nil }
        } message: {
            Text("이름과 분류만 지웁니다. 얼굴은 미분류로 돌아가며 사진은 그대로입니다.")
        }
        .confirmationDialog("얼굴 분석 정보 모두 지우기", isPresented: $confirmsClear) {
            Button("모두 지우기", role: .destructive) {
                Task { @MainActor in
                    await model.clearPeopleAnalysis()
                    selectedPersonID = nil
                    selectedFaceIDs.removeAll()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("사람 이름, 분류, 얼굴 분석 결과만 지웁니다. 사진과 보정은 그대로입니다.")
        }
        .onChange(of: selectedPersonID) { _, value in
            selectedFaceIDs.removeAll()
            displayedLimit = 100
            tab = value == nil ? .confirmed : tab
            renameText = person?.name ?? ""
            inlineError = nil
        }
        .onChange(of: tab) { _, _ in selectedFaceIDs.removeAll(); displayedLimit = 100; inlineError = nil }
        .onChange(of: allItemIDs) { _, currentIDs in selectedFaceIDs.formIntersection(currentIDs) }
        .onDisappear { model.cancelFaceAnalysis() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("얼굴 찾기 · 관리").font(.title2.bold())
                    Text("Mac 안에서 분석합니다. 이름을 붙인 뒤 같은 사람 후보를 확인하세요.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("얼굴 찾기") {
                    Button("전체 사진에서 얼굴 찾기") { model.startFaceAnalysis(selectedOnly: false) }
                    Button("선택 사진에서 얼굴 찾기") { model.startFaceAnalysis(selectedOnly: true) }
                        .disabled(model.selectedPhotoIDs.isEmpty)
                }
                .disabled(!model.peopleLoaded || model.peopleLoadError != nil || model.isAnalyzingFaces || model.isClearingPeople || model.photos.isEmpty)
                if model.peopleSaveError != nil {
                    Button("다시 저장") { model.schedulePeopleSave() }
                        .disabled(model.isClearingPeople)
                }
                Button("닫기") { dismiss() }
            }
            if model.isAnalyzingFaces {
                HStack {
                    ProgressView(value: Double(model.faceAnalysisCompleted), total: Double(max(1, model.faceAnalysisTotal)))
                    Text("\(model.faceAnalysisCompleted)/\(model.faceAnalysisTotal)").monospacedDigit().font(.caption)
                    Button(model.isCancellingFaces ? "중지 중…" : "중지") { model.cancelFaceAnalysis() }
                        .disabled(model.isCancellingFaces)
                }
            }
            if let message = model.peopleLoadError ?? model.peopleSaveError ?? model.peopleMessage {
                Text(message).font(.caption).foregroundStyle(model.peopleLoadError != nil || model.peopleSaveError != nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("사람").font(.headline).padding(.horizontal, 14).padding(.top, 14)
            Button {
                selectedPersonID = nil
            } label: {
                listRow("미분류", count: model.peopleFaces(personID: nil).count, selected: selectedPersonID == nil)
            }.buttonStyle(.plain)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.sortedPeople) { person in
                        Button { selectedPersonID = person.id } label: {
                            listRow(person.name, count: model.counts.people[person.id] ?? 0, selected: selectedPersonID == person.id)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 8)
            Button("얼굴 분석 정보 모두 지우기…", role: .destructive) { confirmsClear = true }
                .font(.caption).padding(14)
                .disabled(!model.peopleLoaded || model.peopleLoadError != nil || model.isClearingPeople || (model.peopleCatalog.people.isEmpty && model.peopleCatalog.analyses.isEmpty))
        }
        .background(Color.white.opacity(0.035))
    }

    private func listRow(_ title: String, count: Int, selected: Bool) -> some View {
        HStack {
            Image(systemName: "person.crop.square")
            Text(title).lineLimit(1)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var content: some View {
        VStack(spacing: 0) {
            contentToolbar
            Divider()
            Group {
                if model.peopleLoadError != nil {
                    empty("사람 정보를 열 수 없습니다", detail: "파일을 복구한 뒤 앱을 다시 실행하세요.")
                } else if model.photos.isEmpty {
                    empty("사진이 없습니다", detail: "사진을 가져온 뒤 얼굴 찾기를 실행하세요.")
                } else if model.peopleCatalog.analyses.isEmpty {
                    empty("아직 분석한 사진이 없습니다", detail: "전체 사진 또는 선택 사진에서 얼굴 찾기를 실행하세요.")
                } else if allItems.isEmpty {
                    empty(selectedPersonID == nil ? "미분류 얼굴이 없습니다" : (tab == .candidates ? "같은 사람 후보가 없습니다" : "확인된 얼굴이 없습니다"),
                          detail: model.peopleCatalog.analyses.allSatisfy { $0.faces.isEmpty } ? "분석한 사진에서 얼굴을 찾지 못했습니다." : "다른 목록을 선택해 보세요.")
                } else {
                    faceGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let inlineError {
                Text(inlineError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            selectionActions
        }
    }

    @ViewBuilder
    private var contentToolbar: some View {
        HStack(spacing: 10) {
            if let person {
                TextField("이름", text: $renameText).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("이름 변경") {
                    inlineError = model.renamePerson(person.id, to: renameText)
                }
                Button("사진 보기") { model.showPhotos(for: person.id) }
                Picker("목록", selection: $tab) {
                    ForEach(PeopleTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer()
                Button("이름 삭제…", role: .destructive) { deletingPerson = person }
            } else {
                Text("미분류 얼굴").font(.headline)
                Spacer()
            }
        }
        .padding(14)
        .onAppear { renameText = person?.name ?? "" }
    }

    private var faceGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(displayedItems) { item in faceCard(item) }
                if displayedLimit < allItems.count {
                    Button("더 보기 (\(allItems.count - displayedLimit)개)") { displayedLimit += 100 }
                        .frame(minWidth: 150, minHeight: 160)
                }
            }.padding(16)
        }
    }

    private func faceCard(_ item: PeopleFaceItem) -> some View {
        let selected = selectedFaceIDs.contains(item.id)
        return VStack(spacing: 7) {
            if let image = NSImage(data: item.thumbnailJPEG) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 112, height: 112).clipped()
            } else {
                Image(systemName: "person.crop.square").font(.largeTitle).frame(width: 112, height: 112)
            }
            Text(item.fileName).font(.caption).lineLimit(1)
            Text(item.personName ?? "미분류").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Button("이 사진 열기") { model.openPeoplePhoto(item.photoID) }.font(.caption)
            if let selectedPersonID, tab == .candidates {
                HStack {
                    Button("맞아요") { model.assignFaces([item.id], to: selectedPersonID) }
                    Button("다른 사람") { model.rejectCandidate(item.id, for: selectedPersonID) }
                }.font(.caption)
            } else if item.personID != nil {
                HStack {
                    Menu("다른 이름") {
                        ForEach(model.sortedPeople) { target in
                            Button(target.name) { model.assignFaces([item.id], to: target.id) }
                        }
                    }
                    Button("분류 해제") { model.unassignFace(item.id) }
                }.font(.caption)
            }
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if item.personID == nil {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary).padding(7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.personID == nil else { return }
            if !selectedFaceIDs.insert(item.id).inserted { selectedFaceIDs.remove(item.id) }
        }
    }

    @ViewBuilder
    private var selectionActions: some View {
        if !selectedFaceIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedPersonID, tab == .candidates {
                    Button("선택한 얼굴 확인") {
                        model.assignFaces(selectedFaceIDs, to: selectedPersonID)
                        selectedFaceIDs.removeAll()
                    }.buttonStyle(.borderedProminent)
                } else if selectedPersonID == nil {
                    HStack {
                        TextField("새 사람 이름", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Button("새 사람으로 등록") {
                            inlineError = model.createPerson(named: newName, assigning: selectedFaceIDs)
                            if inlineError == nil { newName = ""; selectedFaceIDs.removeAll() }
                        }
                        Picker("기존 사람", selection: $existingPersonID) {
                            Text("선택").tag(UUID?.none)
                            ForEach(model.sortedPeople) { Text($0.name).tag(Optional($0.id)) }
                        }.frame(maxWidth: 180)
                        Button("선택한 얼굴에 적용") {
                            if let existingPersonID {
                                model.assignFaces(selectedFaceIDs, to: existingPersonID)
                                selectedFaceIDs.removeAll()
                            }
                        }.disabled(existingPersonID == nil)
                    }
                }
            }
            .padding(14).background(Color.white.opacity(0.035))
        }
    }

    private func empty(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "person.crop.square", description: Text(detail))
    }
}
