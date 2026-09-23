import AppKit
import SwiftUI
import LighthouseCore

struct InspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset

    private var edits: EditSettings { photo.edits }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("보정").font(.title3.weight(.semibold))
                        Spacer()
                        if photo.isRAW { Text("RAW").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                    }
                    Text(photo.filename).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ratingRow
                HStack(spacing: 8) {
                    flagButton("선택", icon: "checkmark", flag: .pick)
                    flagButton("제외", icon: "xmark", flag: .reject)
                    Button("해제") { model.setFlag(.none) }.accessibilityLabel("선택과 제외 표시 해제").disabled(photo.flag == .none)
                }.buttonStyle(.bordered)
                if model.selectedPhotoIDs.count >= 2 {
                    Text("슬라이더는 기준 사진에 적용됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("선택한 \(model.selectedPhotoIDs.count)장에 일괄 적용…") { model.showBatchEdit = true }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("선택한 사진에 보정 일괄 적용")
                }
                Divider()
                HStack(spacing: 0) {
                    panelButton("전체 보정", selected: model.adjustmentPanel == .global) { model.leaveLocalPanel() }
                    panelButton("부분 보정", selected: model.adjustmentPanel == .local) { model.enterLocalPanel() }
                    panelButton("복구", selected: model.adjustmentPanel == .retouch) { model.enterRetouchPanel() }
                }
                .padding(3).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                if model.adjustmentPanel == .global { globalControls }
                else if model.adjustmentPanel == .local { localControls }
                else { RetouchControls(photo: photo) }
                Divider()
                section("파일 정보")
                metadataRow("크기", "\(photo.metadata.width) × \(photo.metadata.height)")
                metadataRow("카메라", photo.metadata.camera)
                metadataRow("렌즈", photo.metadata.lens)
                metadataRow("ISO", photo.metadata.iso.map(String.init))
                metadataRow("조리개", photo.metadata.aperture.map { String(format: "f/%.1f", $0) })
                metadataRow("셔터", photo.metadata.shutter.map(shutterText))
                metadataRow("촬영", photo.metadata.capturedAt?.formatted(date: .abbreviated, time: .shortened))
                Text(photo.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Text("원본 보존 · 보정 자동 저장").font(.caption2.weight(.medium)).foregroundStyle(.orange)
            }
            .padding(18)
        }
        .background(Color(red: 0.145, green: 0.152, blue: 0.164))
    }

    private func panelButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(selected ? Color.orange.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var globalControls: some View {
        Group {
            HStack {
                section("LUT")
                Spacer()
                Text("보관 \(model.savedLUTs.count)개").font(.caption2).foregroundStyle(.secondary)
            }
            Button(".cube 추가…") { model.presentLUTImport() }
                .disabled(model.isLUTImporting || model.isLUTLibraryLoading)
                .accessibilityLabel("3D LUT 파일 보관 목록에 추가")
            Picker("보관한 LUT", selection: Binding(
                get: { edits.lut?.id ?? "" },
                set: { model.selectSavedLUT($0) }
            )) {
                Text("없음").tag("")
                ForEach(model.savedLUTs) { item in
                    Text(lutLabel(item)).tag(item.id).disabled(item.error != nil)
                }
                if let lut = edits.lut, !model.savedLUTs.contains(where: { $0.id == lut.id }) {
                    Text("\(lut.name) · 보관 파일 없음").tag(lut.id).disabled(true)
                }
            }
            .disabled(model.isLUTImporting || model.isLUTLibraryLoading)
            .accessibilityLabel("보관한 LUT 선택")
            if model.isLUTImporting { ProgressView("LUT 확인 중…").font(.caption) }
            if model.isLUTLibraryLoading { ProgressView("보관한 LUT 확인 중…").font(.caption) }
            if let error = model.lutLibraryError {
                Text("보관 목록 오류: \(error)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lut = edits.lut {
                Text(lut.name).font(.caption.weight(.medium)).lineLimit(2)
                    .accessibilityLabel("적용된 LUT: \(lut.name)")
                Toggle("LUT 사용", isOn: Binding(
                    get: { lut.isEnabled },
                    set: { enabled in model.updateLUT { $0.isEnabled = enabled } }
                )).font(.caption).accessibilityLabel("LUT 켜기 또는 끄기")
                localSlider("LUT 강도", value: lut.intensity * 100, range: 0...100, format: "%.0f%%") { percent in
                    model.updateLUT { $0.intensity = percent / 100 }
                }
                Button("LUT 제거") { model.removeLUT() }
                    .accessibilityLabel("현재 사진의 LUT 제거")
                if model.selectedPhotoIDs.count >= 2 {
                    Button("선택한 \(model.selectedPhotoIDs.count)장에 LUT 적용") { model.applyCurrentLUTToSelection() }
                        .disabled(model.isLUTImporting || model.isLUTLibraryLoading)
                        .accessibilityLabel("선택한 사진에 현재 LUT만 적용")
                }
            }
            if let error = model.lutError {
                Text("LUT 오류: \(error)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("사진용 SDR sRGB 3D .cube만 지원합니다. V-Log, .vlt, 1D LUT는 지원하지 않습니다.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("참조 사진 색감 맞추기…") { model.presentReferenceMatch() }
                .accessibilityLabel("참조 사진 색감 맞추기")
            Divider()
            section("빛")
            adjustment("노출", value: edits.exposure, range: -4...4, format: "%.2f EV") { $0.exposure = $1 }
            adjustment("대비", value: edits.contrast, range: 0.5...1.5, format: "%.2f") { $0.contrast = $1 }
            adjustment("하이라이트", value: edits.highlights, range: 0...1, format: "%.2f") { $0.highlights = $1 }
            adjustment("섀도", value: edits.shadows, range: 0...1, format: "%.2f") { $0.shadows = $1 }
            Divider()
            section("색상")
            adjustment("색온도 이동", value: edits.temperatureShift, range: -2500...2500, format: "%.0f K") { $0.temperatureShift = $1 }
            adjustment("틴트", value: edits.tintShift, range: -100...100, format: "%.0f") { $0.tintShift = $1 }
            adjustment("채도", value: edits.saturation, range: 0...2, format: "%.2f") { $0.saturation = $1 }
            AdvancedColorControls(edits: edits)
            Divider()
            section("디테일 및 구도")
            adjustment("선명도", value: edits.sharpness, range: 0...2, format: "%.2f") { $0.sharpness = $1 }
            HStack {
                Button {
                    change {
                        $0.rotationQuarterTurns = ($0.rotationQuarterTurns + 1) % 4
                        $0.cropRect = nil
                    }
                } label: { Label("90° 회전", systemImage: "rotate.right") }
                    .accessibilityLabel("시계 방향으로 90도 회전")
                Spacer()
                Button("자유 크롭…") { model.presentCrop() }
                    .accessibilityLabel("자유 크롭 및 수평 보정")
            }.buttonStyle(.bordered)
            if edits.cropRect != nil || edits.cropAspect != nil || edits.straightenDegrees != 0 {
                Text(String(format: "크롭 적용 · 수평 %+.1f°", edits.straightenDegrees))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("보정 초기화") { model.updateEdits(.neutral) }.disabled(!edits.isModified)
                Spacer()
                Button("복사") { model.copyEdits() }
                Button("다음에 붙여넣기") { model.pasteToNext() }.disabled(model.clipboard == nil || model.visiblePhotos.last?.id == photo.id)
            }.buttonStyle(.bordered)
        }
    }

    private func lutLabel(_ item: LUTLibraryItem) -> String {
        let duplicateName = model.savedLUTs.filter { $0.name == item.name }.count > 1
        return item.name + (duplicateName ? " · \(item.id.prefix(6))" : "") +
            (item.error == nil ? "" : " · 사용 불가")
    }

    private var localControls: some View {
        Group {
            HStack {
                Button("피사체 선택") { model.addAutomaticLocal(background: false) }
                    .accessibilityLabel("자동 피사체 마스크 만들기")
                Button("배경 선택") { model.addAutomaticLocal(background: true) }
                    .accessibilityLabel("자동 배경 마스크 만들기")
            }
            .disabled(model.isAutoMasking)
            if model.isAutoMasking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("기기에서 전경을 찾는 중…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("취소") { model.cancelAutoMask() }.accessibilityLabel("자동 마스크 선택 취소")
                }
            }
            if let error = model.autoMaskError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("자동 선택은 사람뿐 아니라 전경의 다른 물체도 포함할 수 있습니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                section("영역")
                Spacer()
                Button { model.addLocal() } label: { Label("영역 추가", systemImage: "plus") }
                    .accessibilityLabel("부분 보정 영역 추가")
            }
            if edits.localAdjustments.isEmpty {
                Text("영역을 추가한 뒤 사진 위를 드래그해 밝기와 대비를 조절할 곳을 칠하세요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(edits.localAdjustments) { area in
                    Button { model.chooseLocal(area.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: area.id == model.selectedLocalID ? "circle.inset.filled" : "circle")
                            Text(area.name).lineLimit(1)
                            Spacer()
                            if !area.isEnabled { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("영역 선택: \(area.name)")
                    .accessibilityAddTraits(area.id == model.selectedLocalID ? .isSelected : [])
                }
                if let area = model.selectedLocal {
                    Divider()
                    HStack {
                        TextField("영역 이름", text: Binding(
                            get: { area.name },
                            set: { name in model.updateLocal { $0.name = name } }
                        )).accessibilityLabel("영역 이름")
                        Toggle("활성", isOn: Binding(
                            get: { area.isEnabled },
                            set: { enabled in model.updateLocal { $0.isEnabled = enabled } }
                        )).labelsHidden().accessibilityLabel("영역 활성화")
                        Button(role: .destructive) { model.deleteLocal() } label: { Image(systemName: "trash") }
                            .accessibilityLabel("선택한 영역 삭제")
                    }
                    Toggle("마스크 반전", isOn: Binding(
                        get: { area.isInverted },
                        set: { inverted in model.updateLocal { $0.isInverted = inverted } }
                    ))
                    .font(.caption).accessibilityLabel("선택한 부분 보정 마스크 반전")
                    HStack {
                        toolButton(.brush, icon: "paintbrush.pointed")
                        toolButton(.eraser, icon: "eraser")
                    }
                    localSlider("브러시 크기", value: model.brushRadius * 200, range: 1...40, format: "%.0f%%") { model.brushRadius = $0 / 200 }
                    localSlider("경계 부드럽게", value: area.feather * 2000, range: 0...100, format: "%.0f") { percent in
                        model.updateLocal { $0.feather = percent / 2000 }
                    }
                    localSlider("영역 노출", value: area.exposure, range: -4...4, format: "%.2f EV") { exposure in
                        model.updateLocal { $0.exposure = exposure }
                    }
                    localSlider("영역 대비", value: area.contrast, range: 0.5...1.5, format: "%.2f") { contrast in
                        model.updateLocal { $0.contrast = contrast }
                    }
                    Toggle("마스크 표시", isOn: Binding(
                        get: { model.showsMask },
                        set: { model.showsMask = $0; model.requestMask() }
                    )).font(.caption).accessibilityLabel("부분 보정 마스크 표시")
                    Text(model.brushTool == .eraser ? "사진 위를 드래그해 칠한 영역을 지우세요." : "사진 위를 드래그해 영역을 칠하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    if area.baseMask != nil {
                        Text("자동 선택 결과를 브러시와 지우개로 다듬을 수 있습니다.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let error = model.maskError { Text("마스크 표시 오류: \(error)").font(.caption).foregroundStyle(.red) }
                    Button(model.isLocalEditing ? "그리기 완료" : "그리기 계속") {
                        if model.isLocalEditing { model.finishLocalDrawing() }
                        else { model.chooseLocal(area.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(model.isLocalEditing ? "부분 보정 그리기 완료" : "부분 보정 그리기 계속")
                }
            }
        }
    }

    private func toolButton(_ tool: BrushTool, icon: String) -> some View {
        Button { model.brushTool = tool; model.cancelDraft() } label: {
            Label(tool.rawValue, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(model.brushTool == tool ? .orange : .gray)
        .accessibilityLabel(tool.rawValue)
    }

    private func localSlider(_ title: String, value: Double, range: ClosedRange<Double>, format: String,
                             set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range).accessibilityLabel(title)
        }
    }

    private var ratingRow: some View {
        HStack(spacing: 3) {
            Text("별점").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ForEach(1...5, id: \.self) { n in
                Button { model.setRating(photo.rating == n ? 0 : n) } label: {
                    Image(systemName: n <= photo.rating ? "star.fill" : "star")
                        .foregroundStyle(n <= photo.rating ? .orange : .gray)
                }.buttonStyle(.plain).accessibilityLabel("별점 \(n)점")
            }
        }
    }

    private func flagButton(_ title: String, icon: String, flag: PhotoFlag) -> some View {
        Button { model.setFlag(flag) } label: { Label(title, systemImage: icon) }
            .tint(photo.flag == flag ? .orange : .gray)
            .accessibilityLabel("\(title) 표시")
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
    }

    private func adjustment(_ title: String, value: Double, range: ClosedRange<Double>, format: String, change: @escaping (inout EditSettings, Double) -> Void) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { value },
                set: { newValue in self.change { change(&$0, newValue) } }
            ), in: range)
            .accessibilityLabel(title)
        }
    }

    private func change(_ body: (inout EditSettings) -> Void) {
        var next = edits
        body(&next)
        model.updateEdits(next)
    }

    private func metadataRow(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Spacer(minLength: 4)
            Text(value ?? "—").multilineTextAlignment(.trailing)
        }.font(.caption)
    }

    private func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 1 { return "1/\(Int((1 / seconds).rounded()))초" }
        return String(format: "%.1f초", seconds)
    }
}
