# 사진 작업 확장 — 라이브러리 계약 v1 (2026-09-29)

확정 범위: 전체 백업·새 폴더 복원, 중복·유사 사진 후보, 스마트 미리보기. 원본 변경/삭제 없음, 자동 전송 없음, 다른 작성자의 파일 수정 없음. 새로운 설계 선택은 Astra 메인에게 문의한다.

## 스마트 미리보기

새 `SmartPreviewStore.swift`. `public struct SmartPreviewStore: Sendable`, init(directory: URL), static defaultDirectory (`CatalogStore.defaultURL` 옆 SmartPreviews). `create(for photo: PhotoAsset, pipeline: ImagePipeline) throws -> SmartPreviewRecord`, `record(for photo: PhotoAsset) throws -> SmartPreviewRecord?`, `previewURL(for photo: PhotoAsset) throws -> URL?`, `remove(for photo: PhotoAsset) throws`. 레코드는 version=1, photoID, sourcePath, sourceSize, sourceModifiedAt, width,height, previewSHA256. per-photo UUID의 TIFF/JSON 두 파일. 경로 필드는 파일 이름으로 직접 쓰지 않는다.

- 원본을 neutral 설정으로 긴 변2560 이하의 16bit sRGB TIFF로 생성(이미지 metadata API 출력은 디코딩된 방향). ImagePipeline 새 `makeSmartPreview(url: URL, maxPixel: Int = 2560) throws -> Data`가 이를 제공하며 imaging 작업자가 소유한다. 새 API 준비 전 소비 코드는 작성해도 빌드는 기다린다.
- 원본의 파일 크기/mtime를 전후 비교하고 달라지면 결과를 버린다. TIFF를 먼저 원자적으로 저장하고 JSON을 마지막에 저장한다. 파일sha 및 실제 읽을 수 있는 TIFF 크기를 확인한다. 기존 preview를 교체하다 실패해도 정상 이전 쌍이 손상되지 않게 임시 디렉터리+교체 또는 버전 파일명을 쓴다(레코드에 생성 UUID를 저장하는 방식 권장; generation filename validation 필수).
- 원본이 없을 때만 fallback 허용. 파일이 있으면 원본 처리 오류를 proxy로 감추지 않는다. 원본이 있으면 sourcePath/size/mtime가 같은 레코드만 유효. 원본이 없어도 photoID/path가 같은 정상 record+TIFF는 유효. 같은 photo ID의 원본 위치가 바뀌면 기존 preview 무효(재생성 안내).
- 복원 시 photoID 유지, sourcePath 및 복원한 원본 size/mtime를 재연결한다. preview 바이트sha는 그대로. 원본 미포함 백업은 기존 경로를 유지한다.
- 공개 `SmartPreviewStore.previewEdits(_ edits: EditSettings) -> EditSettings`: global/local NR off, flicker off, rawDevelop default, hdrAmount0, sharpness0, grain0, retouchStrokes[]로 만든 복사본. 나머지 노출/WB/대비/색/LUT/마스크/구도는 RGB proxy에 근사 적용. 원래 저장된 edits는 절대 바꾸지 않는다. 전역·부분 NR의 저장 타입은 이미지 계약을 따른다.
- 화면은 '스마트 미리보기 · 원본 없음 · 기본 보정 근사'를 표시. 100% 원본 디테일 판정·AI/RAW 디테일·플리커 분석/범위마스크 재생성·자동 마스크·최종 내보내기에는 원본 필요. 정식 render/export의 자동 fallback은 금지. 앱이 preview URL과 previewEdits를 명시적으로 사용한다.

## 중복·유사 사진 후보

새 `SimilarPhotoFinder.swift`. 공개 result/group/type를 두고 `SimilarPhotoFinder.analyze(photos:[PhotoAsset], pipeline:ImagePipeline, isCancelled:@Sendable ()->Bool, progress:@Sendable(Int,Int)->Void) throws -> SimilarPhotoResult` 제공. result groups + per-file 실패 요약, kind exact/similar. group photoIDs와 stable UUID. 같은 정규화 원본 경로(가상 사본 포함)는 한 항목으로 분석, RAW+JPEG는 exact로 간주하지 않는다.

- exact는 파일 전체 streaming SHA256, 파일 크기/mtime 전후 일치 확인. 크기가 같은 집합만 hash하여 불필요한 IO를 줄여도 된다.
- similar는 방향 적용 미리보기로 64bit difference hash + 16x16 RGB 요약 + aspect ratio. Hamming<=8, ratio 차<=0.08, normalized RGB RMSE<=0.12를 초기 기준으로 쓴다. 모든 쌍 O(n²) 나열 대신 dHash의 9개 chunk 후보 또는 BK-tree를 비교한다. 단색/저정보 영상은 similar 후보에서 제외하거나 별도 보수적인 기준을 둔다. 정확도 검증 없이 similarity score를 확률로 표시하지 않는다.
- exact 그룹은 similar 그룹에서 중복 노출하지 않는다. similar는 대표와 모두 조건을 만족하는 후보만 포함하여 느슨한 연결 chain을 피한다. 사진 이동·재편집 여부와 무관하게 분석은 보정 전 이미지 기준. 실패는 정상사진 검색을 막지 않는다. 취소는 사용자에게 중단과 완료분을 구분하며 자동 표시/삭제 없음.
- 앱은 그룹 썸네일·파일명·kind와 '이 묶음 비교'를 제공한다. 기존 여러 장 보기로 보내며 별점/선택/제외 및 원본보존 정책 유지.

## 전체 백업/복원

새 `LibraryArchive.swift`. ZIP 해제 의존성 없이 `.lighthousebackup` 디렉터리 패키지를 사용한다(앱에서 선택 가능; Finder에서 폴더로 보여도 동작). `LibraryArchive.create(dataDirectory: URL, destination: URL, includeOriginals: Bool, isCancelled: @Sendable()->Bool, progress:@Sendable(Int,Int)->Void) throws -> LibraryArchiveSummary`, `inspect(at: URL) throws -> LibraryArchiveSummary`, `restore(from: URL, to destination: URL, isCancelled..., progress...) throws -> URL`(새 dataDirectory).

- create 전에 앱이 저장을 flush하고 편집·가져오기·사람 분석·내보내기 등 데이터 변경을 잠시 막는다. 작업 도중 원본이 외부에서 변경되면 해당 백업을 실패 처리. 루트 destination은 새 경로여야 하며 현재 library 안/원본 경로와 겹치면 거부.
- 허용 Data: catalog.json 필수, folders.json, smart-folders.json, presets.json, people.json, LUTs/, Masks/, SmartPreviews/. 썸네일/기존 Backups/키체인/OAuth/UserDefaults/log 제외. 선택적 파일이 없는 것은 허용하지만 손상됐으면 빈 데이터로 대체하지 않는다. symlink·특수파일을 복사하지 않고 거부한다. 원본 파일 참조는 canonical target regular file을 읽어 복사할 수 있다.
- originals 포함 시 canonical source path마다 한 번 복사, OriginalFiles/<UUID>.<extension> 형태의 충돌 없는 상대경로. virtual copies는 같은 파일을 공유. 원본 누락이면 전체 포함 백업을 완료로 보고하지 않고 오류(원본 미포함으로 다시 시도 안내). manifest original mapping은 old path→relative copy path. 카탈로그 원본은 backup Data에서 원래 경로를 유지하다 restore에서 바꾼다.
- manifest version1, createdAt, includesOriginals, photoCount, 파일별 relative path/size/SHA256, original mapping을 저장. 모든 상대경로는 절대경로/.. /빈component/중복/경로 충돌 거부; symlink directory 포함 경로 탈출 금지. manifest 자체 외 예상하지 않은 파일도 검증에서 거부(단 `.DS_Store`는 처음부터 복사하지 않고 검사에서 명시적으로 무시 가능). 파일 hash는 streaming, metadata length만 믿지 않는다. 백업은 앱 라이브러리 데이터의 사본이며 비밀 인증은 포함하지 않는다.
- 검사: 모든 hash·필수 파일·카탈로그 로드·각 보조store 로드·참조 Masks/LUT(편집+스냅샷+프리셋)를 검증. 원본 미포함은 old photo path가 없는 것을 허용. 잘못된 archive는 기존 사용자 데이터에 쓰기 전에 거부한다.
- destination은 아직 없는 새 폴더여야 한다. 같은 parent의 전용 staging에 복사/검사/경로변경 후 overwrite 금지 atomic rename으로 노출한다. 실패/취소 시 staging만 삭제하고 기존 폴더·archive·원본 유지. archive 내부/현재 library 위로 restore 금지(호출자가 현재root와겹침 사전확인, core는 archive와겹침거부).
- 복원한 catalog photo.path, people analysis.sourcePath/size/mtime, SmartPreviews record source fields를 새 Originals 경로로 재연결. photoID·folders·snapshots·marks·people 유지. lastExport는 새 라이브러리에서 nil로 하여 예전 내보내기 파일을 교체하는 권한을 이어받지 않는다. 카탈로그에 없는 people 분석은 기존store 유효성대로 보존하되 원본 mapping이 있을 때만 path를 바꾼다.
- App의 LibrarySession이 복원 폴더를 새 LibraryModel로 열고 이전 catalog도 다시 열 수 있게 한다. core CatalogStore.defaultURL은 LIGHTHOUSE_DATA_DIR 최우선, 그 다음 UserDefaults `activeLibraryDirectory`(비어 있지 않은 absolute local path), 그 다음 기존기본폴더. LibraryModel은 directory injection으로 모든store/pipeline 경로를 동일하게 고정한다. 실행 중 defaultURL에 의존해 쓰기 대상이 바뀌지 않게 한다.

## 검증

새 `SmartPreviewTests.swift`, `SimilarPhotoTests.swift`, `LibraryArchiveTests.swift`만 소유. 정상/누락원본/파일변경/깨진TIFF/원자교체실패, exact다른파일명·recompress유사·무관/단색제외·가상사본제외·취소, full/metadata-only roundtrip·마스크/LUT/사람/미리보기·해시손상·경로탈출/symlink·취소/실패 원본보존·기존destination거부. 실제 성능/재시작/화면은 메인 통합 검사.

작업자가 공개 API 타입의 정확한 필드·초기화자를 먼저 확정해 메인에 인계. `.build` lease는 메인에게 받은 동안에만 사용. 공유 PhotoModels/ImagePipeline/앱 파일은 수정 금지.
