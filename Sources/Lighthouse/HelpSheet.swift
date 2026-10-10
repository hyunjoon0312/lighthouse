import SwiftUI

/// 앱 안 도움말. README의 사용 흐름을 주제별 짧은 항목으로 옮긴 것이다. 메뉴 경로는 `menus`에 따로 적어
/// 실제 메뉴 이름과 같은지 테스트가 본다.
enum HelpGuide {
    struct Item: Identifiable, Hashable {
        let title: String
        let body: String
        /// 이 일을 하는 메뉴(예: "사진 › 위치 다시 찾기…").
        var menus: [String] = []
        var id: String { title }
    }

    struct Topic: Identifiable, Hashable {
        let title: String
        let icon: String
        let summary: String
        let items: [Item]
        var id: String { title }
    }

    static let topics: [Topic] = [
        Topic(title: "시작하기", icon: "photo.on.rectangle.angled",
              summary: "사진을 가져오고, 고르기 → 보정 → 내보내기로 이어지는 흐름을 봅니다.", items: [
            Item(title: "사진 가져오기",
                 body: "사진이나 폴더를 고르거나 Finder에서 창으로 끌어 놓습니다(⌘O). 하위 폴더까지 찾고, 이미 가져온 사진은 다시 넣지 않습니다. JPEG·HEIC·PNG·TIFF와 RAW(RW2 등)를 지원합니다.",
                 menus: ["파일 › 사진 가져오기…"]),
            Item(title: "메모리 카드에서 복사",
                 body: "카드의 사진을 사진 폴더(기본 ~/Pictures/Lighthouse/연도/연-월-일, 바꿀 수 있음)로 복사한 뒤 가져옵니다(⇧⌘O). 카드를 빼도 계속 편집할 수 있고, 같은 카드를 다시 가져오면 이미 복사한 사진은 건너뜁니다.",
                 menus: ["파일 › 카드에서 복사해 가져오기…"]),
            Item(title: "원본은 그대로",
                 body: "Lighthouse는 원본 파일을 바꾸거나 지우거나 옮기지 않습니다. 별점·보정은 라이브러리에 저장되고, 내보내기는 언제나 새 파일을 만듭니다."),
            Item(title: "보기 바꾸기",
                 body: "위쪽 단추나 키로 그리드(G)·사진(E)·비교(C)·여러 장 보기(N)를 오갑니다. F는 패널을 숨기고 사진만 크게 보며 Esc로 끝냅니다. ⌃⌘S·⌥⌘I로 사이드바와 오른쪽 패널을 가립니다."),
        ]),
        Topic(title: "고르기", icon: "flag",
              summary: "별점·채택·라벨을 붙여 좋은 컷을 고릅니다.", items: [
            Item(title: "고르기 막대",
                 body: "사진 아래 막대에서 채택·제외·해제, 별점, 색상 라벨을 붙입니다. 키로는 P 채택, X 제외, U 해제, 0–5 별점, 6–9 라벨(빨강·노랑·초록·파랑)이고 보라는 막대나 메뉴로 붙입니다. 막대에서 같은 별이나 라벨을 다시 누르면 뗍니다."),
            Item(title: "여러 장에 한 번에",
                 body: "그리드에서 ⌘클릭·⇧클릭으로 여러 장을 고르면 막대·키·오른쪽 클릭 메뉴의 표시가 고른 사진 모두에 붙고, ⌘Z 한 번에 되돌아갑니다. 사진·비교·여러 장 보기에서는 보고 있는 한 장에만 붙습니다."),
            Item(title: "표시 후 다음 사진",
                 body: "위쪽 선택 줄의 표시 후 다음 사진을 켜면 키로 표시할 때마다 다음 사진으로 넘어갑니다. 좁은 창에서는 옵션 메뉴 안에 있습니다."),
            Item(title: "라벨 이름",
                 body: "빨강 → 블로그처럼 라벨마다 쓰임을 붙이면 고르기 막대·메뉴·조건에 이름이 함께 보입니다. 막대의 라벨을 오른쪽 클릭해도 정할 수 있습니다.",
                 menus: ["사진 › 색상 라벨 › 라벨 이름 정하기…"]),
            Item(title: "연속 촬영",
                 body: "왼쪽의 연속 촬영은 1초 안에 이어 찍은 컷을 묶어 보여 줍니다. 베스트 컷 분석을 누르면 선명도와 얼굴 품질로 묶음마다 추천 컷을 고릅니다."),
            Item(title: "얼굴 확대",
                 body: "사진 보기 오른쪽에 사진 속 얼굴을 크게 모아, 두 눈을 감은 얼굴과 다른 얼굴보다 많이 흐린 얼굴을 알립니다. 얼굴을 누르면 그 얼굴을 100%로 봅니다. 판정은 참고용이니 확대해 확인하세요.",
                 menus: ["보기 › 얼굴 확대 보기"]),
            Item(title: "비교와 여러 장 보기",
                 body: "비교(C)는 왼쪽 기준 사진과 현재 사진을 나란히 놓고, 더 나은 쪽을 이 사진을 기준으로로 옮겨 다음 사진과 이어 비교합니다. 여러 장 보기(N)는 고른 사진을 최대 12장 한 화면에 놓고 ×로 빼 나갑니다."),
        ]),
        Topic(title: "찾기·정리", icon: "magnifyingglass",
              summary: "검색·조건·폴더로 사진을 찾고 묶습니다.", items: [
            Item(title: "검색과 별점 거르기",
                 body: "위쪽 검색창은 파일 이름·키워드·설명·사람 이름으로 찾고, 별점 메뉴는 그 별점 이상만 보입니다. 선택 줄의 전체 표시·채택·미분류·제외로 표시에 따라 거릅니다."),
            Item(title: "조건과 스마트 폴더",
                 body: "조건 단추로 카메라·렌즈·초점거리·ISO·촬영일·표시·라벨을 걸어 거르고, 그 조건을 스마트 폴더로 저장하면 맞는 사진이 저절로 모입니다."),
            Item(title: "내 폴더",
                 body: "왼쪽 내 폴더의 +로 폴더를 만들고 그리드의 사진을 끌어 넣습니다. 원본 파일은 옮기지 않고 Lighthouse 안에서만 묶습니다. 원본 위치에서는 사진이 든 실제 폴더별로 봅니다."),
            Item(title: "키워드와 설명",
                 body: "오른쪽 패널의 키워드(쉼표로 구분)와 설명은 검색에 쓰이고 JPEG로 내보낼 때 IPTC로 들어갑니다. 여러 장을 골랐으면 선택한 N장에 키워드 추가로 한 번에 붙입니다."),
            Item(title: "사람",
                 body: "사진 속 얼굴을 찾아 이름을 붙이면 이름으로 찾을 수 있습니다. 분석은 이 Mac 안에서만 합니다.",
                 menus: ["사진 › 얼굴 찾기 · 관리…"]),
            Item(title: "중복·유사 사진",
                 body: "비슷한 사진을 묶어 나란히 비교하게 합니다. 자동으로 지우지 않습니다.",
                 menus: ["사진 › 중복·유사 사진 찾기…"]),
            Item(title: "카탈로그에서 빼기",
                 body: "Delete는 확인한 뒤 사진을 Lighthouse 목록에서만 뺍니다. 원본 파일은 그대로이고 ⌘Z로 되돌릴 수 있습니다. 내 폴더를 보고 있으면 그 폴더에서만 뺍니다.",
                 menus: ["사진 › 카탈로그에서 빼기…"]),
        ]),
        Topic(title: "보정", icon: "slider.horizontal.3",
              summary: "사진 보기(E)의 오른쪽 패널에서 보정합니다. 원본은 바뀌지 않습니다.", items: [
            Item(title: "자동 보정과 슬라이더",
                 body: "자동(⌘U)으로 노출·색온도·틴트·하이라이트·섀도의 출발점을 잡고 슬라이더로 다듬습니다. 슬라이더 이름이나 값을 두 번 누르면 그 항목만 기본값으로 돌아갑니다."),
            Item(title: "히스토그램 끌기",
                 body: "오른쪽 패널 위 히스토그램을 좌우로 끌면 포인터 아래 구간(검정·섀도·노출·하이라이트·흰색)의 값이 바뀝니다. 구간을 두 번 누르면 그 값만 기본으로 돌아갑니다."),
            Item(title: "회색 찍기",
                 body: "회색 찍기(W)를 누른 뒤 사진에서 회색·흰색이어야 할 곳을 누르면 그곳이 중립이 되게 색온도·틴트를 맞춥니다. Esc로 취소합니다.",
                 menus: ["사진 › 회색 찍기"]),
            Item(title: "보정 묶음",
                 body: "묶음 제목을 눌러 펴고 접습니다. 점이 붙은 묶음은 기본값에서 바뀐 것입니다. 제목을 오른쪽 클릭하면 그 묶음만 초기화하거나 한 묶음만 펴기를 켭니다."),
            Item(title: "보정 전후 보기",
                 body: "Y는 한 장을 선으로 나눠 보정 전·후를 보이고, \\ 키는 원본과 번갈아 보입니다. Z는 100% 보기, J는 하이라이트·섀도 잘림 표시입니다."),
            Item(title: "부분 보정과 복구",
                 body: "부분 보정에서 피사체·배경 자동 선택, 브러시, 직선·원형 그라데이션으로 일부만 조절합니다. 복구에서는 작은 잡티를 지우거나 소스를 골라 복제합니다."),
            Item(title: "크롭과 회전",
                 body: "자유 크롭(R)으로 구도와 수평을 맞추고, ⌘[ · ⌘]로 90°씩 돌립니다.",
                 menus: ["사진 › 자유 크롭…"]),
            Item(title: "프리셋·LUT·참조 색감",
                 body: "전체 보정의 프리셋에서 지금 보정을 저장해 다른 사진에 적용하고, .cube LUT를 보관해 골라 씁니다. 참조 사진 색감 맞추기는 원하는 사진의 톤·색 분포를 근사합니다.",
                 menus: ["파일 › LUT 추가…", "파일 › Lightroom 프리셋 가져오기…", "파일 › 참조 사진 색감 맞추기…"]),
            Item(title: "여러 장에 같은 보정",
                 body: "보정을 복사(⇧⌘C)해 고른 사진에 붙여 넣거나(⇧⌘V), 선택 줄의 일괄 적용…에서 범위를 골라 한 번에 적용합니다. 붙여넣기는 한 번에 실행 취소됩니다.",
                 menus: ["편집 › 보정 복사", "편집 › 보정 붙여넣기"]),
            Item(title: "스냅숏과 가상 사본",
                 body: "오른쪽 패널의 스냅숏 · 보정 기록에 지금 상태를 이름 붙여 두면 언제든 돌아갈 수 있습니다. 같은 사진을 다르게 보정하려면 가상 사본(⌘')을 만듭니다.",
                 menus: ["사진 › 가상 사본 만들기"]),
            Item(title: "노이즈 감소",
                 body: "디테일 묶음에서 노이즈 감소를 일반이나 AI로 켭니다. AI 모델은 앱에 들어 있어 Mac 안에서 실행합니다."),
        ]),
        Topic(title: "내보내기", icon: "square.and.arrow.up",
              summary: "보정을 적용한 새 파일을 만듭니다. 원본은 덮어쓰지 않습니다.", items: [
            Item(title: "파일로 내보내기",
                 body: "형식(JPEG·HEIF·TIFF)·크기·품질·파일 이름 규칙·저장 폴더를 정해 새 파일로 저장합니다(⇧⌘E).",
                 menus: ["파일 › 내보내기…"]),
            Item(title: "바뀐 사진 다시 내보내기",
                 body: "내보낸 뒤 보정이 바뀐 사진을 지난번과 같은 설정·폴더·이름으로 다시 내보냅니다. 이전 파일은 Lighthouse가 쓴 그대로일 때만 휴지통으로 옮길 수 있습니다.",
                 menus: ["파일 › 바뀐 사진 다시 내보내기…"]),
            Item(title: "Google Drive로 업로드",
                 body: "내보내기 창에서 Google Drive 계정을 연결하고 Drive로 업로드를 누르면 올립니다. 직접 누를 때만 올리고 자동으로 동기화하지 않습니다. 올리는 동안 사진 아래 줄에 진행이 보입니다."),
            Item(title: "HDR로 저장",
                 body: "RAW에 HDR 하이라이트를 켠 사진은 JPEG·HEIF에 HDR 정보(게인 맵)를 넣어 저장합니다. TIFF는 SDR로 저장합니다."),
        ]),
        Topic(title: "저장과 안전", icon: "checkmark.shield",
              summary: "보정과 분류가 어디에 저장되고 어떻게 되돌리는지 봅니다.", items: [
            Item(title: "자동 저장",
                 body: "사진 목록·별점·보정은 라이브러리 폴더(기본 ~/Library/Application Support/Lighthouse)에 바로 저장되며 저장 단추는 없습니다. 다른 라이브러리 폴더를 열 수도 있습니다.",
                 menus: ["파일 › 라이브러리 열기…"]),
            Item(title: "실행 취소",
                 body: "⌘Z·⇧⌘Z로 보정·별점·표시를 되돌리고 다시 합니다. 글자 칸에 입력하는 동안에는 입력한 글자를 되돌립니다."),
            Item(title: "원본 없음",
                 body: "원본을 옮기거나 드라이브를 빼면 원본 없음이 붙고 왼쪽에 원본 없음 목록이 생깁니다. 지금 파일이 든 폴더를 고르면 다시 연결하며, 같은 옛 폴더의 다른 사진도 함께 찾습니다.",
                 menus: ["사진 › 위치 다시 찾기…"]),
            Item(title: "보관본과 백업",
                 body: "앱은 하루에 한 번 카탈로그 보관본을 남기고 최근 7일치를 둡니다. 라이브러리 백업은 원본까지 넣을 수 있고, 복원은 지금 라이브러리를 그대로 둔 채 새 위치에 만듭니다.",
                 menus: ["파일 › 카탈로그 보관본 보기", "파일 › 라이브러리 백업…", "파일 › 라이브러리 복원…"]),
            Item(title: "XMP 사이드카",
                 body: "켜면 RAW 옆 .xmp 파일에 별점·라벨·키워드·설명을 써서 다른 사진 앱과 나눕니다. 원본 파일과 보정값은 건드리지 않으며 기본은 꺼져 있습니다.",
                 menus: ["사진 › 별점·키워드를 XMP 사이드카로 쓰기"]),
            Item(title: "스마트 미리보기",
                 body: "원본이 든 드라이브를 빼도 보정할 수 있게 미리보기를 만들어 둡니다(기본 보정은 근사). 원본을 다시 연결하면 그동안의 보정을 원본에 적용합니다.",
                 menus: ["사진 › 스마트 미리보기 관리…"]),
            Item(title: "뒤에서 도는 작업",
                 body: "얼굴 찾기·XMP 쓰기·업로드처럼 시간이 걸리는 작업은 사진 아래 줄에 무엇이 얼마나 진행됐는지 보이고, 작업 보기에서 진행과 중지 단추를 봅니다."),
        ]),
    ]

    /// 검색 결과 한 줄. 단축키 표에서 찾은 줄은 `keys`가 있다.
    struct Match: Identifiable, Hashable {
        let topic: String
        let title: String
        let body: String
        let menus: [String]
        let keys: String?
        var id: String { topic + "/" + title }
    }

    /// 띄어 쓴 낱말이 모두 든 도움말 항목(제목·설명·메뉴)과 단축키 표의 줄. 대소문자는 가리지 않는다.
    static func search(_ query: String) -> [Match] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        func matches(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return words.allSatisfy { lowered.contains($0) }
        }
        let items = topics.flatMap { topic in
            topic.items.filter { matches(([$0.title, $0.body] + $0.menus).joined(separator: " ")) }
                .map { Match(topic: topic.title, title: $0.title, body: $0.body, menus: $0.menus, keys: nil) }
        }
        let shortcuts = ShortcutGuide.sections.flatMap { section in
            section.entries.filter { matches($0.keys + " " + $0.action) }
                .map { Match(topic: "단축키 · " + section.title, title: $0.action, body: "", menus: [], keys: $0.keys) }
        }
        return items + shortcuts
    }
}

/// 도움말 창. 왼쪽에서 주제를 고르거나 위에서 검색한다. 단축키 주제는 단축키 창과 같은 표를 보인다.
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String
    @State private var query: String
    private static let shortcutsTitle = "단축키"

    /// `topic`을 고른 채(없으면 첫 주제) 또는 `query`로 찾은 채 연다.
    init(topic: String? = nil, query: String = "") {
        _selection = State(initialValue: topic ?? HelpGuide.topics[0].title)
        _query = State(initialValue: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Lighthouse 도움말").font(.title2.weight(.semibold))
                Spacer()
                TextField("도움말 검색", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .accessibilityLabel("도움말 검색")
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 180)
                Divider()
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty { topicContent } else { results }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 820, height: 600)
        // 시트는 본 창의 강조색 범위 밖이라 보조 단추를 중립색으로 두고, 고른 주제만 강조색으로 보인다.
        .tint(Palette.inactive)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HelpGuide.topics) { topic in sidebarRow(topic.title, icon: topic.icon) }
            sidebarRow(Self.shortcutsTitle, icon: "keyboard")
            Spacer()
        }
        .padding(10)
    }

    private func sidebarRow(_ title: String, icon: String) -> some View {
        let selected = selection == title && query.trimmingCharacters(in: .whitespaces).isEmpty
        return Button {
            selection = title
            query = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(selected ? Palette.accent : Palette.muted)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(selected ? Palette.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var topicContent: some View {
        if let topic = HelpGuide.topics.first(where: { $0.title == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title).font(.title3.weight(.semibold))
                        Text(topic.summary).foregroundStyle(.secondary)
                    }
                    ForEach(topic.items) { item in entry(item.title, body: item.body, menus: item.menus) }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(Self.shortcutsTitle).font(.title3.weight(.semibold))
                Text("한글 입력 상태에서도 같은 자리의 키로 동작합니다. 글자 칸에 입력하는 동안에는 한 글자 단축키가 동작하지 않습니다.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView { ShortcutGuideList() }
            }
            .padding(22)
        }
    }

    @ViewBuilder private var results: some View {
        let matches = HelpGuide.search(query)
        if matches.isEmpty {
            Text("‘\(query.trimmingCharacters(in: .whitespaces))’에 맞는 도움말이 없습니다. 다른 낱말로 찾아 보세요.")
                .foregroundStyle(.secondary).padding(22)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("검색 결과 \(matches.count)개").font(.callout).foregroundStyle(.secondary)
                    ForEach(matches) { match in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.topic).font(.caption).foregroundStyle(.secondary)
                            if let keys = match.keys {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(keys).font(.body.monospaced())
                                    Text(match.title).fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            } else {
                                entry(match.title, body: match.body, menus: match.menus)
                            }
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func entry(_ title: String, body: String, menus: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).fixedSize(horizontal: false, vertical: true)
            if !menus.isEmpty {
                Text("메뉴: " + menus.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
