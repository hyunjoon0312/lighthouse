# 고급 보정 확장 계약 v1

2026-09-23 · 사용자가 승인한 여섯 기능: 피사체/배경 자동 마스크, RGB 곡선과 색상 범위 HSL, 자유 크롭·수평, 복제·스팟 복구, 필름 입자, 실제 JPEG 압축 미리보기. 기존 원본 보존·로컬 처리·실행 취소·일괄 적용을 유지한다. Compositor의 사용 경험을 참고하되 구현 코드는 새로 작성한다.

## 저장 모델 (먼저 확정할 공용 API)

새 타입은 public Codable, Equatable, Sendable이며 기본값이 있는 public init을 제공한다. 기존 필수 필드의 잘못된 타입은 계속 오류다. 새 비선택 필드는 키가 없을 때만 기본값을 쓰고 명시적 null/잘못된 타입은 거부한다. 선택 필드만 누락/null을 nil로 읽는다.

- `CurvePoint(x: Double, y: Double)`: 좌표 0…1.
- `ToneCurves(master: [CurvePoint], red: [CurvePoint], green: [CurvePoint], blue: [CurvePoint])`: 각 기본값 [(0,0),(1,1)]. `static identity`, `isIdentity`. 각 채널 2…16개, x 오름차순·서로 다른 값·양끝 x=0/1, 모든 좌표 유한 0…1. 잘못된 곡선은 디코딩 오류 및 처리 API에서 명시적 오류. y는 비단조 곡선도 허용한다.
- `ColorBand: String, Codable, CaseIterable, Sendable`: red, orange, yellow, green, aqua, blue, purple, magenta. 중심 hue는 각각 0,30,60,120,180,240,270,300도.
- `ColorRangeAdjustment(band: ColorBand, hue: Double=0, saturation: Double=0, lightness: Double=0)`: hue -30…30도, saturation/lightness -1…1. `EditSettings.colorRanges`는 기본 []이며 동일 band 중복을 처리 경계에서 거부한다.
- `GrainSettings(amount: Double=0, size: Double=1.5, seed: UInt32=1)`: amount 0…1, size 0.5…8 원본 픽셀. seed를 저장하여 같은 상태를 다시 열어도 무늬가 바뀌지 않는다.
- `NormalizedCrop(x: Double=0, y: Double=0, width: Double=1, height: Double=1)`: 수평 보정 후 안전 캔버스 좌상단 정규화 좌표. 폭/높이 최소 0.02, 전체 0…1 안. `static full`, `clamped`가 유한하지 않으면 full, 나머지는 최소 크기와 경계로 보정한다.
- `RasterMask(width: Int, height: Int, pngData: Data)`: EXIF 방향이 반영된 원본 좌상단에 맞는 선형 회색조 PNG. 긴 변 최대 1536, 데이터 최대 8 MiB, 실제 디코드 크기가 선언 크기와 일치해야 한다. 검증은 이미지 소비 경계에서 수행하고 오류를 숨기지 않는다.
- `RetouchMode: String, Codable, CaseIterable, Sendable`: heal, clone.
- `RetouchStroke: Identifiable`: id UUID, mode RetouchMode, points [MaskPoint], radius Double(원본 짧은 변 비율), sourceOffset MaskPoint? (clone의 source minus first destination 정규화 이동량), isEnabled Bool=true. 기본 mode heal, points [], radius 0.02, sourceOffset nil. clone은 유한한 sourceOffset 필수이며 heal은 자동으로 원본 영역 안의 주변 패치를 고른다.
- `LocalAdjustment`에 `baseMask: RasterMask? = nil`, `isInverted: Bool = false` 추가. baseMask → 반전 → 기존 brush/erase strokes → feather 순서다. 따라서 자동 선택 결과를 기존 브러시/지우개로 수정할 수 있다. 빈 base/빈 strokes의 기존 영역은 여전히 효과가 없다.
- `EditSettings` 끝에 `curves: ToneCurves = .identity`, `colorRanges: [ColorRangeAdjustment] = []`, `grain: GrainSettings = GrainSettings()`, `straightenDegrees: Double=0`, `cropRect: NormalizedCrop?=nil`, `retouchStrokes: [RetouchStroke]=[]` 추가. 기존 init 호출 유지. 모든 새 설정은 저장·복원·isModified·undo 대상이다.
- `EditComponents.global`은 curves/colorRanges/grain도 복사, `.geometry`는 straightenDegrees/cropRect도 복사, 새 `.retouch` rawValue 16은 retouchStrokes만 복사, `.all`에 포함한다. `.local`은 기존 자동 마스크 포함 배열을 그대로 복사한다. UI는 자동 마스크/복제 위치가 대상 사진마다 재인식되는 것이 아니라 같은 정규화 위치로 복사됨을 알린다.

## 공통 좌표 API

`PhotoGeometry`는 CoreGraphics를 사용한 public struct다. init(sourceWidth: Double, sourceHeight: Double, edits: EditSettings), 속성 `canvasSize: CGSize`, `cropBounds: CGRect`(안전 캔버스의 좌상단 픽셀), `outputSize: CGSize`, `sourceToCanvas: CGAffineTransform`(좌상단 원본 픽셀→좌상단 안전 캔버스), `ciTransform: CGAffineTransform`(CI 좌하단 원본→CI 좌하단 안전 캔버스), `ciCropBounds: CGRect`, `displayAspect: Double`, 함수 `sourcePoint(fromDisplay:)`, `displayPoint(fromSource:)`, `displayRadius(fromSource:)`를 제공한다.

1. 원본 width/height는 유한 양수, 아니면 1. 시계방향 quarter turn을 먼저 적용한다. 1회는 (x,y)→(H-y,x), 2회는 (W-x,H-y), 3회는 (y,W-x).
2. 회전된 크기를 W,H라 할 때 angle은 유한 -20…20도(그 밖은 clamp, NaN은0), 좌상단 좌표에서 양수는 시계방향. 중심 기준 회전한 뒤 안전 영역만 남긴다. c=cos(abs(angle)), s=sin(abs(angle)), k=min(W/(W*c+H*s), H/(W*s+H*c)), 안전 캔버스는 W*k,H*k. 회전 중심을 안전 캔버스 중심으로 옮긴다. 이 내부 사각형으로 투명한 삼각 모서리를 제거한다.
3. cropRect가 있으면 clamped 사각형을 안전 캔버스에 곱한다. 없으면 기존 cropAspect에 따른 중앙 크롭, 둘 다 없으면 전체 안전 캔버스. legacy angle0/rectnil의 치수와 좌표는 기존과 동일해야 한다.
4. CI 변환은 원본 좌하단→원본 좌상단(y=sourceHeight-y)→sourceToCanvas→캔버스 좌하단(y=canvasHeight-y). crop의 CI y는 canvasHeight-cropBounds.maxY. 최종 crop 후 원점을0으로 옮긴다.
5. display↔source는 위 affine의 정확한 역변환 및 crop 원점을 이용한다. 크롭 밖 좌표도 unclamped로 반환한다. 반지름은 sourceShortSide/outputShortSide 비율을 적용한다.

`LocalMaskGeometry` 기존 init은 유지하되 `straightenDegrees: Double=0, cropRect: NormalizedCrop?=nil` 인자를 끝에 추가하여 내부에서 PhotoGeometry에 위임한다. 새 `init(sourceWidth:sourceHeight:edits:)`도 제공한다. 화면·마스크·이미지·복제 위치는 모두 이 정의를 사용한다.

## 처리 순서와 API

전체 해상도 CI 처리 → 마지막 출력 축소를 유지한다. 사진 데이터를 중간 8비트 래스터로 변환하지 않는다(마스크 및 자동 패치 탐색용 작은 분석 이미지는 예외). 순서는 RAW/EXIF 및 기존 전체 보정 → 원점 정규화 → retouch → curves/HSL → local → LUT → grain → PhotoGeometry 회전/안전 크롭/자유 크롭 → 최종 축소 → sRGB CGImage다. neutral 기능은 빠르게 우회하고 기존 결과를 유지한다. 참조 색감 API는 기존대로 LUT만 제외하므로 새 보정들도 소스 분석에 들어간다. 공간 보정·마스크·입자는 생성 LUT 자체에 포함되지 않는다.

### ColorProcessing.swift (독립 구현)

public `AdvancedColorProcessor.applyColor(to: CIImage, curves: ToneCurves, ranges: [ColorRangeAdjustment]) throws -> CIImage`, `applyGrain(to: CIImage, settings: GrainSettings) throws -> CIImage`. 공개 enum 또는 struct의 static 함수다. 명시적 localized error 타입을 새 파일에 둔다.

- 곡선은 master 후 개별 RGB 순서. x구간의 기울기에서 부호가 바뀌면 접선0, 같은 부호면 조화평균을 쓰는 shape-preserving cubic Hermite, 구간 y범위로 제한한다. public `curveValue(_ value: Double, points: [CurvePoint]) throws -> Double`로 단위 검증 가능하게 한다.
- 곡선/HSL은 기존 LUT와 같은 sRGB 수치에서 처리한다. 작업공간→sRGB 수치→CIColorCube(64³ Float, red-fastest)→작업공간 복귀. 0…1 SDR 도메인에 적용되며 비중립 설정에서 도메인 밖 값은 경계로 제한한다. 8비트 이미지 변환은 하지 않는다. 곡선 입력 결과를 HSL로 바꾸고 색상대별 영향을 합산한다.
- 범위 가중치는 원래 HSL hue와 중심 hue의 최단 각거리로, ±45° 밖0, 안은 0.5*(1+cos(pi*distance/45)). 중립에 가까운 픽셀에서 hue 변화가 불안정하지 않게 hue 효과는 saturation으로 감쇠한다. hue 변화는 가중 합; saturation/lightness는 각각 현재 값에 가중 합을 더해0…1 제한(명도는 합×0.5). 순서에 따라 결과가 바뀌지 않게 모든 범위는 원래 HSL에서 계산한다. public `transformRGB(_ rgb: SIMD3<Double>, curves: ToneCurves, ranges: [ColorRangeAdjustment]) throws -> SIMD3<Double>` 제공한다.
- 생성 색상표는 불변 데이터만 제한된 잠금 캐시(최근4개)로 재사용하여 입자/마스크 조절 시 재계산을 줄인다. CIFilter는 호출별 생성. 유한성/범위 검증은 표 생성 전에 한번 수행하고 내부 반복에서 반복 검증하지 않는다.
- 입자는 amount0이면 정확히 우회한다. CIColorKernel로 원본 destCoord/size의 격자, seed를 사용하는 결정적 단색 value noise를 만든다. 해시(fract(sin(dot(cell, vec2(12.9898,78.233))+seed)*43758.5453)) 네 모서리를 smoothstep 보간한다. sRGB의 RGB에 (noise-0.5)*amount*0.22를 더하고 알파 유지 후 작업공간 복귀한다. 출력 크기와 무관하게 전체 해상도에서 계산하므로 미리보기는 동일한 결과의 축소다. 커널 생성/처리 실패는 효과를 숨기지 말고 오류로 알린다.

### ImagePipeline와 새 처리 파일 (단일 소유자)

- 자동 선택: `public func subjectMask(url: URL) throws -> RasterMask`. neutral full-source 이미지를 max1536으로 render한 뒤 Vision VNGenerateForegroundInstanceMaskRequest를 로컬 실행한다. allInstances를 generateScaledMaskForImage로 합쳐 회색조 PNG로 반환한다. 결과 없음/실패는 localized error, 가짜 마스크로 대체하지 않는다. 방향은 render의 EXIF 적용 상태 .up. 저장된 결과 사용 시 Vision을 재실행하지 않는다. baseMask는 PNG 서명·크기·byte 한도/실제 치수 검사 후 선형 데이터로 읽고 원본 크기로 맞춘다.
- maskImage는 baseMask를 회색 bitmap에 먼저 그린다. isInverted는 base가 없을 때도 전체 영역을 만들 수 있지만 neutral empty 기존 영역은 유지한다. 이후 brush 흰색/erase검정과 feather. local 적용 guard는 baseMask 또는 isInverted 또는 strokes 존재를 고려한다. renderMask의 축소 비율은 PhotoGeometry.outputSize를 사용한다.
- retouch는 순서대로 적용한다. clone은 sourceOffset을 원본 pixels로 환산하고 해당 source를 destination으로 이동, 부드러운 원형/선 마스크로 합성한다. 사진 밖의 source는 검정/투명 얼룩이 되지 않도록 source 지원 범위를 마스크에 곱한다. radius clamp 0.002…0.15, 유한 좌표 검사. 개별 비활성/빈 stroke는 우회한다.
- heal은 작은 먼지/잡티용 주변 패치 복구다. 매 stroke의 현재 CI 이미지를 max256 sRGB 분석 래스터로 만들고 첫 점 주위 3r와5r 거리의8방향 후보를 평가한다. 후보 및 전체 번역 경로가 원본 내부에 있으며 목적 경로와 겹치지 않는 후보만 사용한다. 목적 점 경계(반경1.2r)의8개 샘플과 후보 경계 색상의 MSE가 가장 작은 후보를 고른다. 동률은 고정 순서. 후보가 없으면 명시적 오류(크기 축소 안내). 선택한 패치를 clone처럼 옮긴 뒤 Gaussian 저주파(source/target, sigma radius*0.6)를 빼고 더해 지역 밝기 차를 줄인다. CIColorKernel로 source + lowTarget - lowSource, 알파 보존. feather radius*0.25. 생성형 대형 객체 제거를 주장하지 않는다.
- `JPEGPreview: @unchecked Sendable` (CGImage), public let data Data, image CGImage(압축된 data를 실제 디코드), width/height Int 또는 image 치수 computed. `public func prepareJPEG(url:edits:maxPixel:quality:) throws -> JPEGPreview`, `public func writeJPEG(_ data: Data, sourceURL: URL, to directory: URL) throws -> URL`. exportJPEG는 prepare→write를 사용한다. 기존 exclusive create/O_EXCL 충돌 회피를 그대로 보존한다.
- 기존 transformedForDisplay를 PhotoGeometry로 교체하고 source bounds 정규화→ciTransform→ciCropBounds crop→0origin→축소한다.

## 화면·상태 계약 (앱 단일 소유자)

- 전체/부분/복구 패널. 전체 보정에 곡선 채널(RGB,R,G,B) 그래프를 제공한다. 클릭하여 점 추가, 점 드래그 x순서 유지, 선택한 내부 점 삭제, 채널 초기화. 끝점 x는 고정. 각 HSL band 선택 후 hue/saturation/lightness 슬라이더, 초기화. 입자 양·크기·패턴 새로 만들기 버튼, amount0 기본. 모든 변경은 updateEdits를 사용한다.
- 부분 보정 상단 피사체 선택/배경 선택 버튼. 무거운 Vision 처리는 전용 queue에, request token + photo ID + 전체 edits snapshot + selection generation을 캡처한다. 선택/편집이 바뀌거나 취소되면 결과 폐기하고 상태를 해제한다. 성공하면 새 LocalAdjustment(baseMask:, isInverted:background, name:)를 하나 추가하고 기존 부분 패널로 들어간다. 자동 선택은 실제 사람 외 foreground objects일 수도 있다. 실패/취소 표시와 기존 브러시 대안 안내. 기존 영역 목록과 refine UX 유지.
- 자유 크롭은 `cropSource: PhotoAsset?` 시트로 스냅샷을 연다(hasModalPresentation 포함). 시트 자체에서 cropRect=nil/cropAspect=nil인 편집본을 렌더해 안전 캔버스 전체를 보여준다. -20…20도 수평 슬라이더, free/1:1/4:5/3:2/16:9 비율, drag-inside 이동·네 모서리 resize, thirds 가이드·어두운 바깥영역, 초기화/취소/적용. 비율은 픽셀 종횡비를 정규화로 바꾸어 유지한다. 각도 변경 중 stale preview는 token으로 폐기하고 렌더가 맞을 때만 crop 조작/적용. 적용 한 번에 한 undo. 과거 중앙 비율 crop을 열면 PhotoGeometry의 현재 cropBounds를 정규화한 위치로 시작한다. 저장은 cropRect, cropAspect=nil, straightenDegrees. 기존 90° 회전은 남기되 새 cropRect는 리셋하여 이전 방향 프레임의 혼동을 막는다.
- 복구는 heal/clone 모드, 크기, 작업 목록·활성화/삭제·전체 지우기. heal은 클릭/짧은 드래그, clone은 '소스 선택' 버튼 뒤 사진 클릭, 그 뒤 그리기. source 선택 및 destination은 공통 geometry로 원본 정규화 변환한다. 한 stroke를 mouse-up 한 번에 commit. source 마커/brush preview 표시. 사진·패널·보기 전환·undo 중 draft 취소; clone source는 사진 전환 시 초기화. rendering/original/100%에서는 현재 local brush와 같은 제한. 반전 mask 오버레이가 복구 패널에 남지 않게 한다.
- ExportSheet를 독립 파일로 이동하고 실제 JPEGPreview와 파일 크기, 픽셀 치수를 보여준다. 품질/긴 변/대상 변경은 debounce→직렬 백그라운드 encode→token/cancellation 검증. fit/100% 보기로 압축 상태 확인. 한 장은 실제 저장할 data를 재사용한다. 배치는 대표 사진 한 장의 크기임을 명시하고 선택 count/옵션을 고정 스냅샷으로 내보낸다. LibraryModel.export에 기본 nil 인자 `prepared: PreparedJPEGExport?`(앱 타입, photo ID/edits/maxPixel/quality/result) 추가하여 정확히 일치하는 사진에만 준비된 bytes를 writeJPEG로 저장, 나머지 사진은 같은 옵션으로 exportJPEG. 검사 중/오류/오래된 결과에서는 내보내기 비활성. 내보내는 중 품질/크기/대상/폴더도 비활성으로 실제 옵션과 화면을 일치시킨다.
- BatchEditSheet에 복구 별도 체크박스 추가, 전역은 곡선·색상 범위·입자 포함임을 표시. 복구/마스크가 대상별 재인식되지 않음을 간결하게 안내한다. 메뉴/keyboard modal guard 유지, 새 컨트롤 접근성 이름 제공.

## 검증과 인계

모델/좌표: 이전 JSON 누락 기본값, 새 키 null/잘못된 타입 오류, 모든 설정 roundtrip, selective batch 및 atomic undo, legacy geometry, 다양한 angle/turn/crop에서 왕복과 mask 위치/출력 치수·안전 모서리.

색/입자: identity 정확 우회, 곡선 endpoint·비단조·중간점·잘못된 점 거부, 서로 다른 HSL band 픽셀 변화와 중립/범위 밖 유지, alpha·색 공간 경계, deterministic seed/size/amount, preview가 full의 축소와 일치.

이미징: 비대칭 base mask+invert+erase 저장복원, clone 특정 source 색/texture와 다른 영역 보존, heal 작은 점의 경계 오차 감소·유한 결과, JPEG decoded preview와 파일 bytes 동일·치수·품질 크기·기존 파일 보존. 실제 S9 RW2에도 새 처리를 수행하고 원본 SHA256 비교. Vision 성공은 실제 foreground fixture로 확인하고 OS 모델 미가용은 명시한다.

앱: 실제 실행·마스크 버튼/취소·곡선·색상 슬라이더·crop 이동/resize/수평·clone source→stroke·undo·입자·export 품질/100%·batch·재실행. UI 도구가 창을 가져오지 못하면 실제 오류로 기록하고 빌드/모델 검사로 대체 통과하지 않는다. 전체 swift test/build, release app 및 codesign. 저장 호환·색·좌표·비동기 결합은 Astra 최종 독립 검토.
