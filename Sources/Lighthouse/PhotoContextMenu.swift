import SwiftUI
import LighthouseCore

/// 사진 칸의 오른쪽 클릭 메뉴. 고른 사진 중 하나를 누르면 고른 사진 모두에(그리드), 고르지 않은 사진을 누르면
/// 그 사진만 골라 적용한다. 사진·비교·여러 장 보기에서는 누른 사진을 현재 사진으로 삼는다.
struct PhotoContextMenu: View {
    @EnvironmentObject private var model: LibraryModel
    let photo: PhotoAsset

    var body: some View {
        Menu("별점") {
            ForEach(0...5, id: \.self) { rating in
                Button(rating == 0 ? "별점 없음" : String(repeating: "★", count: rating)) { act { model.setRating(rating) } }
            }
        }
        Menu("표시") {
            Button("채택") { act { model.setFlag(.pick) } }
            Button("제외") { act { model.setFlag(.reject) } }
            Button("표시 해제") { act { model.setFlag(.none) } }
        }
        Menu("색상 라벨") {
            ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                Button(label.title) { act { model.setColorLabel(label) } }
            }
            Divider()
            Button("라벨 떼기") { act { model.setColorLabel(nil) } }
        }
        Menu("폴더에 추가") {
            ForEach(model.photoFolders) { folder in
                Button(folder.name) { act { model.addSelectedPhotos(to: folder.id) } }
            }
            if !model.photoFolders.isEmpty { Divider() }
            Button("새 폴더에 추가…") { act { model.presentCreateFolder() } }
        }
        .disabled(!model.foldersLoaded)
        Divider()
        Button("사진 보기에서 열기") { model.focusPhoto(photo); model.setMode(.edit) }
        Button("가상 사본 만들기") { focusOnly { model.createVirtualCopy() } }
        Button("Finder에서 원본 보기") { act { model.revealOriginals() } }
        Button("내보내기…") { act { model.showExport = true } }
            .disabled(model.isMissing(photo))
        Divider()
        Button("카탈로그에서 빼기…", role: .destructive) { act { model.requestRemoveFromCatalog() } }
    }

    private func act(_ action: () -> Void) {
        let usesSelection = model.mode == .grid && model.selectedPhotoIDs.contains(photo.id)
        if !usesSelection && photo.id != model.selectedID { model.focusPhoto(photo) }
        action()
    }

    /// 한 장에만 하는 일은 누른 사진을 현재 사진으로 삼는다.
    private func focusOnly(_ action: () -> Void) {
        if photo.id != model.selectedID { model.focusPhoto(photo) }
        action()
    }
}
