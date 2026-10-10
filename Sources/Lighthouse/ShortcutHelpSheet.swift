import SwiftUI

/// 앱 안의 단축키 안내. README의 단축키 표와 같은 목록이며, 테스트가 두 목록의 키를 비교한다.
enum ShortcutGuide {
    struct Entry: Identifiable {
        let keys: String
        let action: String
        var id: String { keys }
    }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "가져오기·선택", entries: [
            Entry(keys: "⌘O", action: "사진·폴더 가져오기"),
            Entry(keys: "⇧⌘O", action: "카드에서 복사해 가져오기"),
            Entry(keys: "⌘A", action: "보이는 사진 전체 선택"),
            Entry(keys: "⌘클릭 / ⇧클릭", action: "개별 선택 추가·해제 / 범위 선택"),
            Entry(keys: "⇧+화살표", action: "그리드에서 선택 넓히기"),
        ]),
        Section(title: "이동·보기", entries: [
            Entry(keys: "← / →", action: "이전 / 다음 사진"),
            Entry(keys: "↑ / ↓", action: "그리드에서 위 / 아래 줄"),
            Entry(keys: "G / E / C / N", action: "그리드 / 사진 / 비교 / 여러 장 보기(선택한 사진을 한 화면에)"),
            Entry(keys: "\\", action: "원본 보기 전환"),
            Entry(keys: "Y", action: "보정 전·후 나눠 보기 (선을 끌어 옮기기)"),
            Entry(keys: "J", action: "하이라이트·섀도 잘림 표시"),
            Entry(keys: "Z", action: "100% 보기 전환 (가운데 기준)"),
            Entry(keys: "F / Esc", action: "사진만 크게 보기(패널을 숨기고 전체 화면) / 끝내기"),
            Entry(keys: "⌃⌘S / ⌥⌘I", action: "왼쪽 사이드바 / 오른쪽 보정 패널 가리기·보기"),
        ]),
        Section(title: "표시", entries: [
            Entry(keys: "0–5", action: "별점 설정 (그리드에서 여러 장을 골랐으면 모두에)"),
            Entry(keys: "P / X / U", action: "채택 / 제외 / 표시 해제 (그리드에서 여러 장을 골랐으면 모두에)"),
            Entry(keys: "6–9", action: "색상 라벨 빨강 / 노랑 / 초록 / 파랑 (같은 키를 다시 누르면 떼기)"),
            Entry(keys: "Delete", action: "카탈로그에서 빼기(확인 후, 원본 파일은 그대로, ⌘Z로 되돌리기) · 내 폴더에서는 그 폴더에서만 빼기"),
        ]),
        Section(title: "보정·내보내기", entries: [
            Entry(keys: "⌘Z / ⇧⌘Z", action: "실행 취소 / 다시 실행 (보정·별점·표시)"),
            Entry(keys: "⌘U", action: "자동 보정 (노출·색온도·틴트·하이라이트·섀도)"),
            Entry(keys: "W", action: "회색 찍기 (누른 곳을 흰색 기준으로 색온도·틴트 맞추기, Esc 취소)"),
            Entry(keys: "R", action: "자유 크롭·수평"),
            Entry(keys: "⇧⌘C / ⇧⌘V", action: "보정 복사 / 선택한 사진에 전체 보정·LUT 붙여넣기(한 번에 실행 취소)"),
            Entry(keys: "⌘[ / ⌘]", action: "왼쪽 / 오른쪽으로 90° 회전"),
            Entry(keys: "⌘'", action: "가상 사본 만들기"),
            Entry(keys: "⌘R", action: "Finder에서 원본 보기"),
            Entry(keys: "⇧⌘E", action: "내보내기"),
            Entry(keys: "? / ⌘/", action: "단축키 보기"),
        ]),
    ]
}

struct ShortcutHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("단축키").font(.title2.weight(.semibold))
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("한글 입력 상태에서도 같은 자리의 키로 동작합니다. 글자 칸에 입력하는 동안에는 한 글자 단축키가 동작하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ShortcutGuide.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            ForEach(section.entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(entry.keys).font(.body.monospaced()).frame(width: 130, alignment: .leading)
                                    Text(entry.action).fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 560)
    }
}
