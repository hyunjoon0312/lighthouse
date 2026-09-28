import AppKit
import SwiftUI
import LighthouseCore

struct InspectorView: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset

    private var edits: EditSettings { photo.edits }

    private var missingOriginal: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("원본 파일을 찾을 수 없습니다", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(photo.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
            Text("드라이브를 연결하면 다시 확인합니다. 파일을 옮겼다면 새 위치를 알려 주세요. 같은 폴더에서 옮겨진 다른 사진도 함께 찾습니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("위치 다시 찾기…") { model.presentRelocate(for: photo) }.buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("보정").font(.title3.weight(.semibold))
                        Spacer()
                        if photo.isRAW { Text("RAW").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                        Button { model.createVirtualCopy() } label: { Image(systemName: "plus.square.on.square") }
                            .buttonStyle(.borderless)
                            .help("가상 사본 만들기 (⌘')  같은 원본에 다른 보정을 따로 저장합니다")
                            .accessibilityLabel("가상 사본 만들기")
                    }
                    Text(photo.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if model.isMissing(photo) { missingOriginal }
                HistogramView()
                ratingRow
                ColorLabelRow(current: model.commonMarkColorLabel) { model.toggleMarkColorLabel($0) }
                HStack(spacing: 8) {
                    flagButton("선택", icon: "flag.fill", flag: .pick)
                    flagButton("제외", icon: "xmark", flag: .reject)
                    Button("해제") { model.setFlag(.none) }
                        .accessibilityLabel("선택과 제외 표시 해제")
                        .disabled(!model.canClearMarkFlags)
                }.buttonStyle(.bordered)
                if model.markTargetPhotos.count > 1 {
                    Text("별점·표시·라벨은 선택한 \(model.markTargetPhotos.count)장에 함께 적용됩니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if model.hasMixedMarks {
                    Text("선택한 사진의 별점·표시·라벨 값이 서로 다릅니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                DescriptionFields(photo: photo)
                if model.selectedPhotoIDs.count >= 2 {
                    Text("슬라이더는 기준 사진에 적용됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("선택한 \(model.selectedPhotoIDs.count)장에 일괄 적용…") { model.showBatchEdit = true }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("선택한 사진에 보정 일괄 적용")
                }
                Divider()
                // 초기화·복사는 세 패널 모두에 걸치므로 패널 탭 위에 둔다.
                HStack {
                    Button("보정 초기화") { model.updateEdits(.neutral) }.disabled(!edits.isModified)
                        .help("크롭·부분 보정·복구·LUT까지 모두 처음 상태로 돌립니다. ⌘Z로 되돌립니다")
                    Spacer()
                    Button("복사") { model.copyEdits() }
                    Button("다음에 붙여넣기") { model.pasteToNext() }
                        .disabled(model.clipboard == nil || model.visiblePhotos.last?.id == photo.id)
                        .help("전체 보정과 LUT만 붙여넣습니다. 크롭·부분 보정·복구는 사진마다 달라 제외합니다.")
                }.buttonStyle(.bordered)
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
                EditHistoryPanel(photo: photo)
                Divider()
                section("파일 정보")
                metadataRow("크기", "\(photo.metadata.width) × \(photo.metadata.height)")
                metadataRow("카메라", photo.metadata.camera)
                metadataRow("렌즈", photo.metadata.lens)
                metadataRow("초점거리", photo.metadata.focalLength.map { $0.rounded() == $0 ? "\(Int($0)) mm" : String(format: "%.1f mm", $0) })
                metadataRow("ISO", photo.metadata.iso.map(String.init))
                metadataRow("조리개", photo.metadata.aperture.map { String(format: "f/%.1f", $0) })
                metadataRow("셔터", photo.metadata.shutter.map(PhotoMetadata.shutterText))
                metadataRow("촬영", photo.metadata.capturedAt?.formatted(date: .abbreviated, time: .shortened))
                if let record = photo.lastExport {
                    metadataRow("내보냄", record.exportedAt.formatted(date: .abbreviated, time: .shortened) +
                                (record.isChanged(photo) ? " · 그 뒤 보정 바뀜" : ""))
                        .help(record.path)
                }
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

    /// 자주 쓰는 빛·색상을 위에 두고, RAW 현상·프리셋·LUT는 그 아래에 둔다.
    private var globalControls: some View {
        Group {
            HStack {
                section("빛")
                Spacer()
                if model.isAutoAdjusting { ProgressView().controlSize(.small) }
                Button("자동") { model.autoAdjust() }
                    .font(.caption).buttonStyle(.bordered)
                    .disabled(model.isAutoAdjusting)
                    .help("노출·색온도·틴트·하이라이트·섀도를 사진에서 정합니다 (⌘U). ⌘Z로 되돌릴 수 있습니다")
                    .accessibilityLabel("자동 보정")
            }
            adjustment("노출", \.exposure, range: -4...4, format: "%.2f EV")
            adjustment("대비", \.contrast, range: 0.5...1.5, scale: 200)
            // 하이라이트는 1(그대로)에서 낮추기만, 섀도는 0에서 올리기만 한다.
            adjustment("하이라이트", \.highlights, range: 0...1, scale: 100)
            adjustment("섀도", \.shadows, range: 0...1, scale: 100)
            adjustment("명료도", \.clarity, range: -1...1, scale: 100)
            Divider()
            HStack {
                section("색상")
                Spacer()
                if model.isAutoAdjusting { ProgressView().controlSize(.small) }
                Button { model.beginWhiteBalancePick() } label: { Label("회색 찍기", systemImage: "eyedropper") }
                    .font(.caption).buttonStyle(.bordered)
                    .disabled(model.isAutoAdjusting || model.isMissing(photo))
                    .help("사진에서 회색·흰색이어야 할 곳을 눌러 색온도·틴트를 맞춥니다. Esc로 취소, ⌘Z로 되돌립니다")
                    .accessibilityLabel("흰색 기준 찍기")
            }
            adjustment("색온도 이동", \.temperatureShift, range: -2500...2500, format: "%.0f K")
            adjustment("틴트", \.tintShift, range: -100...100, scale: 1)
            adjustment("생동감", \.vibrance, range: -1...1, scale: 100)
            adjustment("채도", \.saturation, range: 0...2, scale: 100)
            AdvancedColorControls(edits: edits)
            Divider()
            section("디테일 및 구도")
            adjustment("선명도", \.sharpness, range: 0...2, scale: 50)
            NoiseReductionControls(edits: edits)
            adjustment("비네팅", \.vignette, range: -1...1, scale: 100)
            HStack {
                Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                    .help("왼쪽으로 90° 회전 (⌘[)")
                    .accessibilityLabel("반시계 방향으로 90도 회전")
                Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                    .help("오른쪽으로 90° 회전 (⌘])")
                    .accessibilityLabel("시계 방향으로 90도 회전")
                Spacer()
                Button("자유 크롭…") { model.presentCrop() }
                    .disabled(model.isMissing(photo))
                    .accessibilityLabel("자유 크롭 및 수평 보정")
            }.buttonStyle(.bordered)
            if edits.cropRect != nil || edits.cropAspect != nil || edits.straightenDegrees != 0 {
                Text(String(format: "크롭 적용 · 수평 %+.1f°", edits.straightenDegrees))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if photo.isRAW { rawDevelopControls }
            Divider()
            presetControls
            Divider()
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
                localSlider("LUT 강도", value: lut.intensity * 100, range: 0...100, format: "%.0f%%", defaultValue: 100) { percent in
                    model.updateLUT(continuous: true) { $0.intensity = percent / 100 }
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
        }
    }

    @ViewBuilder private var presetControls: some View {
        HStack {
            section("프리셋")
            Spacer()
            Button("현재 보정 저장…") {
                model.presetSheet = PresetSheetRequest(kind: .save, initialName: "")
            }
            .font(.caption).buttonStyle(.borderless)
            .disabled(model.presetLoadError != nil)
            .accessibilityLabel("현재 보정을 프리셋으로 저장")
        }
        if let error = model.presetLoadError {
            Text("프리셋 파일 오류: \(error)").font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.presets.isEmpty {
            Text("자주 쓰는 보정을 저장해 두면 다른 사진이나 가져오는 사진에 한 번에 적용할 수 있습니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(model.presets) { preset in
                HStack {
                    Button(preset.name) { model.applyPreset(preset) }
                        .buttonStyle(.borderless).lineLimit(1)
                        .help(model.selectedPhotoIDs.count >= 2 ? "선택한 \(model.selectedPhotoIDs.count)장에 적용" : "현재 사진에 적용")
                        .accessibilityLabel("프리셋 \(preset.name) 적용")
                    Spacer()
                    Menu {
                        Button("이름 변경…") {
                            model.presetSheet = PresetSheetRequest(kind: .rename(preset.id), initialName: preset.name)
                        }
                        Button("삭제", role: .destructive) { model.deletePreset(preset.id) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24)
                    .accessibilityLabel("\(preset.name) 관리")
                }
                .font(.caption)
            }
            Picker("가져올 때 적용", selection: $model.importPresetID) {
                Text("없음").tag(UUID?.none)
                ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
            }
            .font(.caption)
            .accessibilityLabel("가져오는 사진에 자동으로 적용할 프리셋")
        }
    }

    @ViewBuilder private var rawDevelopControls: some View {
        Divider()
        HStack {
            section("RAW 현상")
            Spacer()
            if edits.rawDevelop != RAWDevelopSettings() {
                Button("자동으로") { change { $0.rawDevelop = RAWDevelopSettings() } }
                    .font(.caption).buttonStyle(.borderless)
                    .accessibilityLabel("RAW 현상 설정을 카메라 기본값으로")
            }
        }
        if let capabilities = model.rawCapabilities {
            if let automatic = capabilities.luminanceNoiseReduction {
                rawSlider("노이즈 감소", \.rawDevelop.luminanceNoiseReduction, automatic: automatic)
            }
            if let automatic = capabilities.colorNoiseReduction {
                rawSlider("색 노이즈 감소", \.rawDevelop.colorNoiseReduction, automatic: automatic)
            }
            if let automatic = capabilities.lensCorrection {
                Toggle("렌즈 보정 (왜곡·주변부)", isOn: Binding(
                    get: { edits.rawDevelop.lensCorrection ?? automatic },
                    set: { enabled in change { $0.rawDevelop.lensCorrection = enabled } }
                )).font(.caption).accessibilityLabel("렌즈 보정")
            }
            if let automatic = capabilities.highlightRecovery {
                Toggle("하이라이트 복구", isOn: Binding(
                    get: { edits.rawDevelop.highlightRecovery ?? automatic },
                    set: { enabled in change { $0.rawDevelop.highlightRecovery = enabled } }
                )).font(.caption).accessibilityLabel("하이라이트 복구")
            }
            SliderRow(title: "HDR 하이라이트", value: edits.hdrAmount, range: 0...2,
                      valueText: edits.hdrAmount == 0 ? "끔" : String(format: "%.1f", edits.hdrAmount),
                      set: { value in change(continuous: true) { $0.hdrAmount = value < 0.05 ? 0 : value } },
                      end: { model.endContinuousEdit() },
                      reset: { change { $0.hdrAmount = 0 } })
            if edits.hdrAmount > 0 {
                Text(LibraryModel.hdrDisplayAvailable
                     ? "SDR 흰색을 넘는 밝은 부분이 HDR 화면에서 더 밝게 보입니다. 노출을 올릴수록 커지며, HEIF·JPEG로 내보내면 게인 맵이 들어갑니다."
                     : "이 화면은 HDR을 표시하지 못해 SDR로 보입니다. HEIF·JPEG로 내보내면 게인 맵이 들어가 HDR 화면에서 밝게 보입니다.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if capabilities == RAWCapabilities(luminanceNoiseReduction: nil, colorNoiseReduction: nil,
                                               lensCorrection: nil, highlightRecovery: nil) {
                Text("이 RAW는 macOS 디코더에서 조절할 수 있는 현상 항목이 없습니다.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// 두 번 누르면 카메라 기본값(자동)으로 돌아간다.
    private func rawSlider(_ title: String, _ keyPath: WritableKeyPath<EditSettings, Double?>,
                           automatic: Double) -> some View {
        let value = edits[keyPath: keyPath]
        let shown = value ?? automatic
        return SliderRow(title: title, value: shown, range: 0...1,
                         valueText: value == nil ? "자동 \(Int((shown * 100).rounded()))%" : "\(Int((shown * 100).rounded()))%",
                         set: { newValue in change(continuous: true) { $0[keyPath: keyPath] = newValue } },
                         end: { model.endContinuousEdit() },
                         reset: { change { $0[keyPath: keyPath] = nil } })
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
                Button { model.addLocal() } label: { Label("브러시", systemImage: "plus") }
                    .accessibilityLabel("브러시 부분 보정 영역 추가")
            }
            HStack {
                Button { model.addGradientLocal(radial: false) } label: {
                    Label("직선 그라데이션", systemImage: "square.bottomhalf.filled").frame(maxWidth: .infinity)
                }
                .accessibilityLabel("직선 그라데이션 영역 추가")
                Button { model.addGradientLocal(radial: true) } label: {
                    Label("원형 그라데이션", systemImage: "circle.dotted.circle").frame(maxWidth: .infinity)
                }
                .accessibilityLabel("원형 그라데이션 영역 추가")
            }
            .font(.caption)
            if edits.localAdjustments.isEmpty {
                Text("브러시 영역은 사진 위를 드래그해 칠하고, 그라데이션은 조절점을 끌어 위치를 정합니다.")
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
                            set: { name in model.updateLocal(continuous: true) { $0.name = name } }
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
                    localSlider("브러시 크기", value: model.brushRadius * 200, range: 1...40, format: "%.0f%%",
                                defaultValue: 8) { model.brushRadius = $0 / 200 }
                    localSlider("경계 부드럽게", value: area.feather * 2000, range: 0...100, format: "%.0f",
                                defaultValue: 20) { percent in
                        model.updateLocal(continuous: true) { $0.feather = percent / 2000 }
                    }
                    localSlider("영역 노출", value: area.exposure, range: -4...4, format: "%.2f EV", defaultValue: 0) { exposure in
                        model.updateLocal(continuous: true) { $0.exposure = exposure }
                    }
                    localSlider("영역 대비", value: area.contrast, range: 0.5...1.5, format: "%.2f", defaultValue: 1) { contrast in
                        model.updateLocal(continuous: true) { $0.contrast = contrast }
                    }
                    localSlider("영역 색온도", value: area.temperature * 100, range: -100...100, format: "%.0f",
                                defaultValue: 0) { value in
                        model.updateLocal(continuous: true) { $0.temperature = value / 100 }
                    }
                    localSlider("영역 채도", value: area.saturation * 100, range: -100...100, format: "%.0f",
                                defaultValue: 0) { value in
                        model.updateLocal(continuous: true) { $0.saturation = value / 100 }
                    }
                    localSlider("영역 명료도", value: area.clarity * 100, range: -100...100, format: "%.0f",
                                defaultValue: 0) { value in
                        model.updateLocal(continuous: true) { $0.clarity = value / 100 }
                    }
                    if let softness = area.gradient?.softness {
                        localSlider("원형 가장자리 부드럽게", value: softness * 100, range: 0...100, format: "%.0f",
                                    defaultValue: 50) { value in
                            model.updateLocal(continuous: true) { $0.gradient = $0.gradient?.withSoftness(value / 100) }
                        }
                    }
                    Toggle("마스크 표시", isOn: Binding(
                        get: { model.showsMask },
                        set: { model.showsMask = $0; model.requestMask() }
                    )).font(.caption).accessibilityLabel("부분 보정 마스크 표시")
                    if area.gradient != nil && !model.isLocalEditing {
                        Text("사진 위 조절점을 끌어 위치와 크기를 바꾸세요. 주황색 점은 전체를 옮깁니다. 그리기를 계속하면 브러시로 더하거나 지울 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(model.brushTool == .eraser ? "사진 위를 드래그해 칠한 영역을 지우세요." : "사진 위를 드래그해 영역을 칠하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if area.baseMask != nil {
                        Text("자동 선택 결과를 브러시와 지우개로 다듬을 수 있습니다.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let error = model.maskError { Text("마스크 표시 오류: \(error)").font(.caption).foregroundStyle(.red) }
                    let drawTitle = model.isLocalEditing ? "그리기 완료" : (area.gradient == nil ? "그리기 계속" : "브러시로 다듬기")
                    Button(drawTitle) {
                        if model.isLocalEditing { model.finishLocalDrawing() }
                        else { model.chooseLocal(area.id, drawing: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("부분 보정 " + drawTitle)
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

    /// `defaultValue`가 있으면 두 번 눌러 그 값으로 돌린다.
    private func localSlider(_ title: String, value: Double, range: ClosedRange<Double>, format: String,
                             defaultValue: Double? = nil, set: @escaping @MainActor (Double) -> Void) -> some View {
        var reset: (@MainActor () -> Void)?
        if let defaultValue { reset = { set(defaultValue); model.endContinuousEdit() } }
        return SliderRow(title: title, value: value, range: range, valueText: String(format: format, value),
                         set: { set($0) }, end: { model.endContinuousEdit() }, reset: reset)
    }

    private var ratingRow: some View {
        let rating = model.commonMarkRating
        return HStack(spacing: 3) {
            Text("별점").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ForEach(1...5, id: \.self) { n in
                Button { model.toggleMarkRating(n) } label: {
                    Image(systemName: rating.map { n <= $0 } == true ? "star.fill" : "star")
                        .foregroundStyle(rating.map { n <= $0 } == true ? .orange : .gray)
                }.buttonStyle(.plain).accessibilityLabel("별점 \(n)점")
            }
        }
    }

    private func flagButton(_ title: String, icon: String, flag: PhotoFlag) -> some View {
        Button { model.setFlag(flag) } label: { Label(title, systemImage: icon) }
            .tint(model.commonMarkFlag == flag ? .orange : .gray)
            .accessibilityLabel("\(title) 표시")
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
    }

    /// 두 번 누르면 보정하지 않은 값으로 돌아간다.
    private func adjustment(_ title: String, _ keyPath: WritableKeyPath<EditSettings, Double>,
                            range: ClosedRange<Double>, format: String) -> some View {
        adjustment(title, keyPath, range: range) { String(format: format, $0) }
    }

    /// 값을 보정하지 않은 값과의 차이에 `scale`을 곱한 정수(0, +35, -20)로 보인다.
    private func adjustment(_ title: String, _ keyPath: WritableKeyPath<EditSettings, Double>,
                            range: ClosedRange<Double>, scale: Double) -> some View {
        let neutral = EditSettings.neutral[keyPath: keyPath]
        return adjustment(title, keyPath, range: range) { value in
            let amount = ((value - neutral) * scale).rounded()
            return amount == 0 ? "0" : String(format: "%+.0f", amount)
        }
    }

    private func adjustment(_ title: String, _ keyPath: WritableKeyPath<EditSettings, Double>,
                            range: ClosedRange<Double>, text: (Double) -> String) -> some View {
        let value = edits[keyPath: keyPath]
        return SliderRow(title: title, value: value, range: range, valueText: text(value),
                         set: { newValue in change(continuous: true) { $0[keyPath: keyPath] = newValue } },
                         end: { model.endContinuousEdit() },
                         reset: { change { $0[keyPath: keyPath] = EditSettings.neutral[keyPath: keyPath] } })
    }

    private func change(continuous: Bool = false, _ body: (inout EditSettings) -> Void) {
        var next = edits
        body(&next)
        model.updateEdits(next, continuous: continuous)
    }

    private func metadataRow(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Spacer(minLength: 4)
            Text(value ?? "—").multilineTextAlignment(.trailing)
        }.font(.caption)
    }

}

/// 키워드와 설명. 입력을 시작한 사진에 적용하므로 입력 중 다른 사진을 골라도 섞이지 않는다.
private struct DescriptionFields: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset
    @State private var keywordText = ""
    @State private var captionText = ""
    @State private var addText = ""
    @State private var editingID: UUID?
    @FocusState private var focus: Field?

    private enum Field { case keywords, caption, add }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("키워드 (쉼표로 구분)", text: $keywordText)
                .focused($focus, equals: .keywords)
                .onSubmit { commit(.keywords) }
                .accessibilityLabel("키워드")
            TextField("설명", text: $captionText, axis: .vertical)
                .lineLimit(1...4)
                .focused($focus, equals: .caption)
                .onSubmit { commit(.caption) }
                .accessibilityLabel("설명")
            if model.selectedPhotoIDs.count >= 2 {
                HStack {
                    TextField("선택한 \(model.selectedPhotoIDs.count)장에 키워드 추가", text: $addText)
                        .focused($focus, equals: .add)
                        .onSubmit(addToSelection)
                    Button("추가", action: addToSelection).disabled(PhotoKeywords.parse(addText).isEmpty)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.caption)
        .onAppear(perform: load)
        .onChange(of: photo.id) { _, _ in
            // 입력 중에 다른 사진을 고르면 입력을 시작한 사진에 먼저 저장한다.
            if let field = focus, field != .add { commit(field) }
            load()
        }
        // 실행 취소 등으로 값이 바뀌면 따라간다. 입력 중이라도 저장하지 않은 글자가 없으면 따라가서,
        // 나중에 칸을 떠날 때 옛 글자를 다시 저장해 실행 취소를 되돌리지 않게 한다.
        .onChange(of: photo.keywords) { old, new in
            if focus != .keywords || PhotoKeywords.parse(keywordText) == old { keywordText = PhotoKeywords.text(new) }
        }
        .onChange(of: photo.caption) { old, new in
            if focus != .caption || captionText.trimmingCharacters(in: .whitespacesAndNewlines) == old { captionText = new }
        }
        .onChange(of: focus) { old, new in
            if let old, old != .add { commit(old) }
            if new == .keywords || new == .caption { editingID = photo.id }
        }
    }

    private func load() {
        keywordText = PhotoKeywords.text(photo.keywords)
        captionText = photo.caption
        editingID = focus == nil ? nil : photo.id
    }

    private func commit(_ field: Field) {
        let id = editingID ?? photo.id
        switch field {
        case .keywords: model.setKeywords(keywordText, for: id)
        case .caption: model.setCaption(captionText, for: id)
        case .add: break
        }
        if id == photo.id {
            keywordText = PhotoKeywords.text(model.photo(withID: id)?.keywords ?? [])
        }
    }

    private func addToSelection() {
        model.addKeywordsToSelection(addText)
        addText = ""
    }
}
