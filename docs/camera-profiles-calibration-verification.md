# Adobe 카메라 프로필(DCP)·캘리브레이션 검증 기록

2026-10-09, [계약 v1](camera-profiles-calibration-contract.md) 기준. 실행 산출물은 Git에 넣지 않는 `.artifacts/camera-profiles-20261009/`에 있다. DCP 파일은 이 Mac에 설치된 것을 읽기만 했고 저장소에 넣지 않았다.

## 자동 검사

| 범위 | 명령 | 결과 |
|---|---|---|
| DCP 읽기·변환·찾기·캘리브레이션·가져오기·실제 S9 | `swift test --filter CameraProfileTests` | 14개 통과 |
| 기능을 끈 코드(RED 확인) | 같은 명령, `linearSpaceFilter` 연결·캘리브레이션 호출·1 위 명도 보존을 잠시 제거 | 4개 검사 실패(7건) — 세 동작을 모두 잡는다 |
| 앱 흐름 | `swift test --filter CameraProfileFlowTests` | 2개 통과(실제 S9 RW2와 설치된 DCP 포함) |
| 전체 1회차 | `swift test` | 396개 중 7 skip, 실패 1 — 아래 참고 |
| 전체 2회차 | `swift test` | 396개 중 7 skip, 실패 0 |
| 빌드 | `./scripts/build-app.sh`(64.5초), `codesign --verify --deep --strict dist/Lighthouse.app`, `git diff --check` | 모두 통과 |

- 1회차 실패는 기존 `LightroomPresetTests.testDefaultProfilesAndGrayscaleOverride`가 "Camera Standard"를 지원하지 않는 프로필의 예로 쓴 것이다. 이제 DCP로 연결하므로 아직 지원하지 않는 "Adobe Color"로 바꿨다.
- 처음 쓴 `testForwardMatrixDifferenceUsesReferenceProfile`은 테스트 프로필의 노출 오프셋(+0.25 EV)을 빠뜨린 기대값이라 실패했다. 기대값을 고쳤다.

## 실제 RAW

`probe`로 LUMIX S9 RW2를 장변 1600px로 렌더했다(디버그 빌드). 결과는 `ALL_OK`이다.

| 케이스 | 평균 RGB | 채도(최대-최소 평균) | 밝기 표준편차 | 시간 |
|---|---|---|---|---|
| macOS 기본 | 91.6 88.5 86.8 | 10.28 | 63.31 | 첫 렌더 |
| Adobe Standard | 93.1 88.9 86.2 | 15.27 | 62.88 | 2.19초 |
| Camera Standard | 93.0 88.8 85.8 | 18.19 | 64.15 | 1.58초 |
| Camera Vivid | 89.0 83.8 81.2 | 19.54 | 66.83 | 1.56초 |
| Camera Monochrome | 89.6 89.6 89.6 | 0.00 | 64.33 | 1.61초 |
| Camera Flat | 104.2 100.0 97.7 | 14.91 | 54.56 | 1.56초 |
| Camera Natural | 99.4 94.4 91.9 | 16.96 | 61.18 | 1.56초 |
| 캘리브레이션 파랑 채도 +100 | 91.8 88.8 85.6 | 13.54 | 63.28 | 0.49초 |
| 캘리브레이션 빨강 색조 +100 | 91.4 89.5 86.1 | 10.59 | 63.44 | 0.49초 |
| 캘리브레이션 그림자 틴트 +100 | 98.1 85.5 93.9 | 16.44 | 63.47 | 0.98초 |

- Vivid는 Standard보다 진하고, Monochrome은 무채색이며, Flat은 대비가 낮다. 톤 곡선을 DCP 것으로 바꾼 Camera 계열의 밝기도 macOS 기본과 비슷하다.
- Adobe Standard·Vivid·Flat JPEG를 눈으로 보면 색이 자연스럽게 바뀌었고 띠·얼룩 같은 큐브 흔적은 보이지 않았다.
- 프로필을 쓰면 렌더가 약 1초 늘었다. 대부분 프로필 큐브(64³)를 만드는 시간이며, 같은 프로필·색온도 구간은 캐시한다. release 빌드의 시간은 따로 재지 않았다.
- 원본 SHA256은 렌더 전후 같다: RW2 `290ad5b4…`, Adobe Standard DCP `a4ca9934…`, Camera Vivid DCP `5012697d…`.

## 화면과 실제 앱

- 300px Inspector 스냅샷에서 텍스처·명료도·디헤이즈 순서와 캘리브레이션 묶음이 겹치거나 잘리지 않았다. 스냅샷 사진은 JPEG라 RAW 전용 메뉴(카메라 프로필·화이트밸런스)는 스냅샷에 나오지 않는다.
- release `dist/Lighthouse.app`을 격리된 임시 `LIGHTHOUSE_DATA_DIR`로 실행해 창(1440×900)이 뜨는 것을 확인했다. 실행 전 다른 Lighthouse 프로세스는 없었고, 띄운 PID 53391만 종료했다.
- 접근성 권한이 없어 실제 창에서 메뉴·슬라이더를 직접 조작하는 검사는 하지 않았다(not_run). 같은 흐름은 앱 테스트로 확인했다.

## Adobe Raw 프로필(v1.1)

2026-10-09 추가. 설치본 6종의 표를 Python으로 먼저 풀어 구조(36×16×16, 선형 인코딩, 종류 0)를 확인한 뒤 구현했다.

| 범위 | 결과 |
|---|---|
| `swift test --filter CameraProfileTests` | 18개 통과(표 인코딩 왕복·거부, Look XMP 읽기, 기준 DCP 조건, 조정값 더하기, 실제 S9) |
| 실제 S9 `probe`(`probe-look.log`) | `ALL_OK`, Adobe Color XMP SHA `8aff634b…` 렌더 전후 같음 |

| 프로필 | 평균 RGB | 채도 | 밝기 표준편차 |
|---|---|---|---|
| Adobe Standard | 93.1 88.9 86.2 | 15.27 | 62.88 |
| Adobe Color | 92.1 87.1 84.0 | 16.56 | 66.12 |
| Adobe Vivid | 89.9 84.3 81.0 | 17.97 | 68.69 |
| Adobe Monochrome | 86.8 86.8 86.8 | 0.00 | 66.66 |
| Adobe Neutral | 95.2 91.1 88.4 | 15.41 | 54.85 |
| Adobe Landscape | 93.0 86.7 83.4 | 20.55 | 63.93 |
| Adobe Portrait | 92.5 88.2 85.5 | 15.24 | 63.83 |

- Adobe Color는 Adobe Standard보다 대비·채도가 조금 높고, Vivid는 더 진하며, Neutral은 대비가 낮고, Monochrome은 무채색이다. JPEG를 눈으로 봐도 자연스러웠다.
- 디버그 빌드 기준 처음 프로필 목록을 만들 때 1.7초(DCP 15개·Look 6개 읽기), 다시 부를 때 0초다. Adobe Color 첫 렌더 1.7초, 캐시 뒤 0.5초(300px).
- 전체 `swift test`: 400개 중 7 skip, 실패는 `PreviewResponsivenessTests.testRAWDragShowsFramesAndSettlesExactly` 1건(드래그 중 프레임 0장). 같은 시각 load가 15~41이었고, 이번 변경을 잠시 빼고(`git stash`) 이전 커밋으로 같은 검사를 3번 돌려도 2번 실패했다. 부하에 흔들리는 검사로 보고 고치지 않았다. release 빌드·codesign은 통과했다.
- 기존 테스트의 "지원하지 않는 프로필" 예를 Adobe Color에서 Artistic 01로 바꿨다. 기존 찾기 테스트는 실제 설치 폴더를 읽지 않도록 빈 Look 폴더를 넘긴다.

## 검증하지 않은 것

- Adobe Camera Raw/Lightroom 렌더와의 비교. 비교 자료가 없다. Adobe Raw 프로필의 곡선을 sRGB 값에 거는 것도 Adobe 처리 공간과 다를 수 있다.
- 다른 제조사 카메라의 DCP 찾기(이름 맞추기 규칙은 단위 테스트로만 확인했다).
- Camera 계열 프로필에서 HDR 하이라이트의 효과.
