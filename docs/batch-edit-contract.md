# 여러 사진 선택·일괄 보정 — BATCH-v1

2026-09-23 추가 사용자 요청. LUT-LIB-v1과 함께 구현한다. 한 사진을 기준으로 보정하고 선택한 여러 사진에 지정 범위를 복사한다. 슬라이더를 움직이는 동안은 기준 사진만 바뀌고, 사용자가 일괄 적용 버튼을 누를 때 선택 대상에 한 번에 반영한다.

## 역할과 소유권

- Astra: 설계/계약/중요한 검토·통합 UI 검사/docs.
- Sol batch: 새 `Sources/LighthouseCore/BatchEditing.swift`, 새 `Tests/LighthouseCoreTests/BatchEditingTests.swift`만 작성. 기존 파일 수정 없음.
- Sol app: LUT-LIB-v1의 기존 3개 app 파일에 `Sources/Lighthouse/WorkspaceView.swift`와 새 `Sources/Lighthouse/BatchEditSheet.swift`를 추가 소유한다. 두 기능을 통합한다.
- Sol core의 LUTStore/library 소유권은 변하지 않는다. 재위임 없음. 새 판단은 Astra에 질문. 의존 API 준비 전 전체 빌드 반복 금지.

## 코어 API (확정)

1. `EditComponents: OptionSet, Sendable` public rawValue:Int initializer. `.global`=1, `.lut`=2, `.geometry`=4, `.local`=8, `.all` 합집합. `EditSettings.merging(from source: EditSettings, components: EditComponents) -> EditSettings` extension. global은 exposure/contrast/saturation/temperatureShift/tintShift/highlights/shadows/sharpness만 복사. geometry는 rotationQuarterTurns/cropAspect, local은 localAdjustments 전체 대체, lut는 optional LUTAdjustment 전체(이름/강도/활성화/없음) 복사. 선택하지 않은 값은 대상 사진의 기존 값 유지. 원본/메타데이터/별점/flag는 변경하지 않는다.
2. `PhotoSelectionState: Equatable, Sendable` public initializer(), public private(set) `selectedIDs:Set<UUID>`, `activeID:UUID?`, `anchorID:UUID?`. `PhotoSelectionMode` enum `.single, .toggle, .range`. `mutating select(_ id:UUID, in visibleIDs:[UUID], mode:PhotoSelectionMode = .single)`. single은 한 장으로 교체, active/anchor=id. toggle은 membership 반전, 추가면 active/anchor=id, active 제거 시 보이는 순서의 남은 첫 사진, 빈 선택이면 active/anchor=nil. range는 anchor(없으면 active, 둘 다 없으면 id)와 id 사이의 보이는 순서 구간으로 선택을 교체하고 active=id, anchor는 시작점 유지. 숨겨진 id 입력은 무시.
3. `mutating selectAll(in visibleIDs:[UUID])`는 보이는 사진 전체 선택, 유효한 active/anchor 유지(없으면첫번째). `mutating clear()`는 모두 nil/빈집합. `mutating reconcile(with visibleIDs:[UUID], selectFirstIfEmpty:Bool = false)`는 숨겨진 선택을 제거하고 active를 선택 내 첫 사진으로 복구. selectFirstIfEmpty가 true일 때만 빈 선택에서 보이는 첫 사진을 선택한다. 항상 active/anchor의 일관성을 유지한다. `mutating focus(_ id:UUID, in visibleIDs:[UUID])`: 이미 선택됐으면 membership 유지하며 active=id, 아니라면 single 선택. 이 함수는 '기준 사진' 바꾸기/선택 그룹의 사진 보기용이다.
4. `PhotoEditChange: Equatable, Sendable` public `id:UUID`, `before:EditSettings`, `after:EditSettings`, public initializer. `EditHistory: Sendable` public initializer(limit:Int = 100), canUndo/canRedo, `mutating record(_ changes:[PhotoEditChange])`, `mutating undo()->[PhotoEditChange]?`, `mutating redo()->[PhotoEditChange]?`. no-op changes는 제외하고 모두 no-op이면 history/redo를 바꾸지 않는다. 한 changes 배열이 한 undo 단위이며 새 유효 record는 redo를 비운다. 최대 limit개 유지. undo/redo 반환은 같은 forward change 배열이며 app이 before/after를 각각 적용한다.

## 앱 선택/조작

- `@Published var photoSelection=PhotoSelectionState()`를 단일 선택의 정본으로 사용한다. 기존 selectedID는 computed activeID, `selectedPhotoIDs`는 computed selectedIDs, `selectedPhotos`는 visiblePhotos 중 선택된 배열. 기존 select(_ photo)는 single로, 새 `selectFromClick(_ photo)`는 현재 NSEvent의 cmd/shift를 읽어 toggle/range/single. 선택 상태 변경 후 기존 cancelDraft/선택 세대/lutError/local 선택/render를 일관되게 갱신한다. active가 바뀌면 비동기 LUT import의 selectionGeneration을 증가한다.
- 그리드/필름스트립에 모든 선택 사진을 강조하고 기준 사진은 별도 `기준` 표시. Cmd+클릭으로 개별 선택, Shift+클릭으로 범위 선택. 보이는 각 썸네일의 체크 버튼으로도 개별 선택할 수 있어 modifier 키 없이 여러 장 선택 가능. 체크버튼과 사진 클릭/더블클릭의 gesture가 중복 실행되지 않게 분리한다. 선택된 그룹에서 사진을 더블클릭하면 focus로 그룹 유지하고 사진 보기로 전환한다. 접근성에 다중 선택 토글과 기준 사진으로 보기를 노출한다.
- toolbar 바로 아래에 얇은 선택 도구줄: `N장 선택 · 기준: 파일명`, `전체 선택`, `선택 해제`, `일괄 적용…`(선택>=2, active존재). Cmd+A는 텍스트 입력/모달/내보내기/일괄시트 중에는 가로채지 않고 사진 화면에서만 보이는 전체 선택. 필터/검색 변경 시 선택도 보이는 범위로 정리해 숨겨진 사진에 적용하지 않는다.
- 오른쪽 보정 패널에 선택>=2일 때 `슬라이더는 기준 사진에 적용됩니다`와 일괄 적용 버튼을 보여준다. LUT 항목에는 `선택한 N장에 LUT 적용` 바로가기(현재 lut존재, N>=2, import/library loading아님)를 추가한다. 이 버튼은 `.lut` 범위만 현재 선택 모두에 복사한다. 빠른 적용은 별도 허락 질문 없이 일반 사용자 버튼 동작으로 구현.

## 트랜잭션/시트

- 기존 undoStack/redoStack을 EditHistory로 대체한다. updateEdits는 기준 한 장 변경을 record하고 저장/렌더. batch도 한 record로 처리. 공통 변경 함수는 변경 전후를 먼저 만들고 사진 배열을 한 번 교체한 뒤 선택 정리/저장/렌더를 한 번 수행한다. 반복 updatePhoto로 필터 변화 도중 타깃이 바뀌지 않도록 한다. 기준 사진 포함 대상 중 실제 변경 사진만 기록, 별점/flag 유지. undo/redo는 모든 변경 대상의 before/after를 한 번에 복원하고 저장한다.
- `@Published var showBatchEdit=false`. BatchEditSheet는 열릴 때 기준 이름/보정값과 대상 id/파일명 목록을 snapshot으로 캡처한다. 체크 항목: `빛·색상·선명도` 기본on, `LUT` 기본on, `회전·크롭` 기본off, `부분 보정 영역` 기본off. 부분 보정은 같은 정규화 위치로 복사한다는 짧은 설명. 원본·별점·분류에는 영향 없음. LUT없음을 복사하면 대상LUT가 해제됨을 체크항목옆에 명시한다.
- 시트에 기준 이름과 선택한 N개 파일 목록을 표시하고 `선택한 N장에 적용` 버튼, 취소 버튼. components가 비면 적용 비활성화. 클릭 때 snapshot 대상 중 현재존재하고 여전히 보이는 사진만 처리하고 결과 메시지 `선택 N장 중 M장 보정 변경` 표시. 한 번의 Cmd+Z로 모든 적용을 되돌릴 수 있다. 시트가 열렸을 때 배경사진단축키는 동작하지 않게 한다.
- 공유 model 함수 `applyBatchEdits(source: EditSettings, to ids:[UUID], components:EditComponents)`는 현재 visible id와 교집합을 사용하고 catalogLoaded/loadError guard를 유지한다. `applyCurrentLUTToSelection()`은 현재 source와 선택 id snapshot으로 위 함수를 호출한다.

## 선택 내보내기

현재사진/필터전체에 `선택한 사진 (N장)` 옵션을 추가한다. `ExportScope` enum `.current, .selected, .visible`로 기존 export(visible:Bool)를 교체하고 실제 targets 배열을 시작 시 snapshot. export sheet 기본값은 선택>=2이면 selected, 그렇지않으면current. 대상0개면내보내기비활성화. 기존충돌회피/원본보존/오류보고유지.

## 검증

batch core: 선택 single/toggle/range/focus/all/clear/필터정리 invariants, 서로 다른 원래 보정값에 범위별 병합(특히 LUT만 적용 시 노출/구도/mask 유지와 nil LUT해제), 2장 이상 묶음 undo/redo·no-op·새 편집 redo초기화·history limit. `swift test --filter BatchEditingTests`.

app: LUT library와 batch core API가 준비되면 swift build. 테스트를 위해 임시 런타임 로그/제품에 숨은 테스트 명령을 추가하지 않는다. UI에 구현 내부 정보를 노출하지 않는다.

Astra: 최종 전체 swift test, release/codesign. 실제 UI에서 선택3장/기준변경/보정LUT일괄/대상밖사진보존/한번undo전체복원/필터정리/선택JPEG내보내기. 재실행 후 카탈로그와LUT보관목록복원. 필요하면 LibraryModel을독립검증실행파일에서불러와비동기와선택경계를검사한다.
