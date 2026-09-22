# 참조 사진 색감 맞추기 — MATCH-v1

2026-09-23. 사용자 요청: 참조 사진과 유사하게 보정하고 그 색감의 LUT를 만들어 S9에서 사용할 수 있는지 확인한다.

## 확정된 제품 동작

현재 사진과 외부 참조 사진을 로컬에서 분석해 밝기·대비·색 분포를 비슷하게 만드는 통계적 색감 맞추기다. 같은 장면일 필요는 없지만 피사체/조명 차이가 클수록 결과가 달라진다. 장면 생성이나 원래 프리셋의 역추출은 제공하지 않는다. 분석은 현재 사진의 기존 LUT를 제외한 보정 상태를 기준으로 하고, 결과 LUT는 기존 LUT를 대체한다. 다른 보정은 유지한다. LUT에는 이 색 변환만 담으며 마스크·크롭·선명도나 기존 보정 설정은 담지 않는다.

시트에서 참조 파일 선택 → 분석 → 참조/보정 전/결과 미리보기 → 강도 조절 → `보관하고 현재 사진에 적용`, `LUT만 보관`, `S9용 .cube 내보내기…`를 제공한다. 적용 후 기존 일괄 LUT 버튼으로 여러 사진에도 적용 가능하다. UI 안내에 근사 결과이며 S9 실기 확인 전이라는 사실을 간결히 명시한다.

## 역할과 파일 소유권

- Astra: 설계·검토·카메라 공식자료 조사·docs·독립검증.
- Sol core: 새 `Sources/LighthouseCore/ReferenceColorMatch.swift`, 새 `Tests/LighthouseCoreTests/ReferenceColorMatchTests.swift`. LUTStore의 앞선 작업은 완료; 기존 core 파일 변경 없이 public API만 사용.
- Sol match UI (batch 완료 후 같은 작업자): 새 `Sources/Lighthouse/ReferenceMatchModel.swift`, 새 `Sources/Lighthouse/ReferenceMatchSheet.swift`만.
- Sol app: 기존 소유 파일에 아래 진입점과 통합 hook만 추가. 참조 시트 파일은 편집하지 않는다.
- 재위임 없음. 새 결정은 Astra에게 질문하고 소유 파일 외 변경 금지.

## 코어 API와 알고리즘

`ColorMatchTransform: Sendable` public initializer `init(source:[SIMD3<Double>], reference:[SIMD3<Double>]) throws`. 입력은 encoded sRGB 0…1 RGB 표본. 비어있거나 nonfinite 표본, 범위 밖 표본을 오류로 거부한다. public `map(_ rgb:SIMD3<Double>, strength:Double = 1) -> SIMD3<Double>`. public `cubeData(title:String, strength:Double = 1) -> Data`.

알고리즘은 D65 CIELAB 공간의 각 축 평균/표준편차를 맞추는 통계 변환이다. sRGB inverse transfer → XYZ D65 → CIELAB 표준 식과 역변환을 사용한다. 각 축 ratio는 source stddev가 0.001 미만이면 1, 아니면 reference/source 비율을 0.5…2로 제한한다. target mean은 source mean에 L축 ±30, a/b축 ±25 범위의 mean 차이를 더한다. 변환은 `(value - sourceMean) * ratio + limitedTargetMean`. 역변환 후 sRGB를 0…1로 clamp하고 원 RGB와 strength(0…1, nonfinite면0)로 encoded sRGB에서 선형 혼합한다. source==reference는 오차허용 내 identity; strength0은 정확히 원색. 평균/표준편차 계산은 Double 및 안정적인 누적을 사용한다.

cubeData는 UTF-8, red-fastest 순서 33³ RGB행, 6자리 이상의 소수점, full range DOMAIN_MIN 0 0 0 / DOMAIN_MAX 1 1 1. TITLE의 따옴표/개행/control 문자는 안전하게 제거한다. TITLE 바로 다음 줄에 **`#LUMIXPHOTOSTYLE STD`**를 넣는다. 앱의 렌더는 encoded sRGB LUT이며 S9에서는 Standard 기반으로 사용한다. V-Log 변환이라고 표시하지 않는다. 파일 안 comment로 Lighthouse reference color match / Standard base / full range 기록 가능. 파일 경로나 원본 사진 개인정보는 넣지 않는다.

`ReferenceMatchResult`는 `transform:ColorMatchTransform`, `sourcePreview:CGImage`, `referencePreview:CGImage` public let. `ReferenceColorMatcher` final class @unchecked Sendable, public init(lutDirectory:URL = LUTStore.defaultDirectory), `analyze(source:PhotoAsset, referenceURL:URL) throws -> ReferenceMatchResult`, `preview(result:ReferenceMatchResult, strength:Double) throws -> CGImage`.

analyze: ImagePipeline로 source.edits에서 lut=nil만 제거해 maxPixel 800, reference는 neutral maxPixel800로 렌더. CGColorSpace.sRGB, RGBA8 CGContext로 최대256변 표본을 만들고 premultiplied alpha를 해제하며 alpha<0.05는 제외한다. 이미지/빈 표본 오류는 localizedError. preview는 sourcePreview에 동일 transform.map을 적용한 sRGB CGImage를 만들어 방향과 alpha를 유지한다. 직접 픽셀 변환으로 만들되 800px로 한정하고 UI 밖 queue에서 수행한다. 표본과 preview 좌표 방향을 테스트한다. 상태 공유 없는 순수 변환이며 thread 안전.

검증: identity, strength0, 밝고 따뜻한 synthetic reference 쪽으로 색통계 거리 감소, uniform/검정/흰색의 finite 출력, invalid 표본 거부, generated cube 33³/범위/안전 TITLE/STD tag/red-fastest parse roundtrip, preview 방향·투명도, 작은 sRGB fixture file analyze. `swift test --filter ReferenceColorMatchTests` 담당 core. 앱 전체 build/UI는 별도.

## UI 모델과 시트

`ReferenceMatchSheet(source:PhotoAsset, onStored:(LUTAdjustment,Bool)->Void)`의 onStored Bool은 apply 요청 여부. @StateObject ReferenceMatchModel은 source snapshot을 받는다. model API는 새 두 UI 파일 내부에서 정하고 외부에는 위 Sheet initializer만 노출한다. `LUTStore`, `ReferenceColorMatcher`는 기본 디렉터리 사용. NSOpenPanel 한 참조이미지; ImagePipeline supportedExtensions 기반 UTType; 참조 파일은 카탈로그에 자동 추가하지 않는다.

분석/preview/cube 생성/보관은 전용 serial queue. generation token으로 이전 참조/이전 강도의 늦은 결과가 화면을 덮지 못하게 한다. 분석 중·preview 갱신 중에는 저장/내보내기 비활성화. 강도 slider debounce 150ms 이상. 분석 실패 시 이전 결과 폐기하고 오류 표시. 원본 파일/참조 파일 변경 없음. 취소/닫기로 app 보정 변경 없음.

LUT 이름 입력 기본 `참조 색감 · {reference basename}`. 버튼을 누를 때 현재 유효 분석/강도/name을 snapshot. cubeData를 UUID 전용 임시 디렉터리의 .cube로 atomic 작성 → LUTStore.importCube → temp 정리(defer). 보관 성공 후 onStored(adjustment,apply) 호출하고 dismiss. 생성된 LUT에는 강도가 구워져 있으므로 적용 adjustment는 intensity1/enabledtrue. `LUT만 보관`은 사진 보정 변경 없음.

S9 내보내기는 NSSavePanel, defaultname **LHLOOK01.cube**(8 ASCII alnum), 허용확장 cube. 파일 basename이 1…8 ASCII영숫자가 아니면 오류 안내 후 다시 선택하게 한다(강제로 경로 바꾸지 않음). 사용자가 지정한 저장 경로에 현재 강도가 담긴 cubeData atomic 저장. 이 버튼은 앱 LUT보관이나 사진 편집을 자동 수행하지 않는다. 성공 메시지 파일명과 경로 제공. 시트 계속 열어둔다. 네이티브 savepanel의 기존 파일 덮어쓰기 확인을 사용한다. 저장본 reparse/33-grid/STD tag는 테스트로 보장.

시트 권장폭940 높이720 이하, 창이 작으면 ScrollView. 3개 이미지 `현재 사진 (LUT 제외)`, `참조 사진`, `색감 맞춘 결과`, 참조 이름, 강도 및 LUT 이름, 진행/오류/버튼. source filename 표시. 설명: `사진의 밝기와 색 분포를 근사합니다. 조명과 피사체가 다르면 결과도 달라집니다.` / `현재 LUT는 대체됩니다. 다른 보정은 유지됩니다.` / 카메라 `S9: Standard 기반 33³ LUT · 실기 색감 확인 필요`. 개발 용어/API/thread/hash는 제품 UI에 표시하지 않는다.

## app 통합 hook (app 작업자만)

`@Published var referenceMatchSource:PhotoAsset?`를 추가해 `.sheet(item:)`에서 ReferenceMatchSheet(source:)를 연다. 진입 함수 `presentReferenceMatch()`는 selection snapshot, catalog 유효 guard, local stroke 종료. 오른쪽 전체 보정에 `참조 사진 색감 맞추기…` 버튼; File 메뉴도 가능하면 추가. 열려있는 동안 배경 사진키/CmdZ 및 다른 편집 메뉴 guard.

`finishReferenceMatch(_ adjustment:LUTAdjustment, apply:Bool, source:PhotoAsset)`는 저장목록 refresh를 항상 요청. apply일 때 현재 selectedID가 snapshot.source.id이고 그 사진의 edits가 snapshot.edits와 같은 경우만 최신 edits.lut를 adjustment로 바꾸어 updateEdits. 아니면 보관만 했다는 message. 따라서 분석 중 원본 보정 변경/다른 사진 선택으로 잘못 덮어쓰지 않는다. 올바른 적용 때 isOriginal=false, actualSize=false, mode.edit. 기존 history 한 단계 지원. onStored 클로저에서 captured source 전달. 시트 종료는 SwiftUI dismiss로 처리.

## S9 근거 (2026-09-23 확인)

- [S9 공식 LUT Library](https://eww.pavc.panasonic.co.jp/dscoi/DC-S9/html/DC-S9_DVQP3138_eng/0074.html): .cube 2…33 grid, full range 권장, SD 루트/영숫자8자(FAT32), 최대39 LUT. TITLE 밑 `#LUMIXPHOTOSTYLE STD`; 누락 시 V-Log 취급.
- [LUMIX Lab 공식 한국어 안내](https://av.jpn.support.panasonic.com/support/global/cs/soft/lumix_lab/ko/cts/d0.html): 33-grid .cube 가져오기 후 카메라 전송 가능.
- [통계 색 전이 논문](https://home.cis.rit.edu/~cnspci/references/dip/color_transfer/reinhard2001.pdf): 평균/표준편차 전이 원리 참고. 본 앱은 CIELAB 및 변화 제한을 택한 별도 구현이며 원 논문의 lαβ 구현 재현이라고 주장하지 않는다.

S9 기기 연결은 제공되지 않았으므로 공식 규격과 파일 검사는 확인하되 실제 카메라 로딩·촬영 색감 검증을 했다고 보고하지 않는다. Standard 카메라 출력과 macOS RAW/sRGB 렌더의 차이로 동일 색감은 보장하지 않는다. 모든 기존 임의 LUT를 S9 호환으로 표시하지 않고 이번 생성 33-grid LUT에만 내보내기 경로를 제공한다.
