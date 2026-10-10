import SwiftUI
import LighthouseCore

/// 별점 다섯 개. 고른 사진의 별점이 모두 같으면 그 값을, 다르면 빈 별을 보이고, 같은 별을 다시 누르면 뗀다.
struct MarkRatingStars: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        let rating = model.commonMarkRating
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { n in
                Button { model.toggleMarkRating(n) } label: {
                    Image(systemName: rating.map { n <= $0 } == true ? "star.fill" : "star")
                        .foregroundStyle(rating.map { n <= $0 } == true ? Palette.accent : Palette.muted)
                }
                .buttonStyle(.plain)
                .help("별점 \(n) (\(n))")
            }
        }
        // 음성 안내에서는 별 다섯 개 대신 하나의 조절 항목으로 읽고 위아래로 바꾼다.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("별점")
        .accessibilityValue(rating.map { $0 == 0 ? "없음" : "\($0)점" } ?? "여러 값")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.setRating(min(5, (rating ?? 0) + 1))
            case .decrement: model.setRating(max(0, (rating ?? 0) - 1))
            @unknown default: break
            }
        }
    }
}

/// 채택·제외·해제 단추. 고른 사진의 표시가 모두 같으면 그 단추를 강조색으로 보인다.
struct MarkFlagButtons: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        HStack(spacing: 8) {
            flagButton("채택", icon: "flag.fill", flag: .pick, key: "P")
            flagButton("제외", icon: "xmark", flag: .reject, key: "X")
            Button("해제") { model.setFlag(.none) }
                .help("채택·제외 표시 해제 (U)")
                .accessibilityLabel("채택·제외 표시 해제")
                .disabled(!model.canClearMarkFlags)
        }
        .buttonStyle(.bordered)
    }

    private func flagButton(_ title: String, icon: String, flag: PhotoFlag, key: String) -> some View {
        Button { model.setFlag(flag) } label: { Label(title, systemImage: icon) }
            .tint(model.commonMarkFlag == flag ? Palette.accent : .gray)
            .help("\(title) 표시 (\(key))")
            .accessibilityLabel("\(title) 표시")
    }
}

/// 그리드 아래 고르기 막대(Lightroom 라이브러리 아래 도구 막대처럼). 고른 사진 모두에 채택·제외·별점·라벨을 붙이며
/// P·X·U·1–5·6–9 키와 같다. 그리드의 오른쪽 패널은 보정에 쓴다.
struct CullingBar: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        // 좁은 창에서는 오른쪽 안내 글을 먼저 뺀다.
        ViewThatFits(in: .horizontal) {
            controls(showsStatus: true)
            controls(showsStatus: false)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 36)
        .background(Palette.panel)
        .disabled(model.markTargetPhotos.isEmpty)
    }

    private func controls(showsStatus: Bool) -> some View {
        HStack(spacing: 14) {
            MarkFlagButtons()
            separator
            MarkRatingStars()
            separator
            ColorLabelRow(current: model.commonMarkColorLabel, names: model.colorLabelNames,
                          choose: { model.toggleMarkColorLabel($0) }, rename: { model.showColorLabelNames = true })
                .fixedSize()
            Spacer(minLength: 12)
            if showsStatus {
                Text(status).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 18)
    }

    /// 몇 장에 붙는지, 아니면 같은 일을 하는 키를 알린다.
    private var status: String {
        let count = model.markTargetPhotos.count
        if count == 0 { return "사진을 고르면 별점·표시·라벨을 붙입니다" }
        if count == 1 { return "P 채택 · X 제외 · U 해제 · 1–5 별점 · 6–9 라벨" }
        return "고른 \(count)장에 함께 붙입니다" + (model.hasMixedMarks ? " · 값이 서로 다름" : "")
    }
}
