# 역할과 코드 경계

배정 전에 읽는다. 아래 범위는 담당 후보이며 자동 쓰기 권한이 아니다. 최신 작업 패킷에 실제 파일 목록을 명시한다. 경로는 프로젝트 루트 기준이다.

| 담당 | 모델 / effort | 책임과 기본 경계 |
| --- | --- | --- |
| 메인 조율자 | Astra, 중요한 설계·검증 high | 요구·아키텍처·색 처리·호환 판단, 계약·의존성·소유권, 공통 설정, 통합·최종 판정. 별도 하위 팀장을 만들지 않는다. |
| `lighthouse_app` | gpt-5.6-sol / medium | 확정된 SwiftUI·AppKit 화면, 선택·시트·작업 상태 연결. `Sources/Lighthouse/` 안의 배정 파일. |
| `lighthouse_imaging` | gpt-5.6-sol / medium | 확정된 Core Image RAW·전역/영역 보정·LUT·참조 매칭. `ImagePipeline`, `LocalMaskGeometry`, `CubeLUT`, `ReferenceColorMatch`와 해당 테스트. |
| `lighthouse_catalog` | gpt-5.6-sol / medium | 확정된 카탈로그·관리 폴더·LUT 보관·일괄 선택/히스토리 저장. `CatalogStore`, `PhotoFolderStore`, `LUTStore`, `BatchEditing`와 해당 테스트. |
| `lighthouse_reviewer` | gpt-6-astra / high | 읽기 전용 독립 검토. 생산자·소비자, 원본 보존·호환·색 공간·비동기 상태. 파일 생성·수정과 캐시를 쓰는 검사를 하지 않는다. |
| `lighthouse_qa` | gpt-6-astra / high | 중요한 실행·통합·이미지·UI 검증. 배정된 로그·임시 데이터·빌드 캐시만 쓴다. 제품 수정은 원래 소유자에게 반환한다. |

개별 요청의 명시적 모델·effort가 이 시작점보다 우선한다. 역할 파일의 기본값을 바꿨다는 이유로 현재 실행 모델까지 전환됐다고 보고하지 않는다. 현재 런타임에 역할 선택 기능이 없으면 TOML 지시를 전달하고 실제 model·reasoning_effort 인자를 지정한다. 지정 모델이 가용하지 않거나 분류가 애매하면 대체 전에 사용자에게 묻는다.

## 공통 소유권

- 메인: `AGENTS.md`, `.codex/`, `.agents/`, `Package.swift`, `Resources/Info.plist`, `.gitignore`, 빌드 스크립트, 정책·아키텍처·기능 계약, 실행 장부와 통합 결정. 확정된 기계적 변경은 명시적인 단일 Sol 소유자에게 배정할 수 있다.
- `Sources/Lighthouse/LibraryModel.swift`: 선택, 필터, 카탈로그, 일괄 편집, LUT, 폴더와 내보내기가 만나는 공통 소비자다. 한 명의 앱 작업자에게만 배정한다. 독립 패널 작업자는 이 파일을 동시에 수정하지 않는다.
- `Sources/LighthouseCore/PhotoModels.swift`: Codable 저장 계약과 편집 설정의 공통 타입이다. 메인이 호환·기본값·오류 정책을 확정한 뒤 한 소유자에게 먼저 구현시킨다. 소비자는 승인된 인터페이스를 받는다.
- `Tests/LighthouseCoreTests/CoreTests.swift`: 여러 코어 경계가 공유한다. imager와 catalog 작업자에게 통째로 동시에 배정하지 않는다. 새 회귀 테스트가 필요하면 목적이 다른 새 테스트 파일을 각각 소유하게 한다.
- `.build/`, `dist/`: 실행 부작용도 소유권이다. 코드 소유권이 달라도 동시에 같은 빌드·패키징을 실행하지 않는다.

## 제품 계약 선택

관련 작업에서만 해당 문서를 읽고, 문서와 실제 코드가 다르면 메인에게 근거를 반환한다.

| 변경 | 루트 문서와 연결 경계 |
| --- | --- |
| 화면·공통 앱 | `docs/architecture.md`, `docs/implementation-contract.md`; LibraryModel → Workspace/Inspector/메뉴 |
| 브러시 영역 | `docs/local-adjustments-contract.md`; 정규화 원본 좌표 → 화면 변환 → 최종 해상도 마스크 |
| LUT 파싱·처리 | `docs/lut-contract.md`; red-fastest 3D 표·DOMAIN → sRGB 조회 → 작업 공간 합성 |
| LUT 보관 | `docs/lut-library-contract.md`; 내용 해시·표시 이름 sidecar → 목록 → 카탈로그 LUT 참조 |
| 여러 장 편집 | `docs/batch-edit-contract.md`; 보이는 선택 → 선택한 구성요소만 적용 → 단일 undo 단위 |
| 참조 색감 | `docs/reference-match-contract.md`; 현재 LUT 제외 소스와 중립 참조 → 통계 변환 → preview/store/export |
| 사진 폴더 | `docs/photo-folders-contract.md`; 가상 폴더의 사진 ID → 필터·선택; 실제 원본 경로는 유지 |

## 인계 조건

코어 작업자는 공개 타입·함수, 기본값·오류와 실제 검사를 먼저 알린다. 앱 작업자는 취소·늦게 끝난 작업·선택 전환에 대한 소비 동작을 확인한다. 새 계약이 필요하면 파일·호출자·호환 영향과 함께 질문하고, 확정 전 공통 인터페이스를 임의로 바꾸지 않는다.

검토자는 완료된 diff와 요구·검증 기준으로 판단한다. 다른 작업자가 쓰고 있는 중간 코드를 최종 결함으로 단정하지 않는다. QA는 실패 재현·기대/실제·생산자/소비자·로그를 반환하며 수정하지 않는다. 메인이 수정 소유자를 확정한다.
