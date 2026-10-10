import SwiftUI
import LighthouseCore

/// 사진 보기 오른쪽의 얼굴 확대 줄(Lightroom Classic의 Faces 패널·Narrative Select의 Close-ups처럼). 사진 속 얼굴을 크게 모아
/// 감은 눈과 다른 얼굴보다 흐린 얼굴을 알리고, 누르면 그 얼굴을 100%로 본다. 판정은 참고용이라 확대 그림을 먼저 보인다.
struct FaceCloseupStrip: View {
    @EnvironmentObject private var model: LibraryModel
    let result: FaceCloseupResult

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("얼굴 \(result.faces.count)").font(.caption.weight(.semibold))
                    Spacer()
                    Button { model.showsFaceCloseups = false } label: {
                        Image(systemName: "xmark").frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("얼굴 확대 닫기 (보기 메뉴에서 다시 켭니다)")
                    .accessibilityLabel("얼굴 확대 닫기")
                }
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(result.faces.indices, id: \.self) { index in face(index) }
                    }
                }
                .scrollIndicators(.never)
                Text("눌러 100%로 보기").font(.caption2).foregroundStyle(Palette.muted)
            }
            .padding(10)
        }
        .frame(width: 136)
        .background(Palette.panel)
    }

    private func face(_ index: Int) -> some View {
        let eyesClosed = result.faces[index].eyesClosed == true
        let soft = result.softFaces.contains(index)
        return Button { model.showFace(index) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: result.crops[index]).resizable().interpolation(.high).scaledToFill()
                    .frame(width: 112, height: 112).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(eyesClosed || soft ? Palette.warning : Palette.hairline, lineWidth: eyesClosed || soft ? 1.5 : 1))
                if eyesClosed {
                    Label("눈 감음", systemImage: "eye.slash")
                }
                if soft {
                    Label("다른 얼굴보다 흐림", systemImage: "scope").fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption2).foregroundStyle(Palette.warning)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(soft ? "같은 사진에서 가장 선명한 얼굴보다 많이 흐립니다. 눌러 100%로 확인하세요" : "눌러 이 얼굴을 100%로 봅니다")
        .accessibilityLabel("얼굴 \(index + 1)" + (eyesClosed ? ", 눈 감음" : "") + (soft ? ", 다른 얼굴보다 흐림" : ""))
        .accessibilityHint("100%로 보기")
    }
}
