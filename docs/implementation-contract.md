# 구현 계약 v1

Astra가 확정한 구현 인터페이스. 각 작업자는 자신의 파일만 수정한다. 아래 이름과 타입을 변경해야 하면 먼저 Astra에게 알린다. 추가 작업자를 만들지 않는다.

## 코어 작업자 소유권

`Package.swift`, `.gitignore`, `.agents/common/`, `.agents/skills/astra-sol-workflow/`, `Sources/LighthouseCore/`, `Tests/LighthouseCoreTests/`, `scripts/build-app.sh`, `Resources/Info.plist`.

- 먼저 `/Users/joon/.codex/RTK.md`, `/Users/joon/.codex/CODEX_RULES.md`, `/Users/joon/.codex/skills/astra-sol-workflow/`의 실제 파일을 해당 저장소 경로로 복사한다. 정책을 수정하지 않는다.
- 패키지: Swift tools 6.0, macOS 15, Swift language v5, library `LighthouseCore`, executable target/product `Lighthouse` (코드는 앱 작업자 소유), test target `LighthouseCoreTests`. 외부 패키지 없음.
- `.build`, `dist`, `.DS_Store`, 개발 테스트 이미지·출력 폴더 `.artifacts`를 ignore한다.
- 빌드 스크립트는 release 바이너리를 `dist/Lighthouse.app/Contents/MacOS/Lighthouse`에 복사하고 Info.plist, 리소스를 배치한다. bundle ID `com.rian.lighthouse`, 버전 0.1.0, 최소 OS 15.0. 사용자별 설치·공증·프로비저닝 없이 이 Mac에서 실행 가능한 앱. 가능한 경우 ad-hoc codesign. 원본 사용자 폴더에는 쓰지 않는다.

### 공개 모델 (모두 public)

- `PhotoFlag: String, Codable, CaseIterable, Sendable` — `.none`, `.pick`, `.reject`.
- `EditSettings: Codable, Equatable, Sendable` — public init 기본값, `exposure: Double = 0`, `contrast: Double = 1`, `saturation: Double = 1`, `temperatureShift: Double = 0`, `tintShift: Double = 0`, `highlights: Double = 1`, `shadows: Double = 0`, `sharpness: Double = 0`, `rotationQuarterTurns: Int = 0`, `cropAspect: Double? = nil`. static `neutral`, computed `isModified: Bool`.
- `PhotoMetadata: Codable, Equatable, Sendable` — `width: Int = 0`, `height: Int = 0`, `camera: String?`, `lens: String?`, `iso: Int?`, `aperture: Double?`, `shutter: Double?`, `capturedAt: Date?`; 모든 기본값을 제공하는 public init.
- `PhotoAsset: Identifiable, Codable, Equatable, Sendable` — `id: UUID`, `path: String`, `importedAt: Date`, `metadata: PhotoMetadata`, `rating: Int`, `flag: PhotoFlag`, `edits: EditSettings`; init `init(id: UUID = UUID(), url: URL, metadata: PhotoMetadata = PhotoMetadata(), importedAt: Date = Date())`; computed `url: URL`, `filename: String`, `isRAW: Bool`. 경로는 standardizedFileURL.resolvingSymlinksInPath로 정규화. 원본 파일은 이동하지 않는다.
- `CatalogStore`: `init(url: URL)`, static `defaultURL: URL` (`LIGHTHOUSE_DATA_DIR`가 있으면 그 폴더 아래 `catalog.json`), `load() throws -> [PhotoAsset]`, `save(_ photos: [PhotoAsset]) throws`. 내부에 버전 1 봉투 사용. 파일 없음만 빈 배열, 손상·미지원 버전은 오류. 폴더 생성 후 원자적 저장. 호출자는 직렬화한다.

### 공개 이미지 API

`ImagePipeline`: `final class`, 필요 시 `@unchecked Sendable` (CIContext 재사용, 필터는 호출마다 생성).

- `public init()`
- static `supportedExtensions: Set<String>` (최소 jpg/jpeg/png/heic/heif/tif/tiff/rw2/dng/arw/nef/cr2/cr3/orf/raf/pef)
- static `isRAW(_ url: URL) -> Bool`
- static `supportedCameraModels: [String]`
- `metadata(for url: URL) throws -> PhotoMetadata`
- `thumbnail(for url: URL, maxPixel: Int = 360) throws -> CGImage`
- `render(url: URL, edits: EditSettings, maxPixel: Int? = 2200) throws -> CGImage`
- `exportJPEG(url: URL, edits: EditSettings, to directory: URL, maxPixel: Int?, quality: Double) throws -> URL`

RAW는 CIRAWFilter를 통해 실제 센서 데이터에서 현상한다. baseline exposure와 원본 neutral temperature/tint를 유지한 채 조절값을 적용한다. 일반 포맷은 orientation을 적용해 CIImage로 로드. 대비·채도는 CIColorControls, 하이라이트·섀도는 CIHighlightShadowAdjust, 선명도는 CISharpenLuminance. 온도는 RAW에서 as-shot 상대값, 일반 이미지에서 기준 6500 상대값. 90도 시계 방향 회전, 중앙 비율 크롭, 출력 원점 정규화. 중립 설정은 불필요한 필터를 건너뛴다. `maxPixel`은 출력 긴 변 상한으로 업스케일하지 않는다. 전체 출력에 draft 모드를 쓰지 않는다. 메타데이터 치수와 orientation도 일관되게 처리한다.

JPEG는 sRGB, quality 0…1, 별도 `원래이름-edited.jpg`로 쓴다. 기존 파일·원본 덮어쓰기를 원자적으로 거부하고 충돌하면 접미사를 늘린다. 디코딩 실패·디렉터리 오류는 설명 가능한 localized error. 저장·렌더 메서드에서 UI를 호출하지 않는다.

코어 작업자는 저장 roundtrip, 손상 카탈로그 보호, 비중립 보정 픽셀 변화, 회전·크롭·축소 치수, JPEG 충돌 보존에 대한 의미 있는 테스트를 구현·실행한다. 파일 시스템은 각 테스트 임시 폴더로 격리. 앱 파일이 아직 없어 전체 빌드가 막히면 준비된 코어 파일부터 검증하고 통합은 조율자에게 넘긴다.

## 앱 작업자 소유권

`Sources/Lighthouse/`만 수정한다. `Package.swift`와 코어, 문서, 빌드 스크립트에는 쓰지 않는다. 코어의 위 인터페이스를 따른다.

- SwiftUI @main App, AppKit delegate로 창을 전면 표시. 최소 1100×720, 초기 약 1440×900. 어두운 중성 회색, 포인트는 따뜻한 황색 또는 주황색, 한국어 UI. 시스템 심볼 활용, 외부 이미지·의존성 없음.
- 메인 액터 `ObservableObject`가 사진 목록·선택·필터·보정·진행 상태를 관리한다. 카탈로그와 원본 메타데이터 읽기·썸네일·렌더·내보내기는 백그라운드 직렬 큐 또는 제한된 작업 큐에서 실행. CIContext를 매번 생성하지 않는다.
- 카탈로그 저장은 스냅샷을 전용 직렬 큐에 순서대로 기록한다. 보정 슬라이더 저장은 짧게 debounce하고 앱 종료 전 마지막 상태를 flush한다. 로드 오류 시 쓰기를 차단하고 명확한 오류 화면을 제공한다.
- 파일/폴더 가져오기: NSOpenPanel, 다중 선택, 폴더 재귀 탐색, 지원 확장자만, 정규화 경로 중복 제외, 진행·실패 요약. 카탈로그에 이미 있는 파일 경로에 중복 엔트리를 넣지 않는다. 사진 폴더를 앱이 이동·복사하지 않는다.
- 사이드바: 전체, 선택됨, 제외됨, 보정됨, 가져온 폴더. 상단 검색과 최소 별점 필터. 결과 수와 가져오기 버튼.
- 중앙: 그리드/사진/비교 모드. 클릭 선택, 더블클릭 보정. 이전/다음, 보기 맞춤/100%, 원본 토글. 비교는 현재 사진을 기준으로 고정하고 다른 사진으로 이동해 나란히 본다. 기본은 화면 맞춤, 전체 해상도 요청은 100% 모드에서만 한다. 오류·로딩 상태를 표시한다.
- 오른쪽: 선택 파일명·RAW 배지·별점·선택/제외, 노출 -4…4, 색온도 이동 -2500…2500K, 틴트 -100…100, 대비 0.5…1.5, 하이라이트 0…1, 섀도 0…1, 채도 0…2, 선명도 0…2. 회전, 중앙 크롭(원본/1:1/4:5/3:2/16:9), 초기화. 파일 메타데이터. 보정 복사/다음 사진에 붙여넣기. 가능한 범위에서 편집 실행 취소·다시 실행.
- 아래 필름스트립은 필터 결과로 구성. rating 0…5, P 선택, X 제외, U 표시 해제, 좌우 이동, G 그리드, E 편집, C 비교, 백슬래시 원본 보기. 텍스트 입력 중 단축키가 가로채지 않도록 한다. 메뉴에 Cmd+O 가져오기, Cmd+Shift+E 내보내기를 연결한다.
- 렌더 debounce 및 generation token으로 오래된 응답이 다른 선택에 표시되지 않게 한다. 썸네일은 NSCache 등으로 상한을 두고 캐시, 즉시 모든 원본을 디코딩하지 않는다. 전후 비교 원본은 같은 소스의 neutral edits를 사용.
- 내보내기 시트: 현재 사진 / 현재 필터 결과, 긴 변 원본·3840·2048, JPEG 품질, 폴더 선택, 진행과 완료/부분 실패 결과. 중복 파일은 코어가 회피. 진행 중 중복 내보내기 방지.
- 원본 누락/디코딩 실패 시 사진별 오류를 표시하고 다른 사진 선택은 계속 가능해야 한다.
- `LIGHTHOUSE_DATA_DIR`는 코어 기본 경로를 그대로 쓰므로 UI 스모크 테스트가 실제 사용자 카탈로그를 건드리지 않는다. 선택적으로 프로세스 launch argument `--import <path>`를 처리해 첫 실행의 실제 파일 가져오기를 자동 검증할 수 있게 한다.

## 완료 보고

변경 파일, 실행한 명령과 실제 결과, 미검증 범위와 남은 설계 문제를 보고한다. 완료 보고 직전에 조율자 메시지의 본문을 확인한다. 구현 완료를 UI 검증 완료나 실물 RW2 검증 완료로 표현하지 않는다.

## 통합 검토에서 확정한 보완

- 카탈로그 로드 완료 전 가져오기·변경·저장을 차단한다. 종료 직전 저장 실패는 사용자에게 오류를 표시하고 종료를 취소한다.
- 미리보기, 썸네일, 일괄 가져오기·내보내기 큐를 분리한다. 같은 사진 보정 중에는 기존 미리보기를 유지하고 완료 시 교체하며 실패하면 오류를 표시한다.
- 명시적 사진 선택·보기 전환 시 검색 입력 초점을 해제한다. 검색 입력 중에는 단축키를 가로채지 않으며 Escape로 입력을 마칠 수 있다.
- 100% 보기는 전체 이미지 픽셀 크기를 창의 backing scale로 나눈 포인트 크기로 표시한다.
- 별점·표시·보정 변경으로 현재 필터에서 사진이 제외되면 선택 상태를 즉시 다시 맞춘다.
- 주요 버튼·슬라이더·사진 타일에 접근성 이름을 제공하고 짧은 셔터 속도는 분수 초로 표시한다.
