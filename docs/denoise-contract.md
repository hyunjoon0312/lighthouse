# 노이즈 감소 계약 (2026-09-29, v1)

JPEG·HEIC와 현상된 RAW에 일반 노이즈 감소와 실제 학습 모델을 사용하는 로컬 AI 디노이즈를 제공한다. 원본은 읽기만 하며, 보정값·복사·일괄 적용·undo·스냅샷·내보내기는 기존 EditSettings 경계를 따른다. 네트워크 추론·자동 다운로드는 없다.

## 저장과 화면

- `NoiseReductionMode: String, Codable, CaseIterable, Sendable`: `off`, `standard`, `ai`.
- `NoiseReductionSettings: Codable, Equatable, Sendable`: `mode` (기본 off), `amount` (0…1, 기본 0.35). `isActive`는 off가 아니며 amount > 0인 경우. 공개 init, 기본값 제공.
- `EditSettings.noiseReduction`에 저장한다. 과거 키 누락은 기본값, 존재하는 null/잘못된 타입·모드·비유한 또는 범위 밖 amount는 로드 오류. 기본 설정은 encode에서 생략해 기존 썸네일 키를 보존한다.
- global 복사·일괄 적용에 포함한다. geometry/LUT만 적용할 때는 바꾸지 않는다.
- 전체 보정에 항상 보이는 ‘노이즈 감소’: 끔 / 일반 / AI 선택, 강도 0…100%, 초기화. RAW 현상 컨트롤과 구분한다. AI 안내는 Mac에서 처리, 첫 처리 시간, 100% 확대 확인. 일반도 JPEG·HEIC에 실제 동작한다. 기존 렌더 진행·오류 표시에 연결한다.

## 처리와 성능

- RAW 디코더/방향 적용 → 새 노이즈 감소 → 기존 전체 보정·복구·부분 보정·LUT·입자·구도·축소. RAW 노출/WB는 기존처럼 디코더가 먼저 적용한다. AI는 센서 모자이크를 직접 처리하는 모델이 아니다.
- off 또는 amount 0은 정확한 우회이며 모델 로드도 하지 않는다. 활성화한 노이즈 감소는 RAW도 원본 해상도(scale 1)에서 처리한 뒤 축소한다. AI에서는 RAW 근사 현상을 사용하지 않는다. 미리보기·내보내기 의미를 맞춘다.
- 일반: Core Image CINoiseReduction, noiseLevel = amount * 0.1, sharpness = 0. 원래 extent 유지. 추가 샤프닝은 기존 샤프니스 항목으로 한다.
- AI: KAIR 공식 `ffdnet_color_clip.pth` (MIT), FFDNet 12 conv, 96 feature channels. 모델은 SDR sRGB RGB 0…1과 sigma = amount * 75 / 255를 사용한다.
- 번들 모델 `FFDNet.mlmodel`: FP32 신경망, `input` shape [13,160,160], `output` shape [12,160,160]. 320×320 RGB tile을 pixel-unshuffle한 12 plane + 상수 sigma plane. 채널 순서는 4*c + 2*dy + dx. 출력은 pixel-shuffle하여 직접 복원 RGB(잔차 출력이 아님). conv는 PyTorch의 zero padding 1, 마지막을 제외한 ReLU.
- 타일 중심 256×256, halo 32px. 전체 이미지 좌표에서 edge replicate. 모든 타일의 짝수 phase 유지. 마지막 불완전 타일·홀수 크기·작은 이미지도 처리한다. 외곽 padding과 모델 내부 padding을 구분한다.
- CIContext로 타일만 sRGB RGBAf로 읽고 alpha를 보존한다. 모델 RGB에는 unpremultiplied 값을 넣는다. 출력은 원래 RGB + (model(clamp(RGB)) - clamp(RGB))로 범위 밖 하이라이트 잔차를 보존한 뒤 alpha를 다시 곱한다. 결과는 sRGB RGBAh Data로 materialize; 전체 source Float 사본을 만들지 않는다. 원래 extent/좌표·orientation 유지.
- 공유 직렬 AI 서비스가 모델과 최대 1개 결과만 보유한다. 캐시 키는 엔진 버전·정규화 경로·파일 크기/수정 시각·RAW 현상/노출/WB·노이즈 설정·크기로 구분한다. 다른 전체 보정과 축소 크기는 포함하지 않아 재사용한다. 동시에 같은 원본을 요청한 미리보기/썸네일/내보내기는 중복 추론하지 않는다. 캐시 외의 이전 결과를 무한히 보유하지 않는다.
- 처리 최대 64 million pixels, 초과/잘못된 크기는 이해 가능한 오류. 모델 누락·컴파일·추론 실패는 오류로 전달하며 일반 필터로 몰래 대체하지 않는다. `.app`에서는 개발 폴더 fallback 금지. CPU+GPU Core ML 실행, 오프라인. 빌드 번들 레이아웃은 기존 FaceAnalyzer의 검증된 resolver 방식을 따른다.
- Composition.source는 기존 RAW 원본 현상 결과를 유지해 HDR gain 계산을 변경하지 않는다. AI 모델의 HDR 품질이나 실제 센서 노이즈 제거 수준은 일반화하지 않는다.

## 모델 재현

공식 KAIR release v1.0의 color_clip 가중치와 저장소 revision `fc1732f4a4514e42ce15e5b3a1e18c828af47a1e`의 코드/라이선스를 사용한다. 변환 스크립트에 다운로드 URL·SHA256·도구 버전을 고정하고 `torch.load(weights_only=True)`로 읽는다. 원본 가중치와 Core ML의 deterministic tile 출력 수치 parity, 합성 잡음의 MSE 감소를 기록한다. 라이선스·출처·모델 입력 설명을 리소스에 동봉한다.

## 검증

- Codable 기존 데이터·roundtrip·잘못된 값, global-only batch/undo/reset/snapshot 저장.
- 실제 모델 추론, noise reduction 대조(MSE·평탄 영역·edge 보존), sigma/0 우회, RGB 순서·alpha·홀수 크기·타일 경계·EXIF orientation.
- JPEG 및 실제 ImageIO HEIC 인코딩 입력 → preview/export 픽셀·크기·색 일관성. 원본 bytes SHA256 보존.
- 캐시 파일/RAW 설정/강도 invalidation, 모델 번들 누락 오류. 릴리스 `.app` 오프라인 모델 로드.
- 관련 단위 검사 후 전체 swift test, swift build, universal 앱 빌드/서명/실행. 실제 UI가 환경에서 막히면 별도 미검증으로 적는다.

참조: [KAIR](https://github.com/cszn/KAIR), [공식 FFDNet 구현](https://github.com/cszn/KAIR/blob/fc1732f4a4514e42ce15e5b3a1e18c828af47a1e/models/network_ffdnet.py), [MIT 라이선스](https://github.com/cszn/KAIR/blob/fc1732f4a4514e42ce15e5b3a1e18c828af47a1e/LICENSE), [CINoiseReduction](https://developer.apple.com/documentation/coreimage/cinoisereduction).
