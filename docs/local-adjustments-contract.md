# 부분 보정 구현 계약 v1

사용자 요청: 사진의 특정 영역만 밝기와 대비를 조절한다. Astra가 설계하고 기존 Sol 코어·앱 작업자가 각 소유 파일을 구현한다. 추가 위임은 하지 않는다.

## 경험과 범위

- 브러시로 칠한 마스크 여러 개를 만든다. 영역별 노출(-4…4 EV), 대비(0.5…1.5), 경계 부드럽게(0…0.05, 기본 0.01)를 조절한다. 지우개, 이름, 활성화, 삭제, 마스크 표시를 제공한다.
- 부분 보정은 원본을 변경하지 않는 EditSettings의 일부이다. 기존 카탈로그가 그대로 열리고 저장·undo/redo·복사/붙여넣기·RAW/JPEG 렌더/내보내기에 모두 적용된다.
- 브러시 편집은 사진 보기/화면 맞춤/보정 보기에서 한다. 영역 편집 시작은 이 상태로 전환한다. 100%와 원본/비교/그리드로 전환하면 그리기를 중지한다. 영역 표시가 켜져도 내보내기는 마스크 색을 포함하지 않는다.
- 크롭·90도 회전을 바꿔도 같은 피사체에 마스크가 붙어 있어야 한다. 사진을 바꾸면 선택된 영역·진행 중 스트로크가 다른 사진으로 넘어가지 않는다.

## 코어 소유권 및 인터페이스

수정 허용: Sources/LighthouseCore/, Tests/LighthouseCoreTests/. 기존 변경 보존. UI/문서/스크립트는 수정하지 않는다.

PhotoModels 또는 새 파일에 모두 public Codable, Equatable, Sendable 모델:

- `MaskPoint`: `x: Double`, `y: Double`, `init(x:y:)`. 원본의 EXIF 방향 적용 후, 사용자 회전·크롭 전 이미지의 좌상단 기준 정규화 좌표(0…1).
- `MaskStroke`: `points: [MaskPoint]`, `radius: Double`, `isErasing: Bool`; `init(points:radius:isErasing:)`, isErasing 기본 false. radius는 원본 짧은 변에 대한 반지름 비율.
- `LocalAdjustment: Identifiable`: `id: UUID`, `name: String`, `isEnabled: Bool`, `exposure: Double`, `contrast: Double`, `feather: Double`, `strokes: [MaskStroke]`; public init 모든 인자 기본값(id UUID(), name "영역 1", enabled true, exposure0, contrast1, feather0.01, strokes[]).
- `EditSettings.localAdjustments: [LocalAdjustment]`, init 인자 끝에 기본 []. custom decoding에서 이 새 키의 누락만 []로 처리하고 기존 필수 필드 손상은 계속 오류. JSON 버전1 유지. isModified에 자동 포함.

`LocalMaskGeometry` public struct:

- `init(sourceWidth: Double, sourceHeight: Double, rotationQuarterTurns: Int, cropAspect: Double?)`
- `displayAspect: Double` 최종 출력 종횡비.
- `sourcePoint(fromDisplay point: MaskPoint) -> MaskPoint`: 최종 화면 정규화 좌표→원본 좌표, 중심 크롭 역변환 후 회전 역변환.
- `displayPoint(fromSource point: MaskPoint) -> MaskPoint`: 반대 변환. 잘린 원본 좌표는 0…1 밖도 허용.
- `displayRadius(fromSource radius: Double) -> Double`: 원본 짧은 변 기준 반지름→최종 화면 짧은 변 기준 반지름.

회전 좌표(좌상단 기준) 1회 시 source(x,y)→rotated(1-y,x), 2회→(1-x,1-y), 3회→(y,1-x). 회전 후 가로세로와 중앙 크롭 범위를 계산한다. 원점과 크롭 비율은 기존 pipeline과 일치시킨다.

ImagePipeline:

- 전역 보정 뒤, 사용자 회전·크롭·축소 전에 활성화된 부분 보정을 배열 순서로 적용한다. 각 영역은 현재 이미지에 CIExposureAdjust+CIColorControls를 적용한 결과를 해당 마스크로 CIBlendWithMask 합성한다. 비활성/빈 마스크/중립 보정은 건너뛴다.
- 마스크는 이미지와 같은 원점에서 CGContext 회색조 비트맵으로 래스터화한다. 검정 배경, 흰색 둥근 선/점, 지우개는 검정으로 순서대로 덮는다. radius × 원본 짧은 변을 픽셀 반지름으로, lineWidth는 두 배. 점 스트로크도 원형으로 그린다. CGImage/CIImage와 좌상단 좌표 간 Y 방향을 명시적으로 맞춘다.
- feather × 원본 짧은 변을 CIGaussianBlur 반경으로 사용해 마스크 경계를 부드럽게 한다. 먼저 clampedToExtent로 가장자리를 연장하고 blur 후 이미지 영역으로 crop하여 사진 테두리의 보정 강도가 갑자기 줄지 않게 한다. 마스크는 선형 회색 수치로 해석하여 감마가 마스크 세기를 바꾸지 않게 한다.
- public `renderMask(adjustment: LocalAdjustment, sourceWidth: Int, sourceHeight: Int, edits: EditSettings, maxPixel: Int = 1600) throws -> CGImage`: 마스크를 같은 회전·크롭 후 축소하여 회색조(검정=0,흰색=1) 이미지로 반환. UI 표시용은 처음부터 maxPixel에 맞춰 래스터를 작게 만들어도 된다. 렌더와 동일한 위치·경계. 전체 색상 렌더는 원본 해상도 마스크 사용.
- 변경 가능한 필터/CGContext는 호출 간 공유하지 않는다. 이미지 크기/배열/정규화 인자에서 invalid number, 빈 점 등은 crash 없이 처리한다. API 실패는 기존 localized error 패턴을 따른다.

코어 검사: 예전 localAdjustments 없는 JSON 로드, 새 모델 저장복원, 비대칭 위치에 그린 부분만 exposure/contrast 변화하고 밖은 동일, erase로 내부 복원, disable로 원본 복원, feather 경계 변화, 다중 영역, 회전·크롭 후 위치와 preview/full 일치, geometry roundtrip. 의미 있는 합성 픽셀 패턴과 허용오차 사용. 코어 작업자는 새 검사와 기존 검사를 실행하고 결과를 보고한다.

## 앱 소유권

수정 허용: Sources/Lighthouse/. 기존 코드 보존. 코어는 위 인터페이스를 바로 사용한다. 새 코어를 기다리는 동안 UI/상태 구현을 진행하고 준비 후 swift build한다.

- 오른쪽 별점/표시 아래에 전체/부분 보정 전환을 넣어 부분 보정이 아래로 묻히지 않게 한다. 부분 패널은 영역 추가, 영역 선택/이름/켜기·끄기/삭제, 브러시·지우개, 브러시 크기, 경계 부드럽게, 영역 노출·대비, 마스크 표시 토글, 그리기 완료를 제공한다. 영역이 없으면 사용 안내를 표시한다.
- LibraryModel에서 local 편집 선택 ID, brush/erase 모드, brushRadius(기본0.04, 범위0.005…0.2), 마스크 표시, 편집 중 상태와 mask image를 관리한다. 영역 추가/삭제/활성/수치/스트로크 모두 updateEdits로 변경한다. 한 드래그 스트로크는 mouse-up에 한번 commit하여 undo 한 번으로 지워진다. 사진 변경/필터로 선택 변경/mode/original/actualsize 변경은 진행 중 입력을 취소하며 다른 사진에 commit하지 않는다.
- 부분 패널 진입과 영역 선택/추가 시 .edit, actualSize=false, isOriginal=false로 전환하고 그리기를 활성화한다. 그리기 완료 또는 다른 보기로 전환하면 캔버스는 정상 탐색 상태. UI에 '사진 위를 드래그해 영역을 칠하세요'와 지우개 설명을 제공한다.
- 사진 보기 이미지 위에 별도 BrushCanvasView를 겹친다. 실제 scaledToFit+20pt 패딩 이미지 사각형을 기준으로만 입력받고 여백 드래그는 무시한다. 최소 거리0 드래그/클릭 둘다. geometry로 원본 좌표에 저장하고 드래그 중 경로와 원형 커서를 즉시 표시한다. 작은 이동은 점 간 거리를 고려해 샘플링한다. 그리기 UI는 뒤의 사진/필름스트립 선택을 방해하지 않는다.
- 마스크 표시 이미지는 renderMask 결과를 .luminanceToAlpha로 사용한 주황/빨강 35% 불투명 오버레이. 드래그 중 임시 경로만 빠른 Canvas 표시, 완료 뒤 정확한 feather mask로 교체한다. 비활성 영역도 범위를 볼 수 있게 mask표시는 유지할 수 있다.
- 원본 회전/크롭이 바뀌면 geometry와 mask preview도 갱신한다. 원본 보기/비교에서는 brush overlay를 숨긴다. image render와 마찬가지로 generation token으로 오래된 mask 응답을 버린다.
- 모델은 Undo/Redo 후 selectedLocalID를 실제 배열에 맞추고, 원본/전역 초기화 후 유령 영역이 남지 않게 한다. 부분 패널 선택 자체는 수정 이력에 넣지 않는다. rendering 상태에서는 이전 렌더의 크기가 다를 수 있으므로 입력을 잠시 막거나 geometry에 맞춰 확실히 처리한다.
- 메뉴/기존 가져오기/선별/전체 보정/내보내기를 유지한다. 주요 새 컨트롤 접근성 이름을 제공한다.

## 통합 검증 (Astra)

계약·실제 코드 검토, 전체 테스트/앱 빌드, 실제 창에서 드래그→부분 노출·대비→지우개→실행 취소/저장복원, S9 RW2에서 영역 안/밖 변화와 전체해상도 JPEG 출력, 이전 카탈로그 정상 로드. 검증 데이터는 .artifacts 아래 별도 카탈로그로 격리한다. 사용자 원본/보정값을 테스트로 변경하지 않는다.

통합 보완: 부분 패널 진입과 칠하기 시작 시 텍스트 초점 해제, undo/redo 시 미완료 스트로크 취소, 임시 경로·커서는 사진 범위로 clip한다. 브러시 크기는 지름 1–40%(radius×200), 경계 부드럽게는 0–100(feather×2000)으로 표시하고 저장 단위로 역변환한다.

## 확인한 공식 자료

- [CIBlendWithMask.maskImage](https://developer.apple.com/documentation/coreimage/ciblendwithmask/maskimage): 0은 배경, 1은 보정 전경을 선택하는 회색조 마스크.
- [CIImageOption.colorSpace](https://developer.apple.com/documentation/coreimage/ciimageoption/colorspace): 색상 데이터가 아닌 마스크는 NSNull로 색관리 변환을 제외한다.
