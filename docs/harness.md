# Lighthouse 개발 하네스

이 저장소에는 macOS 사진 앱 개발을 위한 역할 5개와 개발 조율 스킬을 포함한다. 메인 Astra가 설계·계약·통합을 맡고, 필요한 담당자만 선택해 실행한다.

| 역할 | 모델 | 담당 |
| --- | --- | --- |
| 앱 구현 | gpt-5.6-sol | SwiftUI·AppKit 화면, 선택·시트·메뉴와 상태 연결 |
| 이미지 처리 | gpt-5.6-sol | RAW, 영역 보정, LUT, 참조 색감의 확정된 구현 |
| 데이터 관리 | gpt-5.6-sol | 카탈로그, 가상 폴더, LUT 보관, 일괄 편집·히스토리 |
| 독립 리뷰 | gpt-6-astra | 원본 보존, 저장 호환, 색 공간, 비동기·모듈 경계 검토 |
| 실행 QA | gpt-6-astra | 실제 테스트·이미지·UI·패키징 검증과 근거 기록 |

Sol은 medium, 독립 리뷰·QA는 high를 시작점으로 쓴다. 개별 작업에서 사용자가 지정한 모델·effort가 우선한다. 메인은 파일 소유권과 의존성을 정하고 자식 최대 3개를 조율한다. `LibraryModel.swift`와 `PhotoModels.swift`는 매 작업에 한 소유자만 배정한다. 전체 빌드와 패키징도 한 번에 한 담당자만 실행한다.

## 사용

프로젝트를 신뢰한 새 Codex 세션에서 다음처럼 요청한다.

```text
$lighthouse-development 폴더별로 다른 정렬 기준을 저장하고 재시작 후 복원되게 해줘.
$lighthouse-development LUT를 바꿀 때 미리보기와 내보내기 색이 달라지는 원인을 확인하고 수정해줘.
$harness 현재 역할과 검증 절차가 코드 구조와 맞는지 점검해줘.
```

단순 질문과 작은 문구 수정에는 팀 실행을 강제하지 않는다. 새 TOML 역할·스킬의 자동 인식은 클라이언트와 세션에 달려 있다. 현재 역할 선택이 제공되지 않으면 조율자가 정의를 읽어 지시로 전달하고 실제 모델 선택 도구를 사용한다. 모델을 선택할 수 없으면 대체 전에 알린다.

## 저장소 구성

- [개발 조율 스킬](../.agents/skills/lighthouse-development/SKILL.md): 실행·의존성·통신·재개·완료 기준
- [팀과 파일 경계](../.agents/skills/lighthouse-development/references/team.md): 역할별 후보 범위와 공통 파일 소유권
- [검증 기준](../.agents/skills/lighthouse-development/references/verification.md): 원본·저장·색·UI·카메라 검사
- [.codex/agents](../.codex/agents): 실제 역할 TOML 5개
- [Astra–Sol 계약](../.agents/skills/astra-sol-workflow/SKILL.md): 사용자 모델 분담
- [공통 하네스](../.agents/skills/harness/SKILL.md): 로컬 실행 장부·통신·검증 도구

하네스 Python 도구는 **Python 3.11 이상**을 사용하며 외부 Python 패키지는 필요 없다. 앱 빌드의 Swift 환경과 별개다.

```sh
python3 .agents/skills/harness/scripts/validate.py --project .
python3 scripts/test-harness.py
```

검사 스크립트는 역할별 모델과 상태 관리 도구의 정상·실패·의존성·소유권·재개를 임시 프로젝트에서 확인한다. 테스트 fixture ID는 실제 에이전트가 아니다. 실제 자식 생성, 패킷 전달, 독립 검토는 별도 실행 근거로 확인한다.

실행 장부는 `.harness/runs/`, 중요한 메시지는 `_workspace/communications/`, 이미지와 검사 로그는 `.artifacts/`에 로컬로 보관하며 Git에서 제외한다. 사진·개인 카탈로그를 업로드하지 않는다. 테스트는 고유 `LIGHTHOUSE_DATA_DIR`로 사용자 데이터를 격리한다.

## 배포본과 유지보수

공통 하네스는 설치된 `codex-harness` 0.1.0의 스킬·런타임을 그대로 포함했다. 개인 홈 디렉터리나 플러그인 캐시는 실행 의존성이 아니다. 라이선스와 출처는 [LICENSE](../.agents/skills/harness/LICENSE), [NOTICE](../.agents/skills/harness/NOTICE)에 있다. 플러그인 배포본은 `skills/harness/`에 있어 그 실제 경로에서 복사했으며, 다른 레이아웃을 가정하는 저장소 설치기를 실행하지 않았다.

공통 스킬 업데이트는 현재 배포본과의 차이를 먼저 검토한다. 역할·모델·소유권 정책을 바꿀 때는 TOML, 개발 스킬, AGENTS 연결과 검사 스크립트를 함께 확인한다. 새 작업은 새 실행 ID로 남기고, 부분 재실행은 과거 결과를 보존하면서 바뀐 입력과 소비자만 다시 검증한다.
