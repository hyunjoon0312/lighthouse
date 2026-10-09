# 컬러 그레이딩·분할 톤 계약 v1

2026-10-09 사용자 요청. Lightroom 프리셋에서 제외되던 컬러 그레이딩·분할 톤을 앱 조절과 프리셋 가져오기 양쪽에 구현한다. 성공 기준은 Lightroom과 같은 값이 같은 영역을 같은 색 방향으로 비슷한 정도로 바꾸는 것이다. Adobe 현상 엔진과 수치별 동일 픽셀을 보장하지 않는다. 기존 보정과 중립 출력은 유지한다.

후속 하위 프로젝트(텍스처·디헤이즈·화이트밸런스, DCP 프로필·캘리브레이션)는 이 계약의 범위가 아니다.

## 모델과 저장

- `ColorGradeZone: Codable, Equatable, Sendable`: `hue` 0..<360(도), `saturation` 0…1, `luminance` -1…1. 기본 (0, 0, 0).
- `ColorGrading: Codable, Equatable, Sendable`: `shadows`, `midtones`, `highlights`, `global`(모두 `ColorGradeZone`), `blending` 0…1 기본 0.5, `balance` -1…1 기본 0. `static let neutral`. `isNeutral`은 네 영역 모두 saturation 0이고 luminance 0일 때 true다. blending·balance만으로는 효과가 없다.
- `EditSettings.colorGrading: ColorGrading`, 기본 `.neutral`.
- 키가 없을 때만 기본값을 쓴다. 명시적 null, 잘못된 타입, 비유한 값, 범위를 벗어난 값은 거부한다. 영역·그레이딩 내부 키도 같은 규칙이다. encode는 `colorGrading == .neutral`일 때 키를 생략해 기존 카탈로그와 썸네일 키를 유지한다. 중립이 아니면 blending·balance를 포함해 실제 값을 그대로 저장한다.
- `.global` 일괄 복사에 포함한다. `EditSnapshots` 변경 이름은 "컬러 그레이딩"이다. 사용자 프리셋 저장·재로드, `isModified`, 큐브 캐시 키, 최종 렌더 캐시가 새 값을 반영한다.
- 부분 보정(`LocalAdjustment`)에는 추가하지 않는다. 원본은 변경하지 않는다.

## 렌더 계약

- 위치: `AdvancedColorProcessor`의 64³ 큐브 안에서 곡선 → HSL → 컬러 그레이딩 순서로 계산한다. 입력은 큐브 격자의 sRGB 인코딩 값 0…1이다. 곡선·HSL·그레이딩이 모두 중립이면 지금처럼 큐브를 건너뛰어 기존 출력과 픽셀이 같다. `applyColor`와 `transformRGB`에 grading 인자를 더하고 `ImagePipeline.composed`가 `edits.colorGrading`을 전달한다. 큐브 캐시는 grading도 비교한다.
- 흑백 프로필은 현상 단계에서 먼저 적용되므로, 흑백 사진에 분할 톤을 줄 수 있다.
- 영역 가중치. `L = clamp(0.2126r + 0.7152g + 0.0722b, 0, 1)`:
  - `t = L ^ (2 ^ -balance)`
  - `e = 0.05 + 0.45 * blending`
  - `ws = 1 - smoothstep(max(0, 1/3 - e), 1/3 + e, t)`
  - `wh = smoothstep(2/3 - e, min(1, 2/3 + e), t)`
  - `wm = max(0, 1 - ws - wh)`, `wg = 1`
  - smoothstep의 두 끝이 같으면 계단 함수로 처리한다.
- 명도: `ΔY = Σ w_i * luminance_i * 0.5 * L * (1 - L)`를 R·G·B에 똑같이 더하고 0…1로 자른다. 결과를 `base`라 한다.
  - 혼합이 낮고 명도가 강하면 가중치가 가팔라 밝은 입력이 더 어두워질 수 있다(최종 검토에서 발견). 그래서 그레이딩마다 `L + ΔY(L)`를 1025칸 표로 만들고 누적 최대로 단조화한 뒤 선형 보간해 쓴다. 0과 1 끝점은 그대로다.
- 색: 각 영역 `C_i = HSL(hue_i, 1, 0.5)`의 RGB, `d_i = C_i - Y(C_i)`(밝기 0인 색 방향), `D = Σ w_i * saturation_i * 0.3 * d_i`. `base + α·D`가 모든 채널에서 0…1 안에 있는 최대 `α ∈ [0, 1]`로 `base + α·D`를 출력한다. 틴트는 밝기 Y를 바꾸지 않으며, 순수한 검정·흰색은 그대로 남는다.
- 모든 가중치는 같은 입력 픽셀의 L로 계산하므로 영역 적용 순서와 관계가 없다. 계수 0.3, 0.5는 Lighthouse 고유값이다.
- 기존 큐브와 마찬가지로 0…1 밖의 확장 범위는 큐브에서 잘린다. 문제가 보이면 같은 수식을 별도 커널로 옮긴다(이번 범위가 아니다).
- 미리보기와 내보내기는 같은 composition 경로를 쓴다. 검증 실패는 기존 `AdvancedColorProcessingError`로 반환하며 효과를 조용히 빼지 않는다.

## 앱

- 새 파일 `Sources/Lighthouse/ColorGradingControls.swift`에 영역 선택, 색상 바퀴, 슬라이더를 둔다. `AdvancedColorControls`는 HSL 다음, 필름 입자 앞에 이 뷰를 끼운다.
- 영역 Picker: 그림자 / 중간톤 / 하이라이트 / 전체. 선택한 영역은 뷰 상태이며 사진에 저장하지 않는다. 채도나 명도가 0이 아닌 영역은 버튼에 색 점을 표시한다.
- 색상 바퀴 약 160px: 0°(빨강)가 오른쪽이고 반시계 방향으로 돈다. 각도가 색조, 중심에서의 거리(반지름 대비 0…1)가 채도다. 바깥을 끌면 가장자리에 맞춘다. 연속 드래그 한 번은 실행 취소 1단계이며 기존 `model.updateEdits` 경로를 쓴다. 두 번 누르면 선택 영역만 초기화한다. 제자리 클릭은 연속 편집을 잠시(350ms) 열어 두어, 이어지는 두 번 누르기 초기화와 한 실행 취소 단계로 묶는다. 접근성 이름과 현재 색조·채도 값을 제공한다.
- 슬라이더: 색조 0…359°, 채도 0…100, 명도 -100…100은 선택 영역용이다. 혼합 0…100(기본 50)과 균형 -100…100(기본 0)은 공통이다. 이름이나 값을 두 번 누르면 해당 항목만 기본값으로 돌아간다. 키보드·VoiceOver 사용자는 슬라이더로 같은 값을 조절할 수 있다.
- 300px Inspector 폭에서 겹치거나 잘리는 부분이 없어야 한다. 새 전역 상태는 추가하지 않는다.
- 가져오기 호환 정보의 "지원 설정 N개"에 컬러 그레이딩 키를 포함한다.

## 프리셋 가져오기

- payload 구조는 바꾸지 않는다. `LightroomPresetPayload.scalarRanges`에 Adobe 키 14개를 더하며, 지원 키 판정이 제외 접두사 판정보다 먼저 이루어진다. 다른 `ColorGrade*`/`SplitToning*` 이름은 계속 제외 경고를 낸다.

| 키 | 범위 | 적용 |
|---|---|---|
| `SplitToningShadowHue` / `SplitToningShadowSaturation` | 0…360 / 0…100 | shadows hue / saturation÷100 |
| `SplitToningHighlightHue` / `SplitToningHighlightSaturation` | 0…360 / 0…100 | highlights hue / saturation÷100 |
| `SplitToningBalance` | -100…100 | balance÷100 |
| `ColorGradeMidtoneHue` / `ColorGradeMidtoneSat` | 0…360 / 0…100 | midtones hue / saturation÷100 |
| `ColorGradeGlobalHue` / `ColorGradeGlobalSat` / `ColorGradeGlobalLum` | 0…360 / 0…100 / -100…100 | global hue / saturation÷100 / luminance÷100 |
| `ColorGradeShadowLum` / `ColorGradeMidtoneLum` / `ColorGradeHighlightLum` | -100…100 | 각 영역 luminance÷100 |
| `ColorGradeBlending` | 0…100 | blending÷100 |

- 색조 360은 0으로 저장한다. 범위 밖 값, 숫자가 아닌 값, 상충하는 중복 값은 기존 규칙대로 오류다. XMP attribute, direct element, lrtemplate 숫자에서 모두 읽는다.
- 프리셋에 없는 값은 현재 사진값을 유지한다. 옛 분할 톤 프리셋에 `ColorGradeBlending`이 없어도 값을 추정해 채우지 않는다.
- 위 키가 하나라도 있으면 "컬러 그레이딩은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다." 경고를 더한다.
- 이전에 가져온 payload에는 제외된 값이 저장되지 않았다. 새 값을 받으려면 원본 XMP/lrtemplate을 다시 가져와야 하며, 자동 복원을 주장하지 않는다.

## 검증

- 모델: 누락 키 기본값, 명시 null·잘못된 타입·비유한 값·범위 초과 거부, roundtrip, 중립일 때 키 생략, 기존 카탈로그 JSON 디코드와 재인코드 동일성.
- 렌더(`ColorGradingTests` 신규): 중립 무변화와 큐브 생략, 각 영역의 방향(해당 밝기대에서만 색이 움직임), 균형 +/−에 따른 영역 이동, 혼합 0/100에 따른 경계 폭, 검정·흰색 보존, 틴트 후 밝기 Y 보존, 명도 방향, 반복 출력 동일성, 미리보기와 내보내기 일치, 흑백 프로필과 함께 쓸 때 틴트.
- 가져오기: 14개 키의 XMP attribute·element·lrtemplate, 360→0, 범위 오류, 상충 값, 부분 적용 시 누락 값 유지, 알 수 없는 `ColorGrade*` 제외 경고, 근사 경고, 실제 `my.slow.film` 재가져오기(모든 값이 중립이므로 렌더 결과 동일).
- 앱(`LightroomPresetFlowTests` 확장 또는 신규): 영역 전환, 바퀴·슬라이더 값 연결, 드래그 1회 = 실행 취소 1단계, 두 번 눌러 초기화, 일괄 적용·재로드, 300px 스냅샷 육안 확인.
- 전체 `swift test`, `swift build`, release 패키지, 실제 `.app` 실행. 실제 S9 RW2에 그레이딩을 적용해 미리보기·JPEG를 확인하고 원본 SHA가 같은지 본다. 실제 UI 클릭·키보드 조작은 접근성 권한이 없으면 `not_run`으로 보고한다. Adobe와의 시각적 일치는 검증 대상이 아니다.

## 소유권

2026-10-09 사용자 결정에 따라 이 세션의 Claude가 설계와 구현을 모두 맡는다(Astra/Sol 대체). 한 작성자가 다음 순서로 직렬 진행한다: 계약 → 코어 → 앱 → 통합 검증.

- 코어: `AdvancedEditModels`(또는 새 모델 파일), `PhotoModels`, `BatchEditing`, `EditSnapshots`, `ColorProcessing`, `ImagePipeline`, `LightroomPresetPayload`, `LightroomPresetImporter`, 새 `ColorGradingTests`, 필요한 기대값만 바꾼 `LightroomPresetTests`.
- 앱: 새 `ColorGradingControls`, `AdvancedColorControls`, `LightroomPresetImportSheet`(카운트가 필요하면), 앱 테스트.
- 문서: `docs/lightroom-presets.md`의 제외 목록과 사용 안내, `docs/advanced-editing.md` 해당 항목.
- 작업 트리의 다른 미커밋 diff는 보존한다. 커밋·푸시는 사용자가 허락한 경우에만 한다.

## 참고

[Adobe CRS namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/)의 프리셋 메타데이터 키를 읽는다. 렌더 수식은 Adobe 구현을 복제한 것이 아니다.
