# Adobe 카메라 프로필(DCP)·캘리브레이션 계약 v1.2

2026-10-09 사용자 요청("나머지도 다 구현해줘")에 따른 세 번째 하위 프로젝트다. 처음에는 가능성 확인(스파이크)부터 하기로 했고, 스파이크 결과를 바탕으로 이 세션의 Claude가 범위를 정했다. 성공 기준은 앞의 두 하위 프로젝트와 같다: 같은 프로필·값이 같은 방향과 역할로 보인다. Adobe 현상 엔진과 같은 픽셀은 보장하지 않는다.

## 스파이크 결과(2026-10-09)

- 이 Mac에는 Camera Raw가 설치한 DCP가 있다. `/Library/Application Support/Adobe/CameraRaw/CameraProfiles/Adobe Standard/Panasonic DC-S9 Adobe Standard.dcp`와 `Camera/Panasonic DC-S9/`의 Camera Matching 14종이다.
- DCP는 매직 `0x4352`의 TIFF 형식이고 Python으로 태그를 모두 읽을 수 있었다. S9 Adobe Standard에는 ColorMatrix·ForwardMatrix 1/2(표준광 A·D65), HueSatMap 90×30×1, LookTable 36×8×16이 있고 톤 곡선은 없다. Camera Vivid 등에는 ProfileToneCurve(125점)와 LookTable 90×16×16(sRGB 인코딩)이 있다.
- `CIRAWFilter.linearSpaceFilter`는 톤 곡선 전 선형 단계에서 실행된다. 이 필터로 값을 두 배 하면 노출 +1 EV와 같은 결과가 나왔다. `boostAmount = 0`이면 Apple 톤 곡선 없이 선형 값이 나온다. 이 단계의 작업 공간은 선형 확장 sRGB다.
- 결론: Apple RAW 현상 결과를 카메라 RGB로 되돌린 뒤 DCP의 색 변환을 근사 적용할 수 있다. 실제 Adobe 렌더와 비교할 자료는 없다.

## 범위

- **DCP 프로필(RAW만):** 설치된 Adobe DCP와 사용자 DCP 폴더(`~/Library/Application Support/Adobe/CameraRaw/CameraProfiles`)의 프로필을 사진 카메라에 맞춰 고른다. Lighthouse는 DCP를 복사하거나 배포하지 않고, 사용자의 Mac에 있는 파일을 읽기만 한다.
- **캘리브레이션(모든 사진):** Lightroom의 그림자 틴트, 빨강·초록·파랑 원색의 색조·채도.
- **Adobe Raw 프로필(v1.1, RAW만):** Adobe Color·Landscape·Monochrome·Neutral·Portrait·Vivid. 아래 절을 따른다.
- **크리에이티브 프로필(v1.2, 모든 사진):** Artistic·B&W·Modern·Vintage. 아래 절을 따른다.
- 범위 밖: Adaptive 프로필(AI 게인 표), DCP 없이 Adobe 기본 톤 곡선을 재현하는 것.

## 모델과 저장

- `EditSettings.cameraProfile: String?`: DCP의 ProfileName(예: "Adobe Standard", "Camera Vivid"). nil이면 지금처럼 macOS 기본 현상이다. 1…128자, 아니면 디코드 오류. nil이면 키를 쓰지 않는다.
- `EditSettings.calibration: CalibrationSettings`: `shadowTint`, `redHue`, `redSaturation`, `greenHue`, `greenSaturation`, `blueHue`, `blueSaturation`. 모두 -1…1, 기본 0. 누락 키는 0, 범위 밖·비유한 값은 오류. 모두 0이면 키를 쓰지 않는다.
- `.global` 일괄 복사에 둘 다 포함한다. 변경 이름은 "카메라 프로필", "캘리브레이션"이다.

## DCP 찾기

- 사진 카메라 이름(`PhotoMetadata.camera`, 예: "Panasonic DC-S9")과 DCP의 UniqueCameraModel이 대소문자 무시로 같거나, 카메라 이름이 DCP 이름의 모델 부분(제조사 다음, 예: "Z 6")으로 끝나면 맞는 프로필이다. EXIF 제조사가 "NIKON CORPORATION"처럼 Adobe 이름과 달라도 찾기 위해서다.
- Adobe 폴더는 파일이 수천 개라, `Adobe Standard/<카메라> Adobe Standard.dcp`·`Camera/<카메라>/` 이름에서 얻은 카메라 이름이 맞는 `.dcp`만 연다. 사용자 폴더는 모두 연다. 파일은 16 MiB 이하만 읽는다. 목록은 폴더 수정 시각으로 캐시한다.
- 같은 이름이 여럿이면 사용자 폴더, 그다음 Adobe 폴더의 순서로 첫 파일을 쓴다.
- 렌더할 때 프로필을 찾지 못하면 macOS 기본 현상으로 그리고, Inspector에 "이 Mac에서 프로필을 찾을 수 없어 기본 색상으로 보입니다"를 보인다. 내보내기도 같다. 오류로 막지 않는 이유는 Camera Raw가 없는 Mac에서 카탈로그를 열어도 사진이 보여야 하기 때문이다.

## DCP 렌더

선형 작업 공간(선형 sRGB, D65) 값에 다음을 적용하는 64³ 큐브를 만든다. 입력·출력은 `e = log2(1 + 32x) / log2(1 + 32·4)` 모양으로 0…4를 담고, 음수는 0으로 자른다.

1. 색온도 가중치: RAW 현상의 중립 색온도 T로 `w = clamp((1/T - 1/T2) / (1/T1 - 1/T2), 0, 1)`(T1·T2는 두 표준광의 색온도). ForwardMatrix와 HueSatMap 1/2를 이 가중치로 섞는다. 가중치는 0.05 단위로 반올림해 큐브를 캐시한다.
2. 행렬: `XYZ(D50) ← 선형 sRGB`(Bradford), 이어서 `FM_프로필 · FM_AdobeStandard⁻¹`. 같은 카메라의 Adobe Standard DCP를 "macOS 현상 결과 = 색 측정상 맞는 값"의 기준으로 보고 카메라 RGB를 되돌린다. Adobe Standard 자신은 단위 행렬이 된다. Adobe Standard가 없으면 단위 행렬을 쓴다. 그다음 ProPhoto 선형 RGB로 바꾼다.
3. HueSatMap → `2^BaselineExposureOffset` → LookTable → ProfileToneCurve(있을 때만). 표 보간·HSV 정의·인코딩(sRGB)·RGB 톤(가장 큰·작은 채널에 곡선, 가운데는 비율 유지)은 DNG 명세 1.6과 Adobe DNG SDK 참조 구현을 따른다. 1보다 큰 값은 표 조회에 1을 쓰고 같은 배율을 적용해 밝은 부분을 자르지 않는다. 톤 곡선 입력은 0…1로 자른다.
4. 다시 선형 sRGB로 바꾼다.

- 톤 곡선이 있는 프로필(Camera 계열)은 `boostAmount = 0`으로 Apple 톤 곡선을 끄고 DCP 곡선을 쓴다. 톤 곡선이 없는 프로필(Adobe Standard)은 Adobe 기본 곡선 대신 Apple 톤 곡선을 그대로 쓴다(근사, Adobe 기본 곡선 표를 갖고 있지 않다).
- 큐브는 `CIRAWFilter.linearSpaceFilter`로 넣는다. 현상 캐시·노이즈 감소 캐시 키에 프로필 이름과 파일(경로·수정 시각)을 넣는다.
- 스마트 미리보기에는 적용되지 않는다(원본 RAW가 없으므로).

## 캘리브레이션 렌더

현상 직후(화이트밸런스 다음, 디헤이즈 앞) 선형 작업 공간에서 모든 사진에 적용한다.

- 원색 i(빨강·초록·파랑 단위 벡터)의 채도 벡터 `c_i = e_i - 1/3`을 회색 축 둘레로 `hue_i·30°` 돌리고 `1 + 0.5·sat_i`배 한다. 새 원색 `p_i = 1/3 + c_i'`로 행렬 `M = [p_r p_g p_b]`를 만들고, 흰색이 흰색으로 남도록 `M' = M + (1 - M·1)·Yᵀ`(Y는 Rec.709 밝기 가중치)로 보정한다. +는 색조가 커지는 방향(빨강→주황, 초록→청록, 파랑→보라)이다.
- 그림자 틴트: 밝기 Y가 0.25보다 어두운 곳에 `0.2·a·4Y(1 - Y/0.25)²·d`를 더한다. d는 밝기 0인 마젠타 방향, +는 마젠타, -는 초록이다. 결과는 0 아래로 내리지 않는다.
- 모두 0이면 건너뛰어 기존 출력과 픽셀이 같다.

## 앱

- 색상 섹션: RAW 사진에 "카메라 프로필" 메뉴. "macOS 기본"과 이 카메라에 맞는 DCP 이름을 보인다. 고르면 실행 취소 1단계다. 저장된 프로필을 찾지 못하면 안내 문구를 보인다.
- "캘리브레이션" 묶음: 그림자 틴트, 빨강/초록/파랑 색조·채도 슬라이더(-100…100). 컬러 그레이딩 다음, 필름 입자 앞.

## 프리셋 가져오기

- `CameraProfile`: "Adobe Standard"와 "Camera …"는 `cameraProfile`에 그 이름을 넣는다(색상 프로필은 기본 색상). 기존 Default Color/Monochrome 매핑은 그대로다. "Adobe Color" 등 Look 기반 이름은 지금처럼 제외 경고를 낸다. DCP 매핑에는 "카메라 프로필은 이 Mac에 설치된 DCP로 근사하며 Adobe 결과와 다를 수 있습니다." 경고를 붙인다.
- `ShadowTint`, `RedHue`, `RedSaturation`, `GreenHue`, `GreenSaturation`, `BlueHue`, `BlueSaturation`: -100…100, ÷100. 하나라도 있으면 "캘리브레이션은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다." 경고.

## Adobe Raw 프로필(v1.1)

2026-10-09 사용자 요청("Adobe Color 프로필도 구현해줘")으로 더했다.

- 위치: `/Library/Application Support/Adobe/CameraRaw/Settings/Adobe/Profiles/Adobe Raw/*.xmp`(Camera Raw 설치본). 읽기만 한다. 파일은 4 MiB 이하, DTD·entity가 있으면 읽지 않는다.
- 구조(설치본 6종 확인): `PresetType="Look"`, 기준 프로필 `CameraProfile="Adobe Standard"`, `LookTable`이 가리키는 `Table_<MD5>` 문자열, `ToneCurvePV2012`(+R/G/B), 일부는 `Clarity2012`·`Highlights2012`·`Shadows2012`, Monochrome은 `ConvertToGrayscale="True"`.
- 표 문자열: DNG SDK의 85문자 인코딩(4바이트를 리틀 엔디언 정수로 보고 85진수 5자, 낮은 자리부터) → 앞 4바이트는 압축 전 길이 → zlib. 풀면 리틀 엔디언 `종류(0=LookTable), 버전, 색조·채도·명도 칸 수, (색조 이동·채도·명도) float × 칸, 인코딩`이다. 종류가 0이 아니거나 길이가 맞지 않으면 그 프로필은 쓰지 않는다.
- 렌더: 사진 카메라의 Adobe Standard DCP 변환 뒤(DCP LookTable 다음)에 이 표를 같은 보간으로 적용해 같은 선형 단계 큐브에 넣는다. Adobe Standard DCP를 찾지 못하면 프로필 전체를 찾지 못한 것으로 보고 macOS 기본으로 그린다.
- 프로필의 톤 곡선은 현상 직후 sRGB 인코딩 값에 Lighthouse 곡선으로 적용한다(사용자 곡선과 별도). 명료도·하이라이트·섀도는 사용자 값에 더하고(Adobe 단위 ÷100) 범위로 자른다. `ConvertToGrayscale`이면 흑백으로 그린다. 사용자 슬라이더 값은 바꾸지 않는다.
- 메뉴: Adobe Raw 프로필(이름순) → Adobe Standard → Camera 계열. 프리셋의 `CameraProfile`이 이 여섯 이름이면 같은 이름으로 연결한다.
- 현상 캐시 키에 Look 파일(경로·수정 시각)과 기준 DCP를 넣는다.

## 크리에이티브 프로필(v1.2)

2026-10-09 사용자 요청("크리에이티브 프로필도 구현해줘")으로 더했다.

- 위치: Camera Raw 설치본 `Settings/Adobe/Profiles/{Artistic,B&W,Modern,Vintage}/*.xmp`(이 Mac에서 50개). 읽기만 한다. `Adaptive`, `Adobe Raw`, `Camera` 폴더는 이 목록에 넣지 않는다.
- 구성(설치본 확인): 모두 `LookTable`(Adobe Color와 같은 표)이 있고, 대부분 `RGBTable`과 `RGBTableAmount`가 있다. 일부는 톤 곡선, 노출·대비·하이라이트·섀도·흰색·검정·명료도·채도, HSL, 흑백 믹서(`GrayMixer*`), 분할 톤, 비네팅, 흑백 변환을 담는다.
- RGBTable 표(확인한 형식): 리틀 엔디언 `종류 1, 버전 1, 차원 3, 칸 수 N`, 이어서 r(가장 바깥)·g·b(가장 안쪽) 순서의 N³×3 uint16. 값은 항등값 `(i·65535 + (N-1)/2) / (N-1)`과의 차이를 65536으로 감아 저장한다. 뒤에 원색(0 sRGB, 1 Adobe RGB, 2 ProPhoto, 3 P3, 4 Rec.2020), 감마(0 선형, 1 sRGB, 2 1.8, 3 2.2), 색역(0 자르기), 최소·최대 양(double)이 온다.
- 적용 양: `프로필 양`(0…200%, 기본 100%)을 둔다. RGB 표는 `RGBTableAmount(없으면 1) × 프로필 양`을 표의 최소·최대 양으로 자른 값으로, 표의 인코딩 공간에서 `입력 + 양·(표(입력) - 입력)`이다. 0…1 밖의 값은 자른 점의 변화량을 더해 넘는 부분을 보존한다. LookTable은 양과 관계없이 그대로 쓴다. 프로필에 든 곡선·조정값은 프로필 양을 곱해 쓴다(곡선은 항등선과 섞는다).
- RAW: 같은 카메라의 Adobe Standard DCP(있을 때) → LookTable → RGB 표를 선형 단계 큐브에 넣는다. Adobe Standard가 없으면 DCP 없이 LookTable·RGB 표만 넣는다.
- RAW가 아닌 사진: 현상 직후 선형 작업 공간 값에 같은 큐브(DCP 없이)를 적용한다. 그래서 `cameraProfile`은 크리에이티브 프로필이면 JPEG·HEIC에도 저장하고 쓴다.
- 프로필 안의 설정: 노출·대비·하이라이트·섀도·흰색·검정·명료도·채도·생동감·비네팅 양은 사용자 값에 더한다. 곡선·HSL·흑백 믹서는 흑백 변환 전에, 분할 톤은 흑백 변환 뒤에 Lighthouse 처리로 적용한다. 흑백 믹서는 같은 색 범위의 HSL 명도(÷100)로 근사한다. 파라메트릭 곡선, 증분 색온도·틴트, 비네팅의 양 외 항목은 적용하지 않는다(알려진 한계).
- 모델: `EditSettings.profileAmount` 0…2, 기본 1, 1이면 저장하지 않는다. 범위 밖은 디코드 오류. 일괄 복사에 포함하고 변경 이름은 "카메라 프로필"에 묶는다.
- 메뉴: RAW는 Adobe Raw → Adobe Standard → 카메라 매칭 → 크리에이티브(그룹 이름순), JPEG 등은 macOS 기본과 크리에이티브만. 양을 지원하는 프로필이면 "프로필 양" 슬라이더를 보인다.
- 프리셋: `CameraProfile`과 `crs:Look`(Name·Amount, XMP 중첩 Description과 lrtemplate `Look` table)을 읽는다. Look 이름이 있으면 그것을 쓰고 양은 0…2로 받는다. 크리에이티브 이름은 Artistic·B&W·Modern·Vintage 접두사로 알아본다.

## 검증

- DCP 파서: 테스트 안에서 만든 작은 DCP(일반 TIFF·`0x4352` 매직, 리틀·빅 엔디언), 잘못된 개수·크기·잘린 파일 거부.
- 변환: 단위 표는 무변화, 색조 이동 표는 색조를 돌림, sRGB 인코딩 3D 표의 값 보간, RGB 톤의 비율 유지, 색온도 가중치, 1보다 큰 값 보존.
- 찾기: 임시 폴더의 Adobe·사용자 구조에서 카메라 이름 일치, 사용자 폴더 우선.
- 캘리브레이션: 0이면 단위 행렬, 흰색 보존, 색조 방향, 채도 방향, 그림자 틴트 방향, 미리보기·내보내기 일치.
- 가져오기·앱: 키 범위, CameraProfile 매핑과 경고, 메뉴 선택 1단계 실행 취소.
- 크리에이티브: RGB 표 디코드(차이 감기·순서), 양 0이면 무변화, 1 밖 값 보존, JPEG 적용, 프리셋 Look 이름·양, 실제 S9·JPEG에서 렌더가 바뀌고 B&W 프로필이 무채색.
- Adobe Raw: 표 인코딩 왕복(테스트에서 만든 표), 잘못된 문자·길이·종류 거부, 곡선·조정값·흑백 읽기, 기준 DCP 없으면 사용 불가, 실제 S9에서 Adobe Color가 Adobe Standard와 다르고 Adobe Monochrome이 무채색.
- 실제 S9 RW2와 설치된 DCP로 macOS 기본·Adobe Standard·Camera Vivid·Camera Monochrome·Camera Flat을 렌더해 방향(Vivid 채도↑, Monochrome 무채색, Flat 대비↓)을 보고 원본 SHA를 확인한다. DCP 파일은 Git에 넣지 않는다.
