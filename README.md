# Lighthouse

macOS에서 사진을 정리하고 선별한 뒤 RAW를 보정해 JPEG로 내보내는 로컬 데스크톱 앱입니다. Panasonic LUMIX S9의 RW2를 주 대상으로 개발했습니다.

## 실행

현재 Mac에서는 `dist/Lighthouse.app`을 더블클릭해 실행하면 됩니다. **사진 가져오기**로 시작하세요. 외부 패키지나 계정은 필요하지 않습니다.

소스에서 빌드하려면 macOS 15 이상과 Swift 6을 포함한 Xcode 또는 Command Line Tools가 필요합니다.

```sh
./scripts/build-app.sh
open dist/Lighthouse.app
```

개발 중에는 `swift run Lighthouse`로 실행할 수 있습니다. `Package.swift`를 Xcode에서 열어 개발할 수도 있습니다. 현재 번들은 로컬 실행용 ad-hoc 서명을 사용하며 배포용 공증은 포함하지 않습니다.

## 사용 흐름

1. **사진 가져오기**에서 RW2·JPEG·HEIC·PNG·TIFF 파일이나 사진 폴더를 선택합니다. 하위 폴더도 탐색하며 같은 경로를 반복 가져오면 중복을 제외합니다.
2. 그리드에서 사진을 고르고 별점과 선택·제외 표시를 붙입니다. **원본 위치**별로 찾아보거나 **내 폴더**를 만들어 사진을 묶습니다. [폴더와 원본 보존](docs/photo-folders.md)을 참고하세요.
3. 사진 보기에서 노출, 색온도·틴트, 대비, 하이라이트·섀도, 채도, 선명도를 조절합니다. 원본 보기, 보정 초기화, 회전과 중앙 비율 크롭을 사용할 수 있습니다.
4. **부분 보정 → 영역 추가**에서 사진 위를 브러시로 칠하고 해당 부분의 노출·대비를 조절합니다. 지우개, 경계 부드럽게, 여러 영역, 마스크 표시를 지원합니다. 자세한 방법은 [부분 보정 안내](docs/local-adjustments.md)에 있습니다.
5. **전체 보정 → LUT → .cube 추가…**로 여러 LUT를 보관하고 목록에서 골라 적용합니다. 강도는 0–100%로 조절합니다. [LUT 사용 안내](docs/lut.md)에서 형식과 백업 방법을 확인할 수 있습니다.
6. **참조 사진 색감 맞추기…**에서 원하는 사진의 톤·색 분포를 근사하고 결과를 적용하거나 새 LUT로 보관합니다. **S9용 .cube 내보내기…**로 카메라 지원 규격의 파일을 만들 수 있습니다. [참조 색감과 S9 안내](docs/reference-match.md)를 읽어주세요.
7. 체크 버튼·⌘클릭·⇧클릭으로 사진을 여러 장 선택한 뒤 **일괄 적용…**에서 보정 범위를 고릅니다. **선택한 N장에 LUT 적용**은 LUT만 복사합니다. [여러 사진 편집 안내](docs/batch-editing.md)에 자세한 동작을 설명했습니다.
8. 비교 모드에서는 기준 사진과 다른 사진을 나란히 보며 선별합니다. 화면 맞춤과 100% 보기를 전환할 수 있습니다.
9. **JPEG 내보내기**에서 현재 사진, 선택한 사진 또는 현재 필터 결과를 저장합니다. 전체·부분 보정과 LUT를 함께 적용하며 긴 변과 품질을 선택할 수 있고 파일명이 겹치면 접미사를 붙입니다.

## 단축키

| 키 | 동작 |
| --- | --- |
| ⌘O | 사진·폴더 가져오기 |
| ⌘A | 보이는 사진 전체 선택 |
| ⌘클릭 / ⇧클릭 | 개별 선택 추가·해제 / 범위 선택 |
| ← / → | 이전 / 다음 사진 |
| 0–5 | 별점 설정 |
| P / X / U | 선택 / 제외 / 표시 해제 |
| G / E / C | 그리드 / 사진 / 비교 |
| `\` | 원본 보기 전환 |
| ⌘Z / ⇧⌘Z | 보정 실행 취소 / 다시 실행 |
| ⇧⌘E | JPEG 내보내기 |

## 사진과 보정값 저장

원본은 가져온 위치에 그대로 유지하고, 분류와 보정값은 `~/Library/Application Support/Lighthouse/catalog.json`에 자동 저장합니다. 원본을 이동하거나 외장 드라이브 연결을 해제하면 다시 접근 가능한 상태로 복원해야 합니다. 원본 삭제와 이동은 앱에서 수행하지 않습니다.

사진과 보정은 `catalog.json`, 내 폴더 구성은 같은 위치의 `folders.json`, LUT와 표시 이름은 `LUTs` 폴더에 보관합니다. 첫 버전은 개인 라이브러리를 대상으로 하며 수만 장의 대규모 처리 성능은 아직 검증하지 않았습니다. 백업할 때 이 파일·폴더들과 원본 사진을 함께 보관하세요.

RAW 지원은 macOS의 카메라 지원에 따릅니다. 현재 개발 Mac에서 S9의 일반 24MP RW2를 실제 현상·내보내기로 확인했습니다. 모든 펌웨어·촬영 모드의 RW2를 확인한 것은 아닙니다. 내보내기는 SDR sRGB JPEG이며 자유 영역 크롭, AI 마스킹, 클라우드 동기화, Lightroom 카탈로그 호환은 아직 제공하지 않습니다.

## 검증과 개발 자료

```sh
swift test
swift build
```

테스트용 카탈로그를 분리하려면 다음과 같이 실행합니다.

```sh
LIGHTHOUSE_DATA_DIR="$PWD/.artifacts/test-catalog" swift run Lighthouse
```

- [제품 범위와 기술 설계](docs/architecture.md)
- [파일별 구현 계약](docs/implementation-contract.md)
- [부분 보정 설계와 구현 계약](docs/local-adjustments-contract.md)
- [LUT 설계와 구현 계약](docs/lut-contract.md)
- [LUT 보관 목록 계약](docs/lut-library-contract.md)
- [일괄 편집 계약](docs/batch-edit-contract.md)
- [참조 사진 색감 계약](docs/reference-match-contract.md)
- [폴더 관리 계약](docs/photo-folders-contract.md)
- [검증 기록](docs/verification.md)
- [프로젝트 작업 지침](AGENTS.md)
