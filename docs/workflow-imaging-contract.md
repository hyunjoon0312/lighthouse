# 사진 작업 확장 — 이미지 계약 v1 (2026-09-29)

사용자가 추천한 여섯 기능 모두 승인했다. 이 계약은 플리커, 범위 마스크, 부분 노이즈 감소와 자동 마스크 재인식의 공용 모델을 정한다. 원본은 읽기만 한다. Astra가 설계·통합 검증, Sol이 아래 확정된 구현을 담당한다. 새 결정이 필요하면 메인에게 반환한다.

## 저장 타입과 호환

`WorkflowEditModels.swift`에 다음 Codable/Equatable/Sendable 공개 타입을 둔다. 키 누락은 기존 기본값, 새 키의 명시적 null/잘못된 타입/비유한·범위 밖 값은 거부한다. 중립 새 값은 encode에서 생략하여 기존 중립 썸네일 키를 유지한다.

- `BandDirection`: horizontal, vertical (띠가 뻗은 방향, EXIF 방향 적용 후 좌표).
- `FlickerSettings`: isEnabled=false, amount=0.7 (0...1), direction=.horizontal, cycles=8 (1...128, 이미지 높이/너비당 반복 횟수), phase=0 (0...1), amplitudeEV=0.25 (0...2), colorAmount=0 (0...1), profile: FlickerProfile?=nil. `isActive`는 enabled && amount>0. `FlickerProfile`은 각 RGB 채널의 3개 harmonic sin/cos 계수 배열(각 6개), 유한·절댓값<=2. 분석 계수는 기본 위상을 포함하고 phase는 사용자의 추가 이동이다. profile 없으면 sin 1차만 amplitudeEV로 사용한다. profile 있으면 추정 계수를 amplitudeEV/분석 기준 진폭으로 조정할 수 있도록 referenceAmplitudeEV를 저장(>0, <=2). 밝기 계수는 RGB 가중 평균; colorAmount로 채널별 계수를 밝기 계수와 혼합한다.
- `RangeSelection`: kind(luminance/color), lower=0, upper=1, softness=0.1, red/green/blue=0.5, tolerance=0.2. 모든 값 0...1, lower<=upper. sRGB로 현상한 중립 이미지에서 색/밝기를 선택한다. 생성 결과는 기존 RasterMask로 저장한다.
- `AutomaticMaskKind`: subject/background. `LocalAdjustment.automaticMaskKind: AutomaticMaskKind?`, `.rangeSelection: RangeSelection?`, `.noiseReduction: NoiseReductionSettings` 추가. 기존 baseMask는 provenance 없음으로 읽고 재인식 대상이라고 추측하지 않는다. provenance는 maskDefinition에 넣을 필요 없음(래스터가 실제 모양). noiseReduction.isActive를 hasEffect에 반영한다.
- `EditSettings.flicker: FlickerSettings` 추가. 전체 보정 복사/프리셋/스냅샷에 포함. LocalAdjustment의 새 필드는 부분 보정 복사에 포함.

## 플리커 분석과 적용

`FlickerCorrection.swift`와 전용 테스트에 구현한다. 공개 `ImagePipeline.analyzeFlicker(url: URL) throws -> FlickerAnalysis`; 결과는 `settings: FlickerSettings`, `confidence: Double`(0...1, 확률 아님), `message: String`. 무패턴/불확실은 localized 오류로 알리고 기존 보정을 건드리지 않는다. UI에서 실행한 한 사진만 분석하며 자동 가져오기 시 적용하지 않는다.

1. neutral 원본을 긴 변 768 이하로 현상. RGBAf 선형 RGB를 CPU로 읽고 alpha 거의 0/클리핑 픽셀을 제외한다. 주파수 분석용으로 RGB log2(max(value,0.002))를 쓴다.
2. 가로/세로 각각 최소 4개의 독립적인 폭 구간에서 행별 trimmed mean profile을 만든다. 완만한 밝기 기울기를 제거한다. cycles 2...64의 정수 후보를 sin/cos 상관으로 찾은 후 최상 후보 주변을 0.1 간격으로 refine한다. 구간 간 동일 주파수/위상의 일관성과 설명한 에너지 비율로 후보를 평가한다. 강한 실제 가로무늬 오인 가능성을 명시하고 낮은 근거에서는 분석 실패로 돌려준다. 임계값은 합성 band/no-band/실제 무늬 회귀 검사 결과로 메인에게 보고한다. 결과는 확률/정확도 보장이 아니다.
3. 선택한 주파수에서 RGB별 1...3 harmonic을 적합한다. DC는 제외해 전체 밝기를 임의로 바꾸지 않는다. 과도한 계수는 거부/제한한다. referenceAmplitudeEV는 profile 최대 변동 크기에 대응하도록 정한다.
4. RAW 현상/EXIF 방향 적용 → 플리커 → 전체 NR → 부분 NR → 기존 빛·색·복구·부분 보정·LUT·입자·구도·축소. RAW 노출/WB는 현상 단계이므로 먼저 적용된다.
5. Metal Core Image kernel로 선형 RGB에 `exp2(-clamp(correctionEV * amount,-2,2))`를 곱한다. RGB 상한을 잘라내지 않으며 alpha/extent 유지. 좌표는 EXIF 적용 이미지의 좌상단: horizontal은 y/H, vertical은 x/W. source extent 원점이 0이 아니어도 같다. cycles는 정규화 길이이므로 미리보기/최종 일치. kernel 준비 실패는 명시 오류, 무음 우회 금지.
6. 활성 플리커는 원본 RAW 현상으로 처리해 미리보기/내보내기 의미를 맞춘다. 원본의 날아간/뭉개진 정보 복원을 주장하지 않는다. global AI cache key에 플리커 설정을 포함해 예전 결과 재사용을 막는다.

## 범위 마스크

`ImagePipeline.rangeMask(url: URL, selection: RangeSelection) throws -> RasterMask`와 필요하면 이미지 입력 internal helper를 추가한다. neutral image를 긴 변 최대1536으로 방향 적용하여 생성하고 grayscale PNG와 파라미터를 저장한다. SubjectMasking의 PNG 저장 경계/8MiB 한도를 공유한다. 기본 luminance는 encoded sRGB의 0.2126/0.7152/0.0722 가중 밝기, lower...upper 안1, 바깥 softness 구간에서 부드럽게0. color는 unpremultiplied sRGB Euclidean distance/sqrt(3)를 tolerance/softness로 선택한다. transparent 영역은0. Metal kernel 또는 bounded 1536 CPU 계산 허용. 미리보기·최종은 동일 저장 래스터를 원본 좌표로 확대한다.

이는 실시간으로 모든 보정에 반응하는 마스크가 아니라 생성 시점의 neutral 색을 기준으로 한 저장 마스크다. 사용자는 범위를 바꿔 재생성할 수 있고 기존 브러시로 더하고 뺄 수 있다. 새 범위 마스크 생성은 automaticMaskKind=nil, rangeSelection 지정. 재생성 시 같은 area ID·효과·브러시는 유지한다.

## 부분 노이즈 감소

LocalAdjustment.noiseReduction에 기존 off/standard/ai와 강도를 그대로 쓴다. 모든 active local NR이 없으면 기존 fast path/중립 결과 유지.

- 원본 해상도의 플리커/전체 NR 결과를 공통 입력으로 삼아 영역별 denoised 후보를 만든 후 기존 fittedMask로 순서대로 합성한다. 후속 영역은 해당 영역에서 우선한다. 피사체·범위·브러시·그라데이션·반전 모두 같은 마스크 의미를 사용한다. local color 효과는 기존 단계에서 그대로 적용하고 NR을 두 번 적용하지 않는다.
- AI 서비스에는 optional cacheContext 문자열(기본 빈 값)을 추가할 수 있다. 부분 NR은 실제 입력을 결정한 RAW/global NR/flicker와 적용 NR을 포함한 안정된 키를 전달한다. 각 영역 이전 합성 결과를 모델 입력으로 쓰지 말고 공통 입력으로 쓴다. 마스크/대비/LUT 변경만으로 denoised 후보를 바꾸지 않는다. 렌더 소비자에서 사진/강도 전환 후 오래된 AI 결과를 표시하지 않는다.
- local/global NR active이면 RAW full-res, approximation disabled. 이웃 미리 읽기는 global 또는 local active AI면 건너뛴다.

## 검증과 인계

새 tests `WorkflowImagingTests.swift`, `WorkflowEditModelTests.swift`: Codable legacy/default/new-invalid, global/local 복사, synthetic gain band 감소/색 띠/방향/크롭/원점/alpha/무패턴 거부, range selection 경계, mask 밖 NR 영향 없음/안쪽 감소, off/0 우회, global/local AI 캐시 입력 구분. 실제 JPEG/HEIC/RAW 및 full suite는 메인 통합 검증. 성능·복원률 일반화 금지.

작업자는 먼저 공용 모델·함수 시그니처를 고정해 메인에 알린다. `.build` 명령은 메인이 lease를 줄 때만 실행한다. 제품 문서는 이 계약을 바꾸지 않고 별도 사용 안내로 작성한다.
