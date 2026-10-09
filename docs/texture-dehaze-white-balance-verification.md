# 텍스처·디헤이즈·화이트밸런스 검증 기록

2026-10-09, [계약 v1](texture-dehaze-white-balance-contract.md) 기준. 실행 산출물은 Git에 넣지 않는 `.artifacts/texture-dehaze-wb-20261009/`에 있다.

## 자동 검사

| 범위 | 명령 | 결과 |
|---|---|---|
| 모델·렌더·가져오기 | `swift test --filter TextureDehazeWhiteBalanceTests` | 12개 통과 |
| 효과를 끈 코드(RED 확인) | 같은 명령, `applyDehaze`·`applyTexture` 호출을 잠시 주석 처리 | 렌더 검사 4개 실패(10건) — 검사가 효과를 실제로 잡는다 |
| 관련 기존 검사 | `LightroomPreset·LightroomTone·ColorGrading·EditPreset·AdvancedImaging·AdvancedModel·BatchEditing·EditSnapshot·AutoAdjust·NoiseReduction` | 101개 통과 |
| 앱 흐름 | `swift test --filter TextureDehazeWhiteBalanceFlowTests` | 2개 통과(실제 S9 RW2 포함) |
| 전체 | `swift test` | 380개 중 7 skip, 실패 0 |

- 구현을 테스트보다 먼저 썼기 때문에, 효과를 끈 상태에서 렌더 검사가 실패하는지 따로 확인했다.
- 기존 `LightroomPresetTests`는 `Temperature`만 든 프리셋을 "지원 설정 없음"의 예로 썼다. 이제 지원하는 키이므로 아직 지원하지 않는 `LensProfileEnable`로 바꿨다.
- `EditPreset.applied(to:)`는 `applied(to:isRAW:)`가 되었다. 기본값을 두면 RAW 화이트밸런스가 조용히 빠질 수 있어 모든 호출에 RAW 여부를 넘긴다.

## 실제 RAW

`probe`로 LUMIX S9 RW2를 장변 1600px로 렌더했다. 결과는 `ALL_OK`이다.

| 케이스 | 평균 RGB | 잔 디테일(인접 픽셀 차) |
|---|---|---|
| 중립 | 91.60 88.55 86.85 | 7.115 |
| 주광 | 99.95 89.61 81.32 | 7.141 |
| 텅스텐 | 43.49 82.07 119.08 | 6.723 |
| 그늘 | 112.79 92.15 69.40 | 7.181 |
| 디헤이즈 +60 | 81.29 77.46 75.78 | 8.375 |
| 디헤이즈 -60 | 124.82 122.91 122.28 | 4.200 |
| 텍스처 +100 | 88.96 85.80 84.16 | 9.941 |
| 텍스처 -100 | 93.22 90.19 88.62 | 4.908 |
| my.slow.film 재가져오기 | 80.29 76.78 75.34 | 7.544 |

- 텅스텐은 주광보다 푸르고 그늘은 더 따뜻하다. 텍스처 ±는 잔 디테일을 키우고 줄인다.
- 디헤이즈 +60을 눈으로 보면 하늘이 짙어지고 그늘과 색이 진해졌으며, 건물과 하늘 경계에 뚜렷한 테두리는 보이지 않았다.
- 처음 수식의 디헤이즈 -60은 평균이 152까지 올라 검정이 회색이 될 만큼 강했다. 안개 양을 줄여 다시 렌더했다(계약 갱신).
- 디헤이즈를 원래 크기에서 계산하면 1600px 렌더가 1.76초 걸렸다. 어두운 채널을 짧은 변 512px 이하에서 구하도록 바꿔 1.17초가 되었다(중립 0.92초, 첫 렌더 준비 시간 포함).
- my.slow.film의 화이트밸런스는 As Shot이고 텍스처·디헤이즈 키는 없다. 다시 가져와도 평균이 컬러 그레이딩 검증 때와 같다.
- 원본 SHA256은 렌더 전후 같다: RW2 `290ad5b4…812e50`, XMP `c6964e45…379b67f4a`.

## 검증하지 않은 것

- 실제 앱 창에서 슬라이더·메뉴를 직접 조작하는 검사는 접근성 권한이 없어 하지 않았다(not_run). 같은 흐름은 앱 테스트로 확인했다.
- Adobe 결과와의 시각적 일치. Core Image 켈빈과 Adobe 켈빈이 같은 척도인지도 확인하지 않았다.
