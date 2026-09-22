# LUT 보관 목록 — LUT-LIB-v1

2026-09-23. 사용자 요청: 여러 LUT를 저장해 놓고 골라 사용한다. 기존 LUT 렌더·원본 보존·카탈로그 호환은 유지한다.

## 결과와 범위

- 전체 보정/LUT에 `보관한 LUT` 선택 메뉴와 보관 개수를 추가한다. `없음`과 저장된 LUT를 고를 수 있다. 선택하면 미리보기와 JPEG에 적용하며 강도는 현재 사진 값(없으면 100%)을 유지하고 활성화한다.
- `.cube 추가…`에서 여러 파일을 한 번에 보관한다. 한 파일 성공만 선택한 경우 기존처럼 현재 사진에도 적용한다. 여러 파일 선택 시 현재 룩은 유지하고 저장된 목록에서 고르게 한다. 성공/실패 건수와 실패 이유를 보고하며 정상 파일은 보관한다. 동일 내용은 중복 항목을 만들지 않는다.
- 앱 재시작 후 이름과 목록 유지. 이전 버전의 보관 파일도 발견한다. 사진에서 LUT를 제거해도 보관 목록에 남는다. 보관 목록 자체 삭제/이름 편집/폴더/즐겨찾기는 이번 범위 밖이다.
- 사진이 없을 때도 File 메뉴의 `LUT 추가…`로 미리 보관 가능. 파일 메뉴와 패널은 같은 함수를 사용한다.

## 소유권·역할

- Astra: 설계, 이 계약과 README/docs, `.artifacts/lut-library-validation`의 독립 검사, 최종 검토/실제 UI.
- 기존 Sol core: `Sources/LighthouseCore/LUTStore.swift` 및 새 `Tests/LighthouseCoreTests/LUTLibraryTests.swift`만 편집.
- 기존 Sol app: `Sources/Lighthouse/LibraryModel.swift`, `InspectorView.swift`, `LighthouseApp.swift`만 편집.
- 재위임 없음. 기존 변경 보존. 첫 편집/단계 전환/완료 전 메시지 본문 확인. 새 설계는 Astra에게 반환. API 준비를 서로 통지하며 준비 전 통합 빌드를 반복하지 않는다.

## 코어 인터페이스와 저장

공개 `LUTLibraryItem: Identifiable, Equatable, Sendable`는 `id: String`, `name: String`, `error: String?` 및 public initializer를 제공한다. error가 nil이면 보관 파일이 현재 유효하다.

`LUTStore.library(knownNames: [String: String] = [:]) throws -> [LUTLibraryItem]`를 추가한다. 디렉터리가 없으면 [], 다른 디렉터리 읽기 실패는 throw. `.cube` 파일 중 stem이 소문자 64자리 SHA-256인 정규 파일을 비재귀적으로 탐색한다. 숨김/다른 확장자/유효하지 않은 이름은 무시한다. 각 항목을 기존 load로 검증하며 개별 손상은 item.error로 기록하고 나머지 목록은 유지한다. 이름과 id 순으로 결정적으로 정렬한다. library는 읽기 전용이다.

새 import는 `<id>.cube`와 같은 폴더에 `<id>.json` sidecar를 atomic 저장한다. 스키마는 `{version:1,id:String,name:String}`. 기존 유효 sidecar 이름을 유지하고 없거나 손상됐으면 TITLE 또는 원래 파일 basename으로 생성/복구한다. 기존 importCube 반환 name도 sidecar에 확정한 이름을 사용한다. 파일 복구·중복 배제·bounded read·캐시 검증 순서는 기존 그대로 유지한다. sidecar 쓰기 실패는 localized cannotSave로 보고한다. 카탈로그/렌더는 sidecar를 요구하지 않는다.

library 이름 우선순위: 유효한 sidecar → 검증된 cube의 비어 있지 않은 TITLE → knownNames[id] → `이름 없는 LUT · {id 앞 8자리}`. cube가 손상됐어도 sidecar/knownNames/해시 이름으로 표시 가능. 잘못된 sidecar id/version/빈 이름/JSON은 무시하고 원문을 덮어쓰지 않는다. 비정상 sidecar가 정상 cube의 사용을 차단하지 않는다. 이전 카탈로그에만 남은 파일명은 app의 knownNames로 제공한다. 새 sidecar가 없는 이전 파일과 기존 카탈로그를 자동 수정하지 않는다. 동일 이름이더라도 서로 다른 내용이면 id로 구분한다.

## 앱 상태와 흐름

- published `savedLUTs:[LUTLibraryItem]`, `isLUTLibraryLoading`, `lutLibraryError`와 기존 isLUTImporting/lutError를 사용한다. library 목록은 기존 전용 lutQueue에서 읽는다. 사진 카탈로그 load 성공 후 한 번 갱신하며 knownNames는 photos의 lut.id/name에서 중복 키를 안전하게 수집한다. import 완료 후 목록을 갱신한다. 작업 토큰으로 오래된 목록 결과를 최신 목록 위에 덮어쓰지 않는다. 보관 목록 읽기 오류와 사진별 import오류는 구분한다.
- NSOpenPanel allowsMultipleSelection=true. 선택 사진이 없어도 import 허용(catalogLoaded/loadError guard 유지). 파일들 순서대로 import하여 개별 실패를 모으고 마지막 library 결과를 전달한다. 목록 조회는 UI 스레드 밖에서 수행한다. 성공해 보관된 파일이 있고 최종 목록 조회에 실패해도 성공 항목을 버리지 말고 known imported 항목을 기존 목록에 id로 병합한 뒤 library 오류를 표시한다.
- 단일 선택 성공 자동 적용은 기존 photo ID + selectionGeneration 조건을 유지하고 최신 edits의 lut만 변경한다. 사진이 없거나 선택 변경이면 저장만 성공 메시지. 여러 파일 선택 시 성공이 하나뿐이어도 자동 적용하지 않는다. 실패가 기존 LUT와 보정을 변경하지 않는다.
- `selectSavedLUT(_ id: String)`는 빈 id면 removeLUT. 유효한 saved item이면 현재 intensity 유지(없으면1), isEnabled=true로 LUTAdjustment를 만들어 updateEdits한다. 선택을 변경하면 원본 표시를 끄고 사진 보기로 전환해 결과를 보인다. 손상 item이면 기존 선택을 유지하고 오류. 단순 선택에 동기 파일 읽기 없음. 재렌더가 실제 파일 무결성을 재검사한다.
- UI picker는 현재사진 id와 정확히 binding. 현재사진 LUT가 목록에 없으면 현재 이름+`보관 파일 없음` 임시 항목을 넣어 binding을 보존한다. 손상 항목은 목록에서 `사용 불가`로 표시하고 선택 비활성화. 이름 중복 항목은 id 앞 6자리도 표시한다. import/초기목록조회 중 picker와 import는 일관되게 비활성화한다. 오류 상세/보관 수를 간결히 표시하며 기존 슬라이더/checkbox/제거 유지. 버튼/메뉴 한국어 accessibility label을 둔다.

## 검증

core: `swift test --filter LUTLibraryTests`. 여러 LUT와 제목 없는 이름 재시작 복원, 동일 내용 재불러오기 dedup/이름 안정성, 같은 제목 다른 id, sidecar 없는 이전 TITLE/knownNames/해시 fallback, 개별 손상과 메타데이터 손상 격리, 유효하지 않은 파일 무시, 디렉터리 오류, 사진 LUT 해제/카탈로그와 독립적인 library 목록.

app: 코어 API 준비 후 `swift build` 1회. 선택·비동기 완료·부분 실패 흐름을 코드 검토하고 실제 UI는 Astra 담당.

Astra: 전체 swift test와 release/codesign, 실제 앱에서 여러 .cube 한 번에 추가/목록 변경/강도 유지/없음·제거 후 재선택/undo/재시작 이름·목록 복원/다른 LUT 결과 JPEG를 검사한다. 이전 sidecar 없는 파일 복원을 독립 확인한다. 기본 사용자 데이터에 테스트 LUT를 넣지 않는다.
