# LUT 구현 계약 — LUT-v1

2026-09-23. Astra가 설계·중요한 검증을, 기존 Sol core/app 작업자가 아래 확정 범위의 구현을 맡는다. 원본과 기존 변경을 보존하고 외부 발행·업로드는 하지 않는다.

## 사용자 경험

전체 보정 패널 맨 위에 LUT 섹션을 둔다. `.cube 불러오기…`, 적용한 이름, 켜기/끄기, 강도 0–100%, 제거를 제공한다. 한 사진에 LUT 하나를 적용하며 보정 복사/붙여넣기, 초기화, 실행 취소/재실행, 카탈로그 자동 저장에 포함한다. 선택 파일은 앱 데이터 디렉터리의 `LUTs`에 복사하므로 원래 LUT 파일을 옮겨도 유지된다. 사진용 SDR sRGB 룩을 대상으로 하며 V-Log 입력 변환 및 Panasonic `.vlt`, 1D/shaper LUT는 이번 범위가 아니다. 이 한계를 사용 안내와 불러오기 패널에 짧게 표시한다.

## 파일 소유권

- core: `Sources/LighthouseCore/PhotoModels.swift`, `ImagePipeline.swift`, 새 `CubeLUT.swift`, `LUTStore.swift`, 새 `Tests/LighthouseCoreTests/LUTTests.swift`만 편집.
- app: `Sources/Lighthouse/LibraryModel.swift`, `InspectorView.swift`만 편집. 다른 파일 변경이 필요하면 조율자에게 알린다.
- Astra: 이 문서, README/사용 안내/검증 문서와 `.artifacts/lut-validation`의 독립 검증 코드.
- 같은 파일은 한 명만 편집. 작업자는 첫 편집 전/단계 전환/완료 전 계약 메시지 본문을 확인하고 새 설계 결정은 Astra에 요청한다. 재위임하지 않는다.

## 공유 인터페이스

- `LUTAdjustment: Codable, Equatable, Sendable`: `id: String` (원문 SHA-256 소문자 64자리), `name: String`, `intensity: Double = 1`, `isEnabled: Bool = true`. public initializer. `EditSettings.lut: LUTAdjustment? = nil` trailing parameter, 누락/null은 nil, 손상된 object/type은 디코딩 오류. 기존 localAdjustments 호환 정책 유지.
- `CubeLUT: Sendable`: `title: String?`, `dimension: Int`, `cubeData: Data` (native Float RGBA, alpha 1, red-fastest), `domainMin: SIMD3<Float>`, `domainMax: SIMD3<Float>`. `static func parse(_ data: Data) throws -> CubeLUT`.
- `LUTStore: Sendable`: `init(directory: URL = LUTStore.defaultDirectory)`, public `directory: URL`, `static var defaultDirectory: URL` = CatalogStore.defaultURL의 부모/LUTs. `func importCube(from: URL) throws -> LUTAdjustment`, `func load(id: String) throws -> CubeLUT`. 한국어 LocalizedError. import는 검증 후 원문을 SHA-256.cube에 atomic 저장, 동일 내용 재사용. 제목은 TITLE의 비어있지 않은 값 또는 원래 파일명. 허용 확장자는 대소문자 무관 .cube. load는 ID를 검증하고 파일 내용 해시 일치도 검사한다. 제거는 사진에서 참조만 해제하여 다른 사진/undo가 사용하는 파일을 보존한다.
- `ImagePipeline.init(lutDirectory: URL = LUTStore.defaultDirectory)`. render/export 기존 서명 유지. app의 기본 pipeline/store는 같은 기본 디렉터리를 사용한다.

## 파서와 렌더링

1. UTF-8(BOM 허용), 빈 줄, CRLF, # 주석(따옴표 TITLE 내부 #는 보존), TITLE, LUT_3D_SIZE 2…65, DOMAIN_MIN/MAX(각 3유한값, max > min), LUT_3D_INPUT_RANGE(두 유한값, 모든 채널 공통)를 지원한다. DOMAIN과 INPUT_RANGE의 혼합/중복, 중복 SIZE, 알 수 없는 지시어, 1D/combined/shaper는 명시 오류. 모든 메타데이터는 데이터 행보다 앞에 있어야 한다. 정확히 N³개 RGB 행, 각 Float 유한값, 잘못된 숫자/행수는 오류. 파일 상한 64 MiB. 출력 RGB는 유한값이면 허용하며 SDR 출력에서 범위가 제한될 수 있다.
2. 이미지 글로벌/로컬 보정 후, 회전/크롭/축소 전에 LUT를 적용한다. Core Image 작업 공간에서 `matchedFromWorkingSpace(to: sRGB)`로 encoded sRGB에 변환 → domain 정규화 ColorMatrix → CIColorCube → `matchedToWorkingSpace(from: sRGB)`로 복귀. 무의미한 이중감마 변환을 피하기 위해 CIColorCubeWithColorSpace와 중복 사용하지 않는다. Cube alpha는 1이나 원래 사진 alpha를 보존해야 한다. 필터 실패는 무음 우회 없이 오류.
3. 켜짐 + 강도 > 0만 load/apply한다. 강도는 유한값 확인 후 0…1 제한. 0/꺼짐/없음은 LUT 파일이 없어도 원래 렌더 경로를 그대로 사용한다. 결과와 LUT 전 이미지는 작업 공간에서 강도 비율로 합성한다. 입력 extent 유지. 누락/손상 LUT는 켜진 상태에서 명확한 오류이며 잘못된 룩을 내보내지 않는다.
4. 읽기 파싱 캐시가 필요하면 pipeline 내부 NSCache를 이용하고 NSCache 외 공유 mutable 상태를 피한다. 무결성 확인을 생략하지 않도록 첫 버전은 캐시 없이 구현해도 된다. 카탈로그에는 큰 cubeData를 넣지 않는다.

## 앱 동작

불러오기는 NSOpenPanel에서 `.cube` 한 파일 선택 후 백그라운드 전용 큐에서 검증/복사한다. 불러오기 시작 사진 ID를 고정하고 완료 시 다른 사진에 적용하지 않는다. 완료 시 시작 사진이 계속 선택된 경우 최신 edits를 복사하고 LUT만 바꾸어 updateEdits를 호출한다. 선택이 바뀌면 적용하지 않았다는 메시지를 보여주며 파일 보관만 유지한다. 진행 중 버튼 비활성화, 오류는 LUT 섹션에 표시하고 기존 LUT/보정을 유지한다. 강도·활성화·제거는 updateEdits 경유. LUT import 성공 시 사진 보기와 보정 보기로 전환하여 결과를 볼 수 있게 한다. 불러오기 오류가 다른 사진에도 남지 않도록 선택 변경 시 오류를 정리한다.

## 검증 분담

Sol core: `swift test --filter LUTTests` — 파서 정상/오류/차원/행수/비유한값/도메인, 저장 dedup/이동 뒤 복원/잘못된 ID/손상/누락, 이전 카탈로그와 새 roundtrip. 픽셀 기반 identity(감마와 RGB 순서), 비선형 LUT, domain, 0/50/100%, 비활성/없음, local과 공존, alpha, 미리보기/원본크기/JPEG. 테스트 이미지는 인공 입력과 독립적으로 계산한 기대값 사용. app은 코어가 준비되기 전 전체 빌드를 반복하지 않으며 준비된 뒤 `swift build`로 연동 확인한다.

Astra: 코드/실제 파서·색공간 계약 검토, 전체 `swift test`, release app build와 codesign 확인, 실제 S9 RW2와 LUT를 적용한 UI 불러오기·강도·해제·undo·재실행·JPEG 검증. 성공 코드만을 시각 검증으로 간주하지 않는다.

색공간 근거: [Apple CIImage.matchedToWorkingSpace](https://developer.apple.com/documentation/coreimage/ciimage/matchedtoworkingspace(from:)), [Core Image Filter Reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html)의 CIColorCube 저장 순서와 작업 공간 설명.

## LUT-v1.1 검토 보완

공유 API와 파일 소유권은 동일하다. LUTStore는 import/load 모두 최대 64 MiB + 1 byte만 읽어 상한을 검사한다. 명시적 불러오기에서 이미 검증한 입력과 같은 해시 이름의 보관본이 손상되어 있으면 검증한 원문으로 atomic 복구한다. 일반 load는 무결성 오류를 계속 반환한다. 도메인 값 자체가 유한하더라도 Float의 span/정규화 scale/bias가 비유한값이 되는 범위는 파싱 오류로 처리한다.

## LUT-v1.2 성능 보완

Astra가 65³ identity LUT를 release 최적화로 3회 파싱한 결과 0.948/0.927/0.924초였다. LUTStore 내부의 NSCache(최대 8개, 32 MiB 목표)에 immutable CubeLUT를 보관한다. import는 검증한 표를 저장하고, load는 매번 bounded read와 SHA-256 일치 검사를 먼저 완료한 후 내용 해시로 캐시를 조회한다. 누락·손상 파일을 캐시로 숨기지 않는다. 공개 API와 파일 소유권은 동일하다.
