# Lighthouse 앱 아이콘

등대의 빛과 사진 조리개를 결합한 macOS 앱 아이콘이다. 앱의 기존 차콜 배경과 앰버 `#FFAB4D`를 사용한다. 바깥 여백은 투명하며 문자는 넣지 않았다.

- 원본: `LighthouseIcon.png` (1254 × 1254, RGBA)
- 앱 리소스: `../App/Lighthouse.icns`
- 연결: `../Info.plist`의 `CFBundleIconFile`
- 제작: 2026-09-26, 내장 `image_gen` 도구. 별도 API/CLI 생성은 사용하지 않았다.

저장소 루트에서 다음 명령으로 아이콘을 다시 변환하고 앱을 빌드한다. `sips`와 `iconutil`이 있는 macOS에서 실행한다. 아이콘 변환은 생성 이미지의 크기와 파일 형식만 바꾸며 알파를 유지한다.

```sh
./scripts/build-icon.sh
./scripts/build-app.sh
```

## 검증

2026-09-26에 원본의 실제 알파 투명도, ICNS 왕복 변환의 10개 크기(16–1024 px), 32·128 px 표시를 확인했다. 앱 번들의 아이콘 참조와 리소스 일치, release 빌드 및 ad-hoc 서명 검사를 통과했다. 이미 실행 중인 앱이나 Dock의 기존 아이콘은 macOS 캐시 때문에 재실행 후 갱신될 수 있다.

## 생성 프롬프트

```text
Use case: logo-brand
Asset type: finished macOS application icon for Lighthouse, a native professional RAW photo editor.
Primary request: design ONE exquisite, memorable, production-ready app icon combining a lighthouse beacon and a photographic aperture into a single coherent sculpted emblem.

Canvas: square 1024 x 1024 PNG with actual transparent alpha outside the icon. Center a macOS continuous rounded-square tile occupying about 82% of the canvas, with generous uniform transparent margins. The tile is straight-on, perfectly square, no perspective. Use a deep charcoal graphite tile (#25272A) with restrained softly rounded bevel and a fine edge highlight.
Subject: a bold warm-amber and ivory lighthouse silhouette integrated within a large six-blade camera aperture. The tower is simple and tapering, the lantern is the luminous focal point. The aperture blades curve around the tower as one elegant circular frame, conveying precision optics. Two short understated beams from the lantern suggest light being shaped. Keep the entire mark simple, visually unified and readable as a small Dock icon; generous negative space around the emblem.
Color palette: the existing Lighthouse app uses graphite and warm amber #FFAB4D. Match this palette. Rich amber outer edges, soft pale-gold highlights, subtle ivory lantern core. No rainbow.
Style: high-end native Mac app icon, tactile satin-metal and finely frosted optical glass, disciplined geometry, softly embossed depth. Crisp silhouette, controlled highlights, quiet premium photographic-tool character. Polished but minimal, no tiny mechanical details.
Composition: single centered icon only, complete edges visible, balanced visually. Beautiful at 1024px, unmistakable shape at 32px.
Text: absolutely no lettering, no words, no initials.
Avoid: no camera body, no landscape or ocean, no stars, no extra badges, no mockup environment, no multiple variants or presentation sheet, no huge lens flare, no harsh black outline, no white background, no checkerboard drawn into pixels, no Adobe or Lightroom mark. Transparency must be real. Deliver the final isolated icon asset.
```
