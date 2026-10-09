# Lightroom 프리셋 가져오기 계약 v1

## 결과와 범위

사용자가 선택한 `.xmp`와 기존 `.lrtemplate` 현상 프리셋을 로컬 프리셋 보관함에 추가한다. 여러 파일의 성공·실패를 각각 보여 주고, 같은 이름에는 번호를 붙인다. 선택 사진·여러 장·사진 가져올 때 적용·실행 취소·재실행 복원에 같은 적용 함수를 쓴다. 기존 곡선, HSL, 마스크, 복구, 크롭, LUT와 라이브러리 흐름을 유지한다.

Adobe 현상 엔진과 색 결과의 일치를 보장하지 않는다. 적용 전과 저장 후 프리셋별로 근사 변환과 제외 항목을 볼 수 있다. ZIP/DNG/DCP 프로필·Adobe AI 마스크·카메라 프로필·컬러 그레이딩·캘리브레이션은 이번 호환 범위에 포함하지 않는다. 지원하지 않는 값만 있는 파일은 빈 프리셋으로 저장하지 않는다.

## 저장·적용

- `EditPreset`에 선택적 `lightroom: LightroomPresetPayload?`를 추가한다. 기존 키가 없는 v1 프리셋은 기존 component 병합을 그대로 쓴다. 명시적 잘못된 payload/null은 손상으로 거부한다. presets.json 버전은 1을 유지한다.
- payload는 `format: String`, 지원하는 Adobe 키의 `scalars: [String: Double]`, 정규화된 `curves: [String: [CurvePoint]]`, `warnings: [String]`를 저장한다. 원본 경로나 XML/Lua 원문은 저장하지 않는다. payload의 Codable와 저장 검증은 키·수치·곡선·유효 설정 개수를 검증한다.
- `EditPreset(name:lightroom:)`, `LightroomPresetImporter.parse(data:fileName:) throws -> EditPreset`, `LightroomPresetImporter.load(url:) throws -> EditPreset`를 공개한다. 후자는 크기를 확인하고 최대 2 MiB만 읽는다. format은 xmp/lrtemplate이다.
- `EditPreset.applied(to:)`는 Lightroom payload가 있으면 명시된 개별 값만 바꾼다. 곡선은 채널별, HSL은 색상별·속성별로 바꾼다. 다른 전역 보정, 크롭, LUT, 부분 보정, 복구, HDR, 노이즈 감소, RAW 설정을 보존한다. 명시된 0도 적용한다.
- 이름은 XMP Name의 x-default(없으면 첫 값), lrtemplate title/name, 마지막으로 파일명이다. 80자로 제한한다. 중복 이름은 앱에서 기존 이름을 보존하며 ` (2)` 등의 접미사를 붙인다.

## 변환 규칙

변환은 Lighthouse 엔진에 맞춘 근사값이다. 모든 입력은 유한 수이고 선언한 Adobe 범위 안이어야 한다. 잘못된 지원 값은 파일 오류로 거부하며 자동 0 변환하지 않는다.

| Adobe 키 | Lighthouse 값 |
| --- | --- |
| Exposure2012 또는 Exposure | exposure, -5…5 입력을 -4…4로 제한하고 제한 시 안내 |
| Contrast2012 또는 Contrast | contrast = 1 + 값/200, -100…100 (구형 -50…100) |
| Saturation | saturation = 1 + 값/100 |
| Vibrance | vibrance = 값/100 |
| Clarity2012 또는 Clarity | clarity = 값/100 |
| Highlights2012 | -100…0은 highlights = 1 + 값/100; 양수는 제외하고 안내 |
| Shadows2012 | 0…100은 shadows = 값/100; 음수는 제외하고 안내 |
| Sharpness | 0…150을 sharpness = 값/75로 근사 |
| PostCropVignetteAmount | vignette = 값/100 (양수는 가장자리 밝게, 음수는 어둡게) |
| GrainAmount / GrainSize | amount = 값/100, size = 0.5 + 값×0.075 |
| HueAdjustment{Red,Orange,Yellow,Green,Aqua,Blue,Purple,Magenta} | hue = 값×0.3 |
| SaturationAdjustment{색} / LuminanceAdjustment{색} | saturation/lightness = 값/100 |
| ToneCurvePV2012, ToneCurvePV2012Red/Green/Blue | master/red/green/blue; 0…255 좌표를 0…1로 변환 |
| ToneCurve (현대 master 곡선 없을 때) | master의 구형 별칭 |

현대 키가 있으면 구형 별칭보다 우선한다. 곡선은 2…16개의 x 오름차순 점이며 x=0,255 양끝이 필요하다. 형식이 맞지 않으면 안내 후 해당 곡선을 제외한다. 과도한 점 수를 조용히 잘라내지 않는다. 다른 곡선과 HSL 속성은 보존한다.

Temperature/Tint/IncrementalTemperature/IncrementalTint/WhiteBalance는 서로 다른 RAW 기준과 단위 때문에 이번에는 제외하고 안내한다. As Shot도 대상 사진 보정을 초기화하지 않는다. Whites/Blacks/Texture/Dehaze, ConvertToGrayscale, SplitToning/ColorGrade, CameraProfile/Look, Lens/모든 마스크 등 미지원 crs 설정은 무시한 키를 표시한다. 일반 메타데이터(Name/Group/UUID/Version/ProcessVersion/Supports*/Copyright/ContactInfo/HasSettings 등)는 제외 안내에서 생략 가능하나 알 수 없는 현상 키는 조용히 버리지 않는다. 항상 엔진 차이 안내를 포함한다.

## 파서 안전성과 오류

XMP는 Foundation XMLParser로 네임스페이스 URI `http://ns.adobe.com/camera-raw-settings/1.0/`를 확인한다. 접두사 이름에 의존하지 않으며 attributes와 scalar child elements, RDF Alt/Seq를 처리한다. 이름 및 곡선 외의 중첩 구조를 전역 값으로 끌어올리지 않는다. 여러 Description의 상충값은 거부한다. DTD/entity 선언과 외부 entity, 잘못된 XML, 무관한 XML, 프로필 전용 PresetType은 거부한다. 외부 네트워크·파일 엔티티를 해석하지 않는다.

lrtemplate은 Lua를 실행하지 않는다. `s = { ... value = { settings = { ... } } }`와 일반적인 title/type 구조의 데이터 리터럴만 파싱한다. 따옴표 문자열·숫자·boolean·table·주석만 허용하고 함수/표현식은 거부한다. 중첩 깊이와 토큰 수를 제한한다. settings 안의 중첩 마스크를 전역 설정으로 끌어올리지 않는다. 곡선은 숫자 배열 쌍을 처리한다. 현상 프리셋이 아닌 type은 거부한다.

## 앱 흐름

프리셋 영역을 빛 도구 위로 옮기고 검색을 제공한다. `Lightroom 프리셋 가져오기…`는 inspector와 앱 메뉴에 있으며 사진이 없는 상태에서도 메뉴로 실행할 수 있다. NSOpenPanel은 여러 xmp/lrtemplate를 선택한다. 파싱은 백그라운드에서 수행한다. 파싱 완료 시 최신 보관함에 병합한 뒤 저장 성공에만 UI 목록을 변경한다. 불러오기 오류가 있는 보관함은 덮어쓰지 않는다. 종료/중복 요청 상태를 보호하고 가져온 프리셋은 사진에 자동 적용하지 않는다.

공유 sheet `LightroomPresetImportSheet`에 가져오기 결과(추가 수·실패 파일·제외 항목)를 표시하고, 보관한 프리셋 관리 메뉴에 호환 정보도 제공한다. 사진 적용은 기존 applyEditChanges를 사용하여 대상별 `preset.applied(to:)`로 계산한 변경을 한 실행 취소 단위로 기록한다. 경고는 즉시 확인할 수 있게 한다.

## 검증과 소유권

core Sol: `Sources/LighthouseCore/EditPresetStore.swift`, 새 `LightroomPresetImporter.swift`, 새 `LightroomPresetPayload.swift`, `Tests/LighthouseCoreTests/LightroomPresetTests.swift`.

app Sol (core 승인 후): `LibraryModel.swift`와 `LibraryModel+*.swift` 단독 소유(필요한 파일만 변경), `InspectorView.swift`, `LighthouseApp.swift`, `WorkspaceView.swift`, 새 `LightroomPresetImportSheet.swift`, 새 `Tests/LighthouseTests/LightroomPresetFlowTests.swift`. `LibrarySession.swift` 기존 변경은 건드리지 않는다.

메인 Astra: 계약·사용 안내·통합 검사·.build/dist·하네스 기록. 원래 있던 AutoAdjust/LibrarySession/문서·테스트 변경을 보존한다. 작업자는 재위임하지 않는다.

필수 검사: XMP namespace/attributes/elements/curve/name, lrtemplate 정상 및 코드 거부, 악성/깨진/과대 파일, 미지원만 있는 프리셋 거부, 부분 적용·0·HSL 속성 보존, 저장 재로드·구형 호환·손상 보존, 다중 선택 undo/redo, 가져오기 자동 적용, 이름 충돌·부분 성공·저장 오류. 생성 이미지 픽셀·원본 SHA·preview/export, 전체 swift test, swift build, 패키징/서명, 격리 카탈로그 실제 .app의 import/apply/undo/restart 흐름. 실제 S9나 Adobe 색 일치는 샘플·비교 근거 없으면 미검증이다.

## 참고 자료

- [Adobe 프리셋 가져오기 안내](https://www.adobe.com/learn/lightroom-cc/web/import-presets): xmp 및 기존 lrtemplate 형식.
- [Adobe Camera Raw XMP namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/): namespace URI와 구형 키의 의미·범위.
- [Adobe 공식 XMP 샘플](https://github.com/AdobeDocs/cis-photoshop-api-docs/blob/main/sample-code/lr-sample-app/crs.xml): 현대 키와 RDF 구조.

확인일: 2026-10-07. 수치 변환은 Adobe 공식 변환식이 아니라 이 앱의 호환 정책이다.
