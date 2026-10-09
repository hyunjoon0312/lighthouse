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

## 검증하지 않은 것

- Adobe Camera Raw/Lightroom 렌더와의 비교. 비교 자료가 없다.
- 다른 제조사 카메라의 DCP 찾기(이름 맞추기 규칙은 단위 테스트로만 확인했다).
- Camera 계열 프로필에서 HDR 하이라이트의 효과.
