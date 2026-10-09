# Lightroom 프리셋 검증 — 2026-10-07

후속 톤·입자·기본 프로필 확장 결과는 [추가 검증 기록](lightroom-tone-verification.md)에 있다. 아래 표는 최초 구현 당시의 결과다.
현재 작업의 결과만 기록한다. 실제 앱의 클릭 검증과 모델·렌더 검증은 구분한다.

## 구현과 경계 검토

XMP 및 lrtemplate를 읽어 기존 `EditPreset` 보관함에 저장하고, 명시된 값만 사진에 적용한다. 프리셋 검색·호환 결과, 여러 사진 적용과 실행 취소, 가져올 사진에 자동 적용, 빠른 표시 필터를 연결했다. 기존 v1 보관함은 이전 동작을 유지한다.

Astra가 namespace 범위, 전역/중첩 설정 분리, modern/legacy 곡선 우선순위, 미지원 설정 안내, payload 저장 호환, 취소 세대 번호, 저장 성공 후 목록 갱신, 보이는 선택 범위를 직접 검토했다. 발견된 파서 경계 네 가지와 검색/좁은 화면 누락은 담당 구현자가 보완했다.

## 이미지 적용

생성한 색상표와 로컬 LUMIX S9 RW2 표본에 XMP/lrtemplate를 적용하고 JPEG로 출력했다. 640×426, JPEG 품질 0.95에서 다음 값을 측정했다. 평균 오차는 RGB 0…255 기준이며 이 표본에 대한 측정값이다.

| 표본 | 무보정 대비 평균 RGB 차이 | 렌더와 JPEG 재로드의 평균 RGB 차이 |
| --- | ---: | ---: |
| 색상표 + 테스트 XMP | 21.04 | 0.47 |
| 색상표 + 테스트 lrtemplate | 21.39 | 0.57 |
| S9 RW2 + 테스트 XMP | 27.17 | 1.46 |
| S9 RW2 + 테스트 lrtemplate | 11.80 | 1.10 |

[Adobe 공식 XMP 예제](https://github.com/AdobeDocs/cis-photoshop-api-docs/blob/main/sample-code/lr-sample-app/crs.xml)도 파싱·적용·출력했다. 이 예제의 지원 값은 중립이므로 무보정과 픽셀 차이는 0이었다. Lightroom 자체 출력과 비교한 수치는 아니다.

사진 두 개와 프리셋 두 개의 사전 기록 SHA256을 비교해 모두 동일함을 확인했다. 출력 파일은 별도 경로에 생성했다. 원본과 상세 결과는 Git 제외 `.artifacts/lightroom-presets-20261007/`에 둔다.

## 요청한 배포팩

[사용자가 제공한 MYBOX 공유 링크](https://naver.me/FSvL8OxZ)의 `myslowfilm.zip`을 실제 다운로드해 확인했다. 압축은 1,296 bytes, 내부는 `my.slow.film.xmp` 하나(4,506 bytes)였다. 공유 파일은 암호 없이 다운로드 가능한 상태였다.

- 파싱 성공: 프리셋 이름 `my.slow.film`, 수치 설정 32개와 곡선 채널 4개.
- 적용: RGB 채널 곡선, 하이라이트 −13, 채도 +4, 마젠타 색조 +1/명도 −2, 입자 양 9/크기 30 및 명시된 중립 값.
- 제외: 흰색 −17, 검정 −27, 섀도 −2, 입자 거칠기(`GrainFrequency`) 50, 카메라 프로필 및 현재 지원하지 않는 설정. 0이나 기본값인 미지원 항목도 호환 안내에는 표시된다.
- S9 RW2 렌더·JPEG 출력 성공. 무보정 대비 평균 RGB 차이 5.42, 렌더/JPEG 재로드 평균 차이 1.32.
- 판정: **지원하는 항목은 적용 가능, Lightroom과 완전히 같은 색감은 보장하지 않음**.

다운로드 ZIP SHA256: `e714b56b16e5ea77680227f11f7aabe2fbc8da78b3fbc7074dec3f93db1e2596`.

## 자동 검사와 화면

- `swift test`: 333개 실행, 6개 skip, 0 failures. 327개가 실제 실행되어 통과했다. skip은 선택적 얼굴 fixture 1개, UI 이벤트 3개, 화면 렌더 2개다.
- 두 화면 렌더 검사는 환경 변수를 주고 별도 실행해 통과했다. 프리셋 Inspector(300px), 가져오기 결과, 호환 정보 3장과 Workspace의 grid/edit(1440×900, 1100×720) 4장을 직접 열어 확인했다. 검색·버튼·빠른 표시 필터에 겹침이 없었다.
- 관련 신규 검사는 파서 8개, 앱 흐름 4개이며 기존 프리셋·선별·워크플로 검사도 통과했다. 취소 뒤 새 요청, 최신 목록 병합, 보관함 저장 실패, 재로드, 적용·undo/redo와 원본 보존을 포함한다.
- `swift build` debug 빌드는 앱 담당 실행에서 통과했다.
- core/app의 최종 하네스 완료 검사는 각각 0 errors였다. 이 검사는 구현 산출물·검사 근거의 일치 여부에 대한 결과다.

- `./scripts/build-app.sh`: release 빌드와 `dist/Lighthouse.app` 생성 성공.
- `codesign --verify --deep --strict dist/Lighthouse.app`: exit 0. 로컬 ad-hoc 서명이며 배포 공증을 뜻하지 않는다.
- 새 `.app`을 `LIGHTHOUSE_DATA_DIR`로 격리한 사진 1장·프리셋 1개의 테스트 보관함으로 실행했다. 다른 경로의 동일 bundle ID 앱이 실행 중이므로, 실행 파일 SHA256이 같은 QA 복사본에 별도 bundle ID를 주어 창 존재까지 확인했다. 실제 사용자 카탈로그를 검사에 사용하지 않았다.

실제 창 클릭·키보드·메뉴·시트·재시작 조작 검사는 **not_run**이다. Orca는 QA 복사본에 visible windows가 있음을 확인했지만 AX 읽기가 1,500ms 차단되어 `permission_denied`를 반환했다. 이전 CUA 시도도 접근성 timeout이었다. 앱 실행·모델 테스트·화면 렌더를 실제 조작 통과로 바꾸지 않는다. 생성한 QA 프로세스는 종료했고, 원래 실행 중인 다른 경로의 앱은 그대로 유지했다.
