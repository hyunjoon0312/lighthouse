# 사진 작업 확장 — 앱 계약 v1 (2026-09-29)

이미지와 라이브러리 계약 v1의 여섯 기능을 실제 macOS 앱에 연결한다. 앱 작업자는 `Sources/Lighthouse/` 전체의 유일한 작성자이며 특히 `LibraryModel.swift`와 모든 확장 소유권을 함께 가진다. 코어 파일/기존 타인의 테스트는 수정하지 않는다. 모델 구조와 코어 API 변경은 메인 Astra에게 반환한다.

## 상태·라이브러리

- LibraryModel init에 선택적인 `dataDirectory`를 추가하되 기존 주입 인자와 테스트 소스 호환 유지. 모든 catalog/folder/smart/preset/people/LUT/mask/thumbnail/backup store와 ImagePipeline의 경로를 인스턴스의 같은 immutable root로 고정한다. 실행 중 mutable defaultURL을 다시 읽어 경로를 선택하지 않는다. `LIGHTHOUSE_DATA_DIR`는 기존 QA 격리에 우선한다.
- LibrarySession ObservableObject가 현재 LibraryModel을 보유한다. 기존 작업이 끝나고 저장 flush에 성공한 후, 선택한 새 폴더의 유효한 catalog를 검증하여 새 모델을 연다. 열기 실패 시 현재 모델 유지. 성공 후 activeLibraryDirectory를 저장하고 window의 environmentObject/delegate를 갱신한다. 이전 library 폴더는 그대로 보존하며 파일 메뉴의 '라이브러리 열기…'로 다시 열 수 있다. LIGHTHOUSE_DATA_DIR 환경 설정이 있는 실행에서는 영구 UserDefaults를 변경하지 않는다.
- 백업/복원 중 문서 변경, import/export/people analysis/Drive upload 등 충돌 작업을 막는다. 진행/취소/에러/완료 상태를 분리한다. 기존 종료 경고와 메뉴 disabled에도 통합한다. 다른 장기 작업 중 백업/복원/라이브러리 전환은 시작하지 않는다. async 결과는 token, 원본 photoID/path/시작 edits와 현재 상태를 확인해 stale 결과를 적용하지 않는다.
- 사용자 문구는 한국어. 오류를 무음으로 삼키지 않는다. modal gate에 새 sheet를 모두 포함한다.

## 플리커·범위·부분 NR

- 기존 빛/디테일 패널에 플리커 섹션: enabled, amount, direction, cycles, phase, amplitudeEV, colorAmount와 '띠 자동 분석'. 분석 중 progress/취소 또는 결과 무시 token 제공. 분석 실패는 기존 edits 유지. 성공은 한 번의 undo 작업으로 해당 flicker만 갱신한다. 자동 분석은 실제 무늬를 오인할 수 있으며 촬영 시 손실된 정보는 복원하지 못한다는 짧은 도움말.
- 부분 영역 생성 메뉴에 '밝기 범위', '색상 범위'. sheet에서 범위/softness 또는 ColorPicker/tolerance/softness 설정 후 생성. 기존 범위 영역은 '범위 다시 설정'으로 같은 ID/effect/strokes 보존. 원본으로 mask 생성 후 preview overlay를 사용할 수 있다. sheet snapshot의 photoID/path/edits가 변했으면 적용 거부.
- 각 부분 영역에 기존 off/standard/ai + amount UI를 넣고 CPU/AI 진행 표시 재사용. local NR effect 포함한 thumbnail/render signature 사용. global/local AI 모두 neighbor prefetch 금지. `canDisplaySupersededRender`는 flicker/global NR/local NR(해당 enabled/mask 포함)이 변하면 오래된 이미지 표시 금지.
- 새 subject/background 생성 때 AutomaticMaskKind 저장. 과거 provenance 없는 raster는 추측해 자동 재인식하지 않는다.

## 일괄 자동 마스크

- BatchEditSheet의 local 선택 시 '사진마다 피사체·배경 다시 인식' 옵션 기본 켬. source local에 provenance가 있는 경우에만 의미가 있다. 기존 영역은 동일 좌표 복사 안내. 사용자가 끄면 기존 복사 동작 유지.
- 시작 시 source edits와 target ID/path/edits를 snapshot. 대상마다 subjectMask 한 번 생성 후 subject와 background에 같은 baseMask를 사용하고 inversion으로 구분한다. 원래 area effects/brushes/gradient와 ID 복사 의미는 기존 batch와 동일. 대상 추적에 필요한 새 ID는 기존 정책 준수.
- 자동 mask 생성 실패한 대상은 해당 대상 전체 batch 변경을 적용하지 않고 파일별 실패로 보고. 대상 path/edits가 변하면 skip. 취소 시 계산 결과를 적용하지 않는다. 완료 시 성공한 대상만 한 번의 group undo로 적용한다. 진행 중 대상 edits mutation은 가급적 잠그고 async guard도 유지.
- 기존 retouch/brush 좌표는 자동으로 인물에 맞춰 이동하지 않는다. 해당 한계를 짧게 안내. 처리/취소 버튼과 결과 개수 표시.

## 스마트 미리보기

- 선택 사진 '스마트 미리보기 만들기/삭제', 전체 필요시 선택 전체로 수행. 진행/취소/파일별 실패 표시. 생성은 원본 필요하며 원본이 바뀌면 cache 무효화. 재생성·원본 재연결 시 main/pinned/survey/thumb/histogram cache 모두 갱신.
- 원본 누락 시에만 store에서 검증된 TIFF를 명시적으로 가져오고 `previewEdits` 복사본으로 render. main/pinned/survey/grid/split/histogram/clipping에서 일관된 해상도와 source를 사용한다. 원본이 존재하나 decode가 실패하면 원본 오류를 표시한다. 기본 원본 보기 또한 중립 proxy의 근사임을 표시한다.
- '스마트 미리보기 · 원본 없음 · 기본 보정 근사' 배지. offline 시 기본 노출/색/LUT/기존 마스크 효과/크롭 편집 가능. full-resolution detail, NR/RAW/flicker/retouch/new auto/range 분석과 full-res export는 원본 필요하다고 disabled/help 처리한다. 저장된 비활성 NR/flicker/retouch 값은 지우지 않는다. 기본 보기 확대를 허용해도 원본 100% 디테일이라고 표시하지 않는다.
- export와 Drive 원본/보정본 업로드는 원본 경로를 계속 사용하고 proxy를 최종 원본으로 내보내지 않는다. 원본 재연결 후 저장된 모든 보정이 다시 적용된다.

## 중복·유사 후보

- 사진 메뉴 또는 상단 도구에 '중복·유사 사진 찾기…'. 선택 두 장 이상이면 선택, 그 외 현재 보이는 목록으로 범위를 명시. 분석 전 사진 snapshot, progress/cancel, 결과 exact/similar 그룹과 per-file 오류.
- 썸네일/파일명/종류, '이 묶음 비교'로 현재 catalog에 남아 있는 해당 IDs를 기존 survey로 전환. 자동 삭제/제외/별점 변경 없음. 원본 없는 파일은 실패로 보고해 정상 파일 분석은 계속한다.

## 백업·복원

- 파일 메뉴 '라이브러리 백업…', '라이브러리 복원…', '라이브러리 열기…'. 백업 sheet에서 원본 포함 여부와 포함 범위를 안내. 기본 원본 포함 켬, 용량 사용 안내. 인증 정보는 제외된다는 짧은 설명.
- backup 목적지는 NSSavePanel로 새 `.lighthousebackup` 경로 선택. 모든 store 저장 완료/로드 오류 없는지 확인한 뒤 시작. 실패한 저장을 성공으로 보고하지 않도록 flush 에러 반환 경계 마련.
- restore는 NSOpenPanel로 archive폴더 선택→inspect 결과 날짜/사진수/원본포함 표시→새 목적 폴더 선택→restore→그 library 열기. 기존폴더/currentroot/아카이브 중첩은 시작 전 reject하고 코어 검사도 유지. 사용자가 복원 화면의 실행 버튼을 눌러 작업을 시작한다.
- old root와 newly restored root 별도임을 완료 문구에 표시. 라이브러리 전환은 얼굴/LUT/폴더/미리보기 모두 새 경로로 이어져야 한다.

## 검증과 인계

전용 새 `Tests/LighthouseTests/WorkflowAppTests.swift` 소유(실제 test target 폴더명이 다르면 메인에 확인). app API/UI 작은 integration tests: legacy init 유지, per-root 경로, batch cancel/failure/stale/undo, offline render source/disabled final export/edits 보존, archive busy gating. root가 full suite, 실제 app, 이미지/백업 재시작 QA 수행. `.build`/dist 사용은 root lease 때만. 새 종속 타입은 core 승인 산출물로 받으며 placeholder API를 배포하지 않는다.
