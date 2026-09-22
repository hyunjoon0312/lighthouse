# 사진 폴더 관리 — FOLDERS-v1

2026-09-23. 실제 원본 위치별 찾아보기에 더해 앱 내부 관리 폴더를 만든다. 원본 파일을 옮기거나 복사하지 않고 같은 사진을 여러 관리 폴더에 넣을 수 있다. UI는 `내 폴더`와 `원본 위치`를 구분한다. 원본을 보존하는 기존 비파괴 편집/초기화/원본보기/별도 JPEG 내보내기를 그대로 제공하고 오른쪽 보정 패널에 `원본 보존 · 보정 자동 저장`을 명시한다.

## 소유권

Astra가 설계/docs/검증, Sol core가 MATCH-v1 완료 후 새 `Sources/LighthouseCore/PhotoFolderStore.swift`, 새 `Tests/LighthouseCoreTests/PhotoFolderTests.swift`를 소유한다. Sol app이 현재 소유 파일에 UI/model integration 및 새 `Sources/Lighthouse/PhotoFolderSheet.swift`를 작성한다. 다른 core 파일/카탈로그 포맷은 수정하지 않는다. 재위임 없음.

## 저장 API

`PhotoFolder: Identifiable,Codable,Equatable,Sendable` public var id:UUID,name:String,photoIDs:Set<UUID>; public init(id:UUID=UUID(),name:String,photoIDs:Set<UUID>=[]).

`PhotoFolderStore:Sendable` public init(url:URL), public static defaultURL (CatalogStore.defaultURL 옆 `folders.json`), public load() throws->[PhotoFolder], public save(_ folders:[PhotoFolder]) throws. version1 envelope `{version:1,folders:[...]}`. load 파일없음만[]; 잘못된 JSON/지원안되는version/중복folderid/빈name은 localizederror. save 역시 malformedfolder거부. name 최대80문자, trim된이름만 저장; case-insensitive 동일이름은 UI/model에서 금지하고 저장층도 검사해 일관성 유지. photoIDs는 중복제거 Set, encode시 UUID문자열 기준 정렬해서 저장, atomicwrite. save디렉터리 자동생성. 원본 URL/FileManager move/remove API는 없음.

`PhotoFolder` mutating `add(_ ids:Set<UUID>)`, `remove(_ ids:Set<UUID>)`는 멤버십만 변경. 임의 파일 경로를 이름으로 해석하지 않으며 `/` 같은 문자는 단순 표시이름이라 파일조작 영향없음. 숨겨진/현재없는 사진id는 load에서 지우지 않는다(카탈로그 복원 시 보존); UI counts는 현재photos와 교집합. CatalogStore.load/save API는 그대로 유지.

검증: 한 사진 여러폴더, add중복/remove격리, emptylibrary/restartserialization/멤버십동일, malformed/duplicateid/name/version읽기및쓰기실패, 해당폴더옆 sentinel 원본bytes unchanged. core focused `swift test --filter PhotoFolderTests`(app의진행중컴파일오류면 linkedtest실행)만.

## 앱/model

LibraryFilter `.collection(UUID)` 추가. @Published photoFolders:[PhotoFolder], foldersLoaded=false, folderLoadError:String?, folderSheetRequest:PhotoFolderSheetRequest? 추가. PhotoFolderSheetRequest는 Identifiable이며 create/rename 종류와 id/name/현재선택ids snapshot을 가진다(앱 내부 구현 가능).

start의 기존catalog성공 후 같은백그라운드 흐름에서 folders load 별도 Result, main에서 저장. 폴더load실패는 전체사진 사용/기존catalog저장을 막지 않되 폴더CRUD는 막고 sidebar에 오류 표시. foldersLoaded 성공일때만 folderStore.save. 기존 scheduleSave/flushSave에 catalogsnapshot과folderssnapshot을 동일saveQueue로 저장; folderloaderror이면 catalog만save해서 깨진folders를 덮지 않는다. 두 파일은 별도 atomic이며 disk오류를 기존메시지/종료보호로 보고한다.

model create/rename은 trim,1…80글자,case-insensitive unique validation. create는 sheet snapshot의 ids중 현재photos존재하는것을 사용. create 완료 새폴더 filter로전환+선택정리+save. rename은멤버십유지, filter UUID유지. delete는 해당folder메타데이터만 제거, 현재filter그folder이면all로전환; 원본/catalog사진/edits유지. delete확인 UI문구 `폴더만 삭제하며 사진과 보정은 보관됩니다.`.

`addSelectedPhotos(to folderID)` 현재selectedPhotos ids스냅샷을 merge+save, 성공count. `removeSelectedPhotosFromCurrentFolder()`는 collection일때선택ids를멤버십에서제거하고선택/필터정리+save, 원본/catalog유지. 폴더필터에서가져오기는 이번버전전체라이브러리가져오기기존동작유지; 폴더넣기는명시적인선택추가로완료. 폴더없을때빈화면에 `사진은 전체 라이브러리에서 선택해 이 폴더에 추가하세요.` 표시.

visiblePhotos collection은해당folder.photoIDs 포함기준이며기존검색/별점필터추가적용. 잘못된folderid는[]로보이며delete시all로복귀.

## UI

sidebar의새 `내 폴더` section + `새 폴더…` 접근가능button, 각folder이름/count와 contextMenu `이름 변경…`, `폴더 삭제…`. 현재폴더관리를위해선택상태row의ellipsis Menu도노출(우클릭필수아님). 기존filesystemfolders section은 `원본 위치`. 내폴더는flat구조, 중첩/드래그정렬이번범위없음.

선택도구줄에 `폴더에 추가` Menu: 기존폴더목록(없으면비활성안내), `새 폴더에 추가…`(현재선택포함create). collection에서 `이 폴더에서 빼기` button. 좁은창에서는선택도구줄이잘리지않도록2행/compact메뉴나horizontalScrollView사용.

PhotoFolderSheet width440내외, 이름TextField, create에서 `선택한 N장 포함` 체크기본on(0이면offdisabled), 취소/만들기또는이름변경. validationerrorinline. 확인누르면model함수결과success때dismiss. 이름있는필드 편집 중 사진keyboard단축키가동작하지않게 folderSheetRequest guard. 삭제는확인alert로진행.

오른쪽공통보정패널에원본보존안내를추가. 기존 `보정 초기화` 는현재사진의EditSettings.neutral로복원하고CmdZ로되돌릴수있다. 요청은원본파일복제/덮어쓰기버튼추가가아니며기존비파괴흐름의가시성과검증을강화한다.

## 통합검증

폴더생성→선택사진추가→폴더필터→이름변경→멤버십제거→다른폴더/전체원본및보정유지→재시작저장복원. foldermetadata손상시catalog사진편집정상,손상file원문보존. 실제RAW입력해시전후동일 확인. root가fullsuite/build/UI를최종담당한다.
