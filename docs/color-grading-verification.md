# 컬러 그레이딩 검증 기록

2026-10-09, [계약 v1](color-grading-contract.md)과 [구현 계획](superpowers/plans/2026-10-09-color-grading.md) 기준. 실행 산출물은 Git에 넣지 않는 `.artifacts/color-grading-20261009/`에 있다.

## 자동 검사

| 범위 | 명령 | 결과 |
|---|---|---|
| 모델·렌더·가져오기 | `swift test --filter "ColorGradingTests\|LightroomPresetTests"` | 26개 통과 |
| 기존 큐브·톤 회귀 | `swift test --filter "ColorGradingTests\|AdvancedColorTests\|LightroomToneTests"` | 27개 통과 |
| 앱 흐름 | `swift test --filter "ColorGradingFlowTests\|LightroomPresetFlowTests"` | 11개 중 9개 통과, opt-in 스냅샷 2개 skip |
| 스냅샷 | `LIGHTHOUSE_SNAPSHOT_DIR=… swift test --filter ColorGradingFlowTests` | 4개 통과, PNG 2장 생성 |
| 전체 1회차 | `swift test` | 363개 중 7 skip, **실패 4건(테스트 2개)** |
| 전체 2회차 | `swift test` | 363개 중 7 skip, 실패 0 |
| 최종 검토 수정 후 | `swift test --filter "ColorGradingTests\|ColorGradingFlowTests"` | 24개 중 23개 통과, 스냅샷 1개 skip |
| 수정 후 전체(현재→변경 전 연속) | `swift test` | 현재 366개 중 7 skip, 실패 0 / 변경 전 342개 중 6 skip, 실패 0 |
| 빌드 | `swift build`, `./scripts/build-app.sh`(최종 56.1초), `codesign --verify --deep --strict dist/Lighthouse.app` | 모두 통과 |

1회차 실패 2건은 다음과 같다.

- `LibrarySessionObservationTests.testSessionRelaysOnlyTheActiveLibraryAfterSwitch`: 이번 작업과 별개인 미커밋 작업의 테스트다. 단독으로 다시 실행하면 통과했다.
- `PreviewResponsivenessTests.testRAWDragShowsFramesAndSettlesExactly`: 33ms 간격 타이밍에 의존하는 검사다. 단독 실행 1회 실패 뒤, 현재 코드에서 2/2 통과했다. 컬러 그레이딩 변경 9개 파일을 변경 전 상태로 잠시 되돌린 상태에서도 1/1 통과했다.

두 실패 모두 2회차 전체 실행에서는 재현되지 않았다.

최종 검토 수정 뒤 전체 실행에서 RAW 드래그 검사가 4회 중 3회 실패해 회귀 여부를 다시 확인했다.
- 변경 전 코드로 같은 전체 실행을 3회 했을 때는 모두 통과했다.
- 테스트별 시간을 비교하면 HDR 내보내기 테스트부터 느려졌지만, 그 테스트만 따로 실행하면 현재와 변경 전 시간이 같았다(10.2/6.0초 대 9.8/6.0초).
- 이 머신은 공유 머신으로, 같은 시간대에 Android 에뮬레이터 2대가 돌았고 15분 평균 load가 약 14였다.
- 현재 코드와 변경 전 코드를 연달아 전체 실행하자 둘 다 실패 0이었고 시간도 같았다(HDR 15.7초 대 15.0초, 드래그 4.41초 대 4.41초).

그래서 머신 부하에 따라 흔들리는 검사로 판단하며, 원인은 고치지 않았다.

## 최종 검토와 수정

새 검토자의 판정은 "수정 후 머지"였다(치명 0, 중요 2, 사소 6). 중요 2건은 실패하는 테스트를 먼저 만든 뒤 고쳤다.

- **계조 반전:** 혼합이 낮고 명도가 강하면 밝은 입력이 더 어두워졌다. 그레이딩마다 `L + ΔY(L)`를 단조 표로 만들도록 고쳤다(계약 갱신). 검사는 `testStrongLuminanceWithHardBlendingKeepsToneOrder`로, 단조화를 끈 코드에서 5개 설정 모두 실패하고 수정 후 통과한다.
- **바퀴 두 번 눌러 초기화:** 실행 취소 단계가 두 개 남았다. 제자리 클릭의 연속 편집을 350ms 동안 열어 두고, 그 사이 초기화가 오면 같은 단계로 합치도록 고쳤다. 검사는 `testWheelDoubleTapResetIsOneUndoStepFromValueBeforeClick`과 `testWheelDragEndsImmediatelyWhenMovedAndAfterDelayWhenStationary`다.
- 수정 뒤 실제 S9 프로브를 다시 실행했고 `ALL_OK`, 평균 RGB도 이전과 같았다. 이 표의 케이스에는 명도 조정이 없다.

사소한 지적 6건은 고치지 않고 남겼다(360° 표시, 명도만 바꾼 영역의 빨간 점 등).

## 실제 RAW·색상표 렌더

`grading-probe`로 LUMIX S9 RW2와 생성 색상표를 장변 1600px로 렌더하고 JPEG로 저장했다. 결과는 `ALL_OK`이다.

| 케이스 | S9 평균 RGB | 색상표 평균 RGB |
|---|---|---|
| 중립 | 91.60 88.55 86.85 | 127.00 127.00 95.12 |
| 혼합만 90 | 91.60 88.55 86.85 | 127.00 127.00 95.12 |
| 그림자 200°·하이라이트 35°·균형 +10 | 86.24 89.82 89.98 | 125.68 127.55 94.20 |
| 위와 같음 + 흑백 | 83.83 90.49 92.35 | 137.40 137.34 134.57 |
| my.slow.film 재가져오기 | 80.29 76.78 75.34 | 116.45 116.33 80.10 |
| my.slow.film, 그레이딩 키를 뺀 이전 가져오기 | 80.29 76.78 75.34 | 116.45 116.33 80.10 |

- 혼합만 바꾼 경우와 my.slow.film 재가져오기 전후의 평균이 같다. my.slow.film의 컬러 그레이딩 키 14개는 모두 중립값이며, 이제 제외 경고 없이 읽힌다.
- S9 JPEG를 눈으로 보면 그림자는 청록, 밝은 하늘·벽은 주황 쪽으로 움직였다. 흑백 분할 톤에서는 그림자가 청색, 하이라이트가 웜톤으로 보였다.
- 원본 SHA256은 렌더 전후 모두 같다.
  - RW2 `290ad5b4…812e50`
  - 색상표 `1207a32e…44fb817`
  - XMP `c6964e45…379b67f4a`

## 화면

300px 스냅샷 두 장을 확인했다(`color-grading-300.png`, `color-grading-inspector-300.png`).

- 영역 버튼 4개가 잘리지 않았고, 조정된 영역에 색 점이 붙었다.
- 바퀴 방향이 맞았다: 오른쪽 빨강, 위 연두(90°), 왼쪽 청록(180°), 아래 보라(270°). 200° 마커 위치도 맞았다.
- Inspector에서 HSL과 필름 입자 사이에 겹침 없이 들어갔다.
- 첫 스냅샷에서는 선택된 영역이 구분되지 않았다. 굵은 글씨와 강조색 테두리를 직접 그리도록 고쳤다.

## 실제 앱

- `dist/Lighthouse.app`을 격리된 임시 `LIGHTHOUSE_DATA_DIR`로 실행했다(PID 22530).
- `CGWindowList`로 이 PID의 "Lighthouse" 창(1412×882)이 화면에 있는 것을 확인했다.
- 접근성(System Events가 창 0개로 보고)과 화면 캡처("could not create image from window") 권한이 없었다. 그래서 **실제 창에서의 바퀴 드래그·⌘Z 조작은 미검증(not_run)**이다. 같은 흐름은 앱 테스트로만 확인했다.
- 실행 전 다른 Lighthouse 프로세스는 없었다. 실행한 PID 22530만 종료했다.

### 후속: 원인과 수정(2026-10-09)

RAW 드래그 검사의 간헐 실패는 단순한 부하 문제가 아니었다. 정확한 현상 뒤 첫 근사 렌더가 RAW를 다시 현상하는 경우가 있었다. Core Image가 현상 결과를 중간 캐시로 남길지는 그때그때 달랐다. 같은 조건 5번 중 3번은 0.03초였고 2번은 0.42·0.76초가 걸렸다. 늦은 경우에는 검사의 드래그 시간(약 0.66초) 안에 새 화면이 하나도 오지 않았다. 실제 앱에서도 사진마다 처음 슬라이더를 끌 때 화면이 잠깐 멈췄다.

- 수정: `CIRAWFilter` 현상 결과에 `insertingIntermediate(cache:)`로 렌더 단계를 나눴다. 미리보기는 캐시로 고정하고, 내보내기는 같은 자리에서 나누기만 한다. 내보내기도 나눠야 중간값 정밀도가 같아 미리보기와 픽셀이 같다. 처음에는 미리보기에만 넣었다가 "놓은 뒤 화면은 정확한 렌더와 같다" 검사가 실패해 고쳤다.
- 결과: 첫 근사 렌더 5번 모두 0.010~0.011초, 첫 정확한 현상 0.83~1.3초 → 0.64초. 드래그 중 화면은 4~5장에서 7장으로 늘었다. `PreviewResponsivenessTests`·`RAWSourceSizeTests` 실행 시간은 약 34초에서 11.5초로 줄었다.
- 검사: `RAWSourceSizeTests.testFirstApproximateRenderReusesDevelopedRAW`(첫 근사가 정확한 현상의 15% 미만). 예전 코드에서는 5번 중 2번 실패한다(원인 자체가 간헐적이다).
- 확인: 드래그 검사 단독 3회 통과. CPU 부하 프로세스 10개(직접 띄운 PID만 종료)를 돌리며 3회 통과. 전체 `swift test` 2회 연속 408개 중 7 skip, 실패 0.

## 검증하지 않은 것

Adobe Lightroom 결과와의 시각적 일치는 비교 자료가 없어 검증하지 않았다. 이번 성공 기준은 방향·역할 일치다.
