# 추가 톤·입자·기본 프로필 검증

2026-10-07. 개발 계약: [v1](lightroom-tone-contract.md) 및 [렌더 보완 v2](lightroom-tone-render-addendum.md). 실제 실행 근거는 `.artifacts/lightroom-tone-20261007/`에 로컬 보관한다.

## 검증 범위

- 흰색·검정 ±100, 양수 하이라이트·음수 섀도, 입자 거칠기, 기본 색상/흑백 프로필.
- 기존 카탈로그와 프리셋의 누락 키 기본값, 손상 거부, 부분 적용과 저장/재로드.
- 중립/기존 보정 픽셀 유지, 새 보정의 실제 이미지 변화, S9 RW2 렌더와 JPEG 출력, 원본 SHA256.
- Inspector·고급 색상 패널·프리셋 적용/실행 취소, 빌드·패키징·실제 앱 실행.

## 실행 상태

코어 선택 검사: LightroomToneTests 6개, LightroomPreset/AdvancedColor/AdvancedModel/BatchEditing 관련 36개 통과. 프로필 안내 보완 후 LightroomPresetTests 9개 재실행 통과.

독립 실행파일로 생성 색상표와 LUMIX S9 24MP RW2에 13가지 보정을 렌더·JPEG 출력했다. 별도로 이전 버전 렌더 실행파일의 JPEG와 비교한 2건 모두 평균 RGB 오차 0이었다. 새 설정을 끄면 기존 출력이 유지되는 것을 확인했다. 원본 RAW·색상표·XMP 3개 SHA256이 모두 동일했다.

| my.slow.film 적용 | 결과 |
| --- | --- |
| 파싱 | scalar 36개 + 곡선 4채널 + 기본 프로필 1개 |
| 추가 값 | whites -0.17, blacks -0.27, shadows -0.02, grain roughness 0.5 |
| Default Color | Lighthouse 기본 색상으로 매핑, 엔진 차이 안내 유지 |
| S9 무보정 대비 RGB 차이 | 평균 11.26/255 (이전 지원 범위만 적용하면 5.42) |
| S9 렌더/JPEG 재로드 오차 | 평균 1.34/255, 640×426, 품질 0.95 |
| 13가지 렌더/JPEG 오차 | 평균 0.41…1.38/255 |

생성 색상표 2장, S9 이전 범위/새 프리셋/흑백 3장을 열어 육안 확인했다. 검은 영역의 추가 압축, 흰색 조절, RGB 곡선과 입자 유지, 흑백 전환을 확인했다. 프리셋의 Adobe 원본 출력과 비교한 검사가 아니다.

앱 흐름 검사 6개가 통과했다. XMP/lrtemplate에서 새 값을 읽고, 선택한 2장에 부분 적용, 단일 undo/redo, 누락값 유지, 카탈로그·프리셋 저장/재로드, 기본값 복원을 확인했다. opt-in 스냅샷 검사도 별도로 1개 통과했다. 메인 검토자가 Inspector 300px, 고급 색상/입자 300px, 호환 정보 PNG 3장을 독립적으로 열어 수치·배치·프로필 포함 카운트를 확인했다. 이는 실제 OS 클릭 검증과 구분한다.

전체 `swift test`: 342개 중 336개 통과, opt-in 검사 6개 skip, 실패 0개(81.4초). `swift build`와 `git diff --check`도 통과했다. 로그는 `full-swift-test.log`와 `swift-build.log`에 남겼다.

`./scripts/build-app.sh` release 빌드(60.6초)와 `codesign --verify --deep --strict dist/Lighthouse.app`가 통과했다. 결과 앱은 `dist/Lighthouse.app`이다.

실제 dist 앱을 격리 `LIGHTHOUSE_DATA_DIR`로 실행했다(PID 40664). 같은 번들 ID의 별도 checkout 앱이 이미 실행 중이어서, 이번 빌드의 복사본에 QA 번들 ID를 부여하고 재서명하여 별도 실행했다(PID 41448). 재서명으로 전체 실행파일 SHA256은 달라지지만 `__TEXT,__text` 섹션이 동일한 것을 확인했다. 도구는 QA 앱의 실제 창이 있음을 확인한 뒤 `permission_denied`를 반환했다(AX reads blocked). 따라서 실제 창에서의 마우스·키보드 조작은 **미검증**이며 offscreen 화면 검사로 대체했다고 주장하지 않는다. 실행한 두 QA 프로세스만 종료했다. 기존 별도 checkout 앱은 유지했다.

상세 근거: `actual-app-state.json`, `qa-app-state.json`, `actual-app-process.txt`, `app-binary-verification.json`, `build-app.log`. 접근성 설정을 변경하지 않았다. 사용자용 안내에는 원본 프리셋 재가져오기와 미지원 범위를 명시했다.

## 색감과 프로필의 범위

Lightroom의 Adobe 엔진 또는 DCP/Camera Matching 프로필과 픽셀 일치 검증은 수행하지 않는다. 일반 프리셋의 Default Color/Color는 Lighthouse 기본 색상, Default Monochrome/Monochrome 및 ConvertToGrayscale은 색상/흑백 모드로 연결한다. 알 수 없는 전용 프로필은 제외 경고를 유지한다.
