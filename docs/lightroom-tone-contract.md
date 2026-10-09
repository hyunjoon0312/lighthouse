# Lightroom 추가 톤·입자·기본 프로필 계약 v1

2026-10-07 사용자 후속 요청. 앞선 `my.slow.film`에서 제외된 주요 값과 반대 방향 톤 조절을 구현한다. Adobe 현상 엔진과 수치별 동일 픽셀을 보장하지 않는다. 기존 보정과 중립 출력은 유지한다.

## 모델과 저장

- `EditSettings.whites`, `blacks`: Double, -1…1, 기본 0. `highlights`는 기존 중립 1을 유지하고 0…2로 확장, `shadows`는 -1…1. 기존 필드의 의미를 재정의하지 않는다.
- `PhotoColorProfile: String, Codable, CaseIterable, Sendable`: `color`, `monochrome`. `EditSettings.colorProfile` 기본 `.color`. 이것은 Lighthouse 기본 색상/흑백 처리 선택이며 Adobe DCP/Camera Matching 프로필 복제가 아니다.
- `GrainSettings.roughness`: Double 0…1, 기본 0.5. 기존 amount/size/seed 보존.
- 새 키는 누락 때만 기본값. 명시 null, 잘못된 타입, 새 숫자 필드의 비유한 값·범위 초과, 알 수 없는 enum 거부. encode는 새 기본값 키 생략해 기존 카탈로그/썸네일 키를 유지. GrainSettings의 기존 키 필수 규칙 유지.
- `.global` 배치 복사에 whites/blacks/colorProfile 포함. 히스토리, 프리셋 저장/재로드, isModified와 캐시가 새 값 반영. 원본 변경 금지.

## 렌더 계약

- 기존 highlights 0…1 / shadows 0…1 조합은 기존 CIHighlightShadowAdjust 출력 유지. 이 필터에는 highlights를 min(1, value), shadows를 max(0, value)로 전달하고 기본값일 때 생략한다.
- 그 직후 추가 톤 커널 적용: positive highlight `h=max(highlights-1,0)`, negative shadow `s=min(shadows,0)`, whites `w`, blacks `b`. 모두 0이면 완전 no-op.
- sRGB 인코딩에서 각 RGB 채널 x에 순차 적용: `x += s*0.8*x*(1-x)^2`; `x += h*0.8*x*x*(1-x)`; `x += w*0.25*smoothstep(0.5,1,x)`; `x += b*0.25*(1-smoothstep(0,0.5,x))`. 마지막 0…1 clamp. 입력의 0…1 밖 채널은 보존. premultiplied alpha를 올바르게 복원/적용하고 원래 alpha·extent 유지. 각 단일 제어의 밝기 방향·단조성과 끝점 동작을 검사. Lightroom과 유사한 역할의 독자 곡선이다.
- `.color`는 no-op, `.monochrome`는 비RAW 노출/WB 처리 뒤 전역 대비 전 saturation=0 처리. RAW/JPEG 공통 preview/export 경로. 새 프로필은 RAW decoder 원본 캐시 키에 넣지 않아도 되지만 최종 렌더 캐시는 EditSettings에 따라 달라져야 한다.
- grain 커널의 랜덤 수식, 크기·seed 의미 유지. roughness=0.5는 예전 smoothstep 보간 그대로. 0…0.5는 선형 보간→기존 smoothstep 혼합, 0.5…1은 기존 smoothstep→step(0.5,frac) 혼합. seed 고정시 반복 출력 동일. amount=0이면 효과 없음. range 검증 포함.
- 실패하는 새 커널/색 공간 변환은 오류를 반환하며 조용히 효과를 누락하지 않는다. 기존 preview/export의 동일 composition 경로에서 동작한다.

## 프리셋 가져오기

- `Whites2012`, `Blacks2012`, `Highlights2012`, `Shadows2012`: -100…100. whites/blacks/shadows는 /100, highlights는 1+value/100.
- `GrainFrequency`: 0…100 → roughness /100. 누락한 값은 현재 사진값 그대로.
- payload에 optional `colorProfile: PhotoColorProfile?` 추가. 누락 nil, 명시 null/잘못된 enum은 거부. nil이면 encode 생략. 기존 payload 읽기 유지. profile-only preset 허용.
- XMP attribute/direct element와 lrtemplate string `CameraProfile`: `Default Color`, `Color` → `.color`; `Default Monochrome`, `Monochrome` → `.monochrome`. 알려진 기본 프로필만 매핑하며 매핑 경고에 실제 Lighthouse 처리와 Adobe 차이를 설명한다. 알 수 없는 Adobe/카메라 이름은 제외 경고, 임의 색감 추정 금지. 중첩 Look 프로필을 전역으로 가져오지 않는다. 중복 상충 값, 잘못된 타입 거부.
- `ConvertToGrayscale` Boolean은 별도 optional bool 입력으로 읽어 true→monochrome / false→color, 기본 프로필 매핑보다 우선한다. 알려지지 않은 프로필 자체의 경고는 유지. 새 bool을 scalar로 위장 저장하지 않는다. 최종 payload에는 선택된 colorProfile만 저장한다.
- 이전에 가져온 payload에는 제외 숫자가 저장되지 않았으므로 지원 확장을 받으려면 원본 XMP/lrtemplate을 다시 가져와야 한다. 자동 복원 주장 금지.

## 앱

- 빛 패널: 하이라이트/섀도/흰색/검정 모두 사용자 표시 -100…100, 중립 0. highlights 저장값만 1 offset. 연속 편집 한 undo와 기본값 복원 유지.
- 색상 패널의 프로필 Picker: 기본 색상 / 흑백. 도움말로 기본 색상은 macOS RAW 현상 기준, Adobe/카메라 전용 프로필과 다를 수 있음을 표시.
- 입자에 거칠기 0…100, 기본 50. 새 기능은 기존 model.updateEdits 경로 사용, 임의 전역 상태 추가 금지.
- 가져오기 호환 정보의 카운트에 profile 포함. 일괄 적용/undo/reload/누락 값 유지 검사.

## 검증·소유권

- core 담당: PhotoModels, AdvancedEditModels, BatchEditing, LightroomPresetPayload/Importer, ImagePipeline, ColorProcessing, CoreImageKernels와 새 LightroomToneTests 및 기존 LightroomPresetTests 필요한 기대값만. AutoAdjust 등 기존 다른 수정 보존.
- app 담당: InspectorView, AdvancedColorControls, LibraryModel 묶음 필요한 경우, LightroomPresetImportSheet, LightroomPresetFlowTests. core 승인 이후 소비자 편집.
- 메인 Astra: 계약/사용 안내, diff 검토, 이미지·S9 RW2 실제 렌더/JPEG/원본 SHA, 전체 swift test/build/release/codesign, 실제 앱 실행. 동일 .build 및 Sources 편집/컴파일은 직렬화. 실제 UI AX 미실행은 별도 보고.
- 핵심 검사: 누락키/옛 grain JSON/명시 null 손상/roundtrip, 부분적용/unknown profile/내보내기, 중립 및 예전 톤·grain 픽셀 유지, 새 톤 양방향·입자 차이·흑백 회귀, 그라데이션 및 실제 my.slow.film/S9 적용. Adobe와 시각 일치 여부는 비교 자료 없으므로 미검증.

## 참고

[Apple CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter) 공개 API의 RAW 현상·기본 색 처리와 [Adobe CRS namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/)의 프리셋 메타데이터를 구분한다. 공개 CIRAWFilter API에 Adobe DCP를 직접 지정하는 인터페이스는 확인되지 않았다.
