# 컬러 그레이딩·분할 톤 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 그림자·중간톤·하이라이트·전체 영역의 컬러 그레이딩을 앱 조절과 Lightroom 프리셋 가져오기(분할 톤 포함)에 연결한다.

**Architecture:** `ColorGrading` 모델을 `EditSettings`에 더한다. 렌더는 기존 64³ 색 큐브 안에서 곡선 → HSL → 그레이딩 순서로 계산하므로 미리보기·내보내기 경로와 실패 경로가 늘지 않는다. 프리셋은 기존 `scalars` 사전에 Adobe 키 14개를 더해 "있는 값만 적용" 규칙을 그대로 쓴다. UI는 새 `ColorGradingControls`(영역 버튼 + 색상 바퀴 + 슬라이더)를 `AdvancedColorControls`에 끼운다.

**Tech Stack:** Swift 6 / SwiftPM, Core Image(`CIColorCube`), SwiftUI(macOS), XCTest.

**Spec:** [docs/color-grading-contract.md](../../color-grading-contract.md)

## Global Constraints

- 원본 사진을 변경·삭제·덮어쓰지 않는다. 카탈로그·보정값은 로컬에 둔다.
- Adobe 현상 엔진과 수치별 동일 픽셀을 보장하지 않는다. 성공 기준은 방향·역할 일치다.
- `colorGrading == .neutral`이면 encode에서 키를 생략한다. 키가 없을 때만 기본값을 쓰고 명시 null·잘못된 타입·범위 초과는 거부한다.
- 곡선·HSL·그레이딩이 모두 중립이면 큐브를 건너뛰어 기존 픽셀을 그대로 유지한다.
- 계수: 명도 `0.5 * L * (1 - L)`, 색 `0.3`, 경계 `e = 0.05 + 0.45 * blending`, 밝기 가중치 `0.2126/0.7152/0.0722`.
- 부분 보정(마스크)에는 그레이딩을 추가하지 않는다.
- 작업 트리에 다른 미커밋 diff가 있다(같은 파일 포함). 기존 변경을 되돌리거나 정리하지 않는다. **커밋은 사용자가 허락한 경우에만** 하며, 허락받으면 이 계획의 변경만 `git add -p`로 골라 담는다. 각 작업의 체크포인트는 `git diff --check`다.
- 테스트용 카탈로그는 `TestSupport.startedModel`의 임시 경로만 쓴다. 실제 앱은 고유 임시 `LIGHTHOUSE_DATA_DIR`로 실행하고, 확인 후 직접 띄운 PID만 종료한다.
- `rtk`가 이 환경에 없으므로 원래 명령을 쓴다.

## Review Focus

1. **완전 중립인데 혼합·균형만 바뀐 사진**: 렌더는 이전과 픽셀이 같고 값은 저장돼야 한다 → Task 1(저장), Task 2(`testNeutralGradingIsIdentityAndSkipsCube`).
2. **바퀴 가장자리 계산 오차로 색조 360이 생기는 경우**: 저장·검증 실패 없이 0으로 처리돼야 한다 → Task 4(`testWheelGeometryMapsAnglesAndClampsDistance`의 `-1e-13` 각도 사례).
3. **흑백 프로필과 분할 톤 조합**: 흑백 사진에도 틴트가 보이고 미리보기와 내보내기가 같아야 한다 → Task 2(`testMonochromeToningMatchesPreviewAndExport`).
4. **옛 분할 톤 프리셋(혼합 키 없음) 부분 적용**: 사진의 기존 혼합·다른 영역 값이 유지돼야 한다 → Task 3(`testPartialColorGradingPreservesUnspecifiedValues`).
5. **순수 검정·흰색 근처의 강한 틴트**: 클리핑으로 밝기가 튀지 않고 검정·흰색이 그대로 남아야 한다 → Task 2(`testTintPreservesLuminanceAndPureBlackWhite`).

---

### Task 1: 컬러 그레이딩 모델과 저장

**Files:**
- Modify: `Sources/LighthouseCore/AdvancedEditModels.swift` (`GrainSettings` 뒤에 새 타입 추가)
- Modify: `Sources/LighthouseCore/PhotoModels.swift` (`EditSettings` 필드·init·CodingKeys·decode·encode)
- Modify: `Sources/LighthouseCore/BatchEditing.swift:33-35`
- Modify: `Sources/LighthouseCore/EditSnapshots.swift:34`
- Create: `Tests/LighthouseCoreTests/ColorGradingTests.swift`

**Interfaces:**
- Produces:
  - `public struct ColorGradeZone: Codable, Equatable, Sendable { hue: Double; saturation: Double; luminance: Double; init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0); var isNeutral: Bool; var isValid: Bool }`
  - `public struct ColorGrading: Codable, Equatable, Sendable { shadows, midtones, highlights, global: ColorGradeZone; blending: Double; balance: Double; init(shadows:midtones:highlights:global:blending: = 0.5, balance: = 0); static let neutral; var isNeutral: Bool; var isValid: Bool }`
  - `public enum ColorGradeRegion: String, CaseIterable, Sendable { case shadows, midtones, highlights, global; var keyPath: WritableKeyPath<ColorGrading, ColorGradeZone> }`
  - `EditSettings.colorGrading: ColorGrading`, init 마지막 인자 `colorGrading: ColorGrading = .neutral`

- [ ] **Step 1: 실패하는 모델 테스트 작성**

`Tests/LighthouseCoreTests/ColorGradingTests.swift`:

```swift
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LighthouseCore

final class ColorGradingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let sample = ColorGrading(
        shadows: ColorGradeZone(hue: 220, saturation: 0.4, luminance: -0.2),
        global: ColorGradeZone(hue: 30, saturation: 0.1),
        blending: 0.7, balance: -0.3
    )

    // MARK: 모델·저장

    func testColorGradingDefaultsOmitKeyRoundTripsAndRejectsInvalidValues() throws {
        var object = try jsonObject(EditSettings())
        XCTAssertNil(object["colorGrading"], "중립이면 키를 쓰지 않는다")
        XCTAssertEqual(try decode(object).colorGrading, .neutral)

        let edits = EditSettings(colorGrading: sample)
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edits)), edits)
        XCTAssertTrue(edits.isModified)

        let blendOnly = EditSettings(colorGrading: ColorGrading(blending: 0.8))
        XCTAssertTrue(blendOnly.colorGrading.isNeutral, "혼합만으로는 효과가 없다")
        XCTAssertNotNil(try jsonObject(blendOnly)["colorGrading"], "그래도 값은 저장한다")
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(blendOnly)), blendOnly)

        object["colorGrading"] = ["shadows": ["hue": 200]]
        let partial = try decode(object).colorGrading
        XCTAssertEqual(partial.shadows, ColorGradeZone(hue: 200))
        XCTAssertEqual(partial.midtones, ColorGradeZone())
        XCTAssertEqual(partial.blending, 0.5)
        XCTAssertEqual(partial.balance, 0)

        let invalid: [Any] = [
            NSNull(), "warm", ["blending": 1.5], ["balance": NSNull()], ["balance": -1.01],
            ["shadows": ["hue": 360]], ["shadows": ["hue": -1]], ["shadows": ["saturation": -0.1]],
            ["global": ["luminance": 2]], ["midtones": NSNull()], ["highlights": ["hue": "red"]],
        ]
        for value in invalid {
            object["colorGrading"] = value
            XCTAssertThrowsError(try decode(object), "\(value)")
        }
    }

    func testLegacyCatalogJSONReencodesIdentically() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let legacy = try encoder.encode(EditSettings(exposure: 0.3, contrast: 1.2))
        let reencoded = try encoder.encode(JSONDecoder().decode(EditSettings.self, from: legacy))
        XCTAssertEqual(reencoded, legacy, "기존 카탈로그와 썸네일 키가 바뀌지 않는다")
    }

    func testGlobalMergeCopiesGradingAndChangeSummaryNamesIt() {
        let source = EditSettings(colorGrading: sample)
        XCTAssertEqual(EditSettings().merging(from: source, components: .global).colorGrading, sample)
        XCTAssertEqual(EditSettings().merging(from: source, components: .geometry).colorGrading, .neutral)
        XCTAssertEqual(source.changeSummary(from: EditSettings()), "컬러 그레이딩")
    }

    func testRegionKeyPathsAddressEachZone() {
        var grading = ColorGrading.neutral
        for (index, region) in ColorGradeRegion.allCases.enumerated() {
            grading[keyPath: region.keyPath].hue = Double(index * 10 + 10)
        }
        XCTAssertEqual([grading.shadows.hue, grading.midtones.hue, grading.highlights.hue, grading.global.hue],
                       [10, 20, 30, 40])
    }

    // MARK: 도우미

    private func jsonObject(_ edits: EditSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edits)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> EditSettings {
        try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter ColorGradingTests`
Expected: 컴파일 실패 — `cannot find 'ColorGrading' in scope`

- [ ] **Step 3: 모델 구현**

`Sources/LighthouseCore/AdvancedEditModels.swift`에서 `GrainSettings` 정의가 끝난 바로 뒤에 추가:

```swift
/// 컬러 그레이딩의 한 영역. 색조는 0..<360도, 채도 0…1, 명도 -1…1.
public struct ColorGradeZone: Codable, Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isNeutral: Bool { saturation == 0 && luminance == 0 }

    public var isValid: Bool {
        hue.isFinite && hue >= 0 && hue < 360
            && saturation.isFinite && (0...1).contains(saturation)
            && luminance.isFinite && (-1...1).contains(luminance)
    }

    private enum CodingKeys: String, CodingKey {
        case hue, saturation, luminance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hue = try container.contains(.hue) ? container.decode(Double.self, forKey: .hue) : 0
        saturation = try container.contains(.saturation) ? container.decode(Double.self, forKey: .saturation) : 0
        luminance = try container.contains(.luminance) ? container.decode(Double.self, forKey: .luminance) : 0
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Color grade zone must be finite and within its supported ranges"
            ))
        }
    }
}

/// 그림자·중간톤·하이라이트·전체 영역의 색과 명도. 혼합은 영역 경계의 부드러움(0…1), 균형은 그림자·하이라이트 경계 이동(-1…1)이다.
public struct ColorGrading: Codable, Equatable, Sendable {
    public var shadows: ColorGradeZone
    public var midtones: ColorGradeZone
    public var highlights: ColorGradeZone
    public var global: ColorGradeZone
    public var blending: Double
    public var balance: Double

    public init(shadows: ColorGradeZone = ColorGradeZone(), midtones: ColorGradeZone = ColorGradeZone(),
                highlights: ColorGradeZone = ColorGradeZone(), global: ColorGradeZone = ColorGradeZone(),
                blending: Double = 0.5, balance: Double = 0) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.global = global
        self.blending = blending
        self.balance = balance
    }

    public static let neutral = ColorGrading()

    /// 네 영역 모두 채도·명도가 0이면 혼합·균형과 관계없이 효과가 없다.
    public var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral
    }

    public var isValid: Bool {
        [shadows, midtones, highlights, global].allSatisfy(\.isValid)
            && blending.isFinite && (0...1).contains(blending)
            && balance.isFinite && (-1...1).contains(balance)
    }

    private enum CodingKeys: String, CodingKey {
        case shadows, midtones, highlights, global, blending, balance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func zone(_ key: CodingKeys) throws -> ColorGradeZone {
            try container.contains(key) ? container.decode(ColorGradeZone.self, forKey: key) : ColorGradeZone()
        }
        shadows = try zone(.shadows)
        midtones = try zone(.midtones)
        highlights = try zone(.highlights)
        global = try zone(.global)
        blending = try container.contains(.blending) ? container.decode(Double.self, forKey: .blending) : 0.5
        balance = try container.contains(.balance) ? container.decode(Double.self, forKey: .balance) : 0
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Color grading must be finite and within its supported ranges"
            ))
        }
    }
}

public enum ColorGradeRegion: String, CaseIterable, Sendable {
    case shadows, midtones, highlights, global

    public var keyPath: WritableKeyPath<ColorGrading, ColorGradeZone> {
        switch self {
        case .shadows: \.shadows
        case .midtones: \.midtones
        case .highlights: \.highlights
        case .global: \.global
        }
    }
}
```

`Sources/LighthouseCore/PhotoModels.swift`의 `EditSettings`:

1. `public var hdrAmount: Double` 다음 줄에 추가:
```swift
    /// 그림자·중간톤·하이라이트·전체 컬러 그레이딩. 중립이면 저장하지 않는다.
    public var colorGrading: ColorGrading
```
2. init 시그니처 마지막 `hdrAmount: Double = 0) {`를 `hdrAmount: Double = 0, colorGrading: ColorGrading = .neutral) {`로 바꾸고 본문 끝 `self.hdrAmount = hdrAmount` 뒤에 `self.colorGrading = colorGrading` 추가.
3. CodingKeys 마지막 줄을 `case vibrance, clarity, vignette, hdrAmount, colorGrading`으로.
4. `init(from:)` 끝 `hdrAmount = ...` 다음 줄:
```swift
        colorGrading = try container.contains(.colorGrading)
            ? container.decode(ColorGrading.self, forKey: .colorGrading) : .neutral
```
5. `encode(to:)` 끝 `if hdrAmount != 0 { ... }` 다음 줄:
```swift
        if colorGrading != .neutral { try container.encode(colorGrading, forKey: .colorGrading) }
```

`Sources/LighthouseCore/BatchEditing.swift`의 `result.colorRanges = source.colorRanges` 다음 줄:
```swift
            result.colorGrading = source.colorGrading
```

`Sources/LighthouseCore/EditSnapshots.swift`의 `("HSL", colorRanges != before.colorRanges),` 다음 줄:
```swift
            ("컬러 그레이딩", colorGrading != before.colorGrading),
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter ColorGradingTests`
Expected: 4 tests PASS

Run: `swift test --filter LightroomToneTests` (기존 저장 회귀)
Expected: PASS

- [ ] **Step 5: 체크포인트**

Run: `git diff --check -- Sources/LighthouseCore Tests/LighthouseCoreTests/ColorGradingTests.swift`
Expected: 출력 없음. 커밋은 하지 않는다(Global Constraints).

---

### Task 2: 큐브 렌더에 그레이딩 수식 적용

**Files:**
- Modify: `Sources/LighthouseCore/ColorProcessing.swift` (오류 case, `transformRGB`, `applyColor`, `validate`, `isNeutral`, `makeCubeData`, `transformValidated`, 새 `applyingGrading`, `ColorCubeCache`)
- Modify: `Sources/LighthouseCore/ImagePipeline.swift:364-365`
- Test: `Tests/LighthouseCoreTests/ColorGradingTests.swift`

**Interfaces:**
- Consumes: Task 1의 `ColorGrading`, `ColorGradeZone.isValid`, `ColorGrading.isNeutral/isValid`
- Produces:
  - `AdvancedColorProcessor.transformRGB(_ rgb: SIMD3<Double>, curves: ToneCurves, ranges: [ColorRangeAdjustment], grading: ColorGrading = .neutral) throws -> SIMD3<Double>`
  - `AdvancedColorProcessor.applyColor(to: CIImage, curves: ToneCurves, ranges: [ColorRangeAdjustment], grading: ColorGrading = .neutral) throws -> CIImage`
  - `AdvancedColorProcessingError.invalidColorGrading`

- [ ] **Step 1: 실패하는 렌더 테스트 작성**

`ColorGradingTests`의 `// MARK: 도우미` 위에 추가:

```swift
    // MARK: 렌더

    func testNeutralGradingIsIdentityAndSkipsCube() throws {
        let rgb = SIMD3(0.2, 0.5, 0.9)
        let quiet = ColorGrading(blending: 0.9, balance: 0.5)
        XCTAssertEqual(try AdvancedColorProcessor.transformRGB(rgb, curves: .identity, ranges: [], grading: quiet), rgb)
        let source = grayscaleRamp()
        XCTAssertIdentical(try AdvancedColorProcessor.applyColor(to: source, curves: .identity, ranges: [],
                                                                 grading: quiet), source)
    }

    func testZoneDirectionsAffectOnlyTheirTonalRange() throws {
        let shadows = ColorGrading(shadows: ColorGradeZone(hue: 220, saturation: 0.5))
        XCTAssertGreaterThan(try graded(0.1, shadows).z, try graded(0.1, shadows).x + 0.1)
        assertClose(try graded(0.9, shadows), SIMD3(repeating: 0.9), 0.001)

        let highlights = ColorGrading(highlights: ColorGradeZone(hue: 40, saturation: 0.5))
        XCTAssertGreaterThan(try graded(0.9, highlights).x, try graded(0.9, highlights).z + 0.1)
        assertClose(try graded(0.1, highlights), SIMD3(repeating: 0.1), 0.001)

        let midtones = ColorGrading(midtones: ColorGradeZone(hue: 120, saturation: 0.5))
        XCTAssertGreaterThan(try graded(0.5, midtones).y, try graded(0.5, midtones).x + 0.05)
        assertClose(try graded(0.02, midtones), SIMD3(repeating: 0.02), 0.001)
        assertClose(try graded(0.98, midtones), SIMD3(repeating: 0.98), 0.001)

        let global = ColorGrading(global: ColorGradeZone(hue: 0, saturation: 0.5))
        for gray in [0.1, 0.5, 0.9] {
            XCTAssertGreaterThan(try graded(gray, global).x, try graded(gray, global).z + 0.02, "\(gray)")
        }
    }

    func testTintPreservesLuminanceAndPureBlackWhite() throws {
        let strong = ColorGrading(
            shadows: ColorGradeZone(hue: 220, saturation: 1), midtones: ColorGradeZone(hue: 120, saturation: 1),
            highlights: ColorGradeZone(hue: 40, saturation: 1), global: ColorGradeZone(hue: 300, saturation: 1)
        )
        for gray in [0, 0.02, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0] {
            let output = try graded(gray, strong)
            XCTAssertEqual(luma(output), gray, accuracy: 1e-9, "\(gray)")
            XCTAssertTrue((0...1).contains(output.x) && (0...1).contains(output.y) && (0...1).contains(output.z))
        }
        XCTAssertEqual(try graded(0, strong), SIMD3(repeating: 0))
        XCTAssertEqual(try graded(1, strong), SIMD3(repeating: 1))
        let colored = SIMD3(0.8, 0.2, 0.1)
        let output = try AdvancedColorProcessor.transformRGB(colored, curves: .identity, ranges: [], grading: strong)
        XCTAssertEqual(luma(output), luma(colored), accuracy: 1e-9)
    }

    func testLuminanceDirectionsKeepEndpoints() throws {
        let darker = ColorGrading(shadows: ColorGradeZone(luminance: -1))
        let brighter = ColorGrading(shadows: ColorGradeZone(luminance: 1))
        XCTAssertLessThan(luma(try graded(0.1, darker)), 0.1)
        XCTAssertGreaterThan(luma(try graded(0.1, brighter)), 0.1)
        let midLift = ColorGrading(midtones: ColorGradeZone(luminance: 1))
        XCTAssertGreaterThan(luma(try graded(0.5, midLift)), 0.55)
        for grading in [darker, brighter, midLift] {
            XCTAssertEqual(try graded(0, grading), SIMD3(repeating: 0))
            XCTAssertEqual(try graded(1, grading), SIMD3(repeating: 1))
        }
    }

    func testBalanceAndBlendingMoveZoneBoundaries() throws {
        func shadowTint(_ gray: Double, blending: Double = 0.5, balance: Double = 0) throws -> Double {
            let output = try graded(gray, ColorGrading(shadows: ColorGradeZone(hue: 220, saturation: 0.5),
                                                       blending: blending, balance: balance))
            return output.z - output.x
        }
        let neutralBalance = try shadowTint(0.3)
        XCTAssertLessThan(try shadowTint(0.3, balance: 1), neutralBalance, "균형 +는 하이라이트 쪽을 넓힌다")
        XCTAssertGreaterThan(try shadowTint(0.3, balance: -1), neutralBalance, "균형 -는 그림자 쪽을 넓힌다")

        let hard = try shadowTint(0.5, blending: 0)
        let medium = try shadowTint(0.5, blending: 0.5)
        let soft = try shadowTint(0.5, blending: 1)
        XCTAssertEqual(hard, 0, accuracy: 1e-9, "혼합 0이면 중간 밝기에 그림자 색이 번지지 않는다")
        XCTAssertGreaterThan(medium, hard)
        XCTAssertGreaterThan(soft, medium)
    }

    func testInvalidGradingThrows() {
        let invalid = [
            ColorGrading(shadows: ColorGradeZone(hue: 360)),
            ColorGrading(global: ColorGradeZone(saturation: 1.2)),
            ColorGrading(midtones: ColorGradeZone(luminance: .nan)),
            ColorGrading(blending: -0.1),
            ColorGrading(balance: .infinity),
        ]
        for grading in invalid {
            XCTAssertThrowsError(try AdvancedColorProcessor.transformRGB(
                SIMD3(repeating: 0.5), curves: .identity, ranges: [], grading: grading
            )) { XCTAssertEqual($0 as? AdvancedColorProcessingError, .invalidColorGrading) }
            XCTAssertThrowsError(try AdvancedColorProcessor.applyColor(
                to: grayscaleRamp(), curves: .identity, ranges: [], grading: grading
            ))
        }
    }

    func testCubeMatchesPerPixelTransform() throws {
        let grading = ColorGrading(shadows: ColorGradeZone(hue: 220, saturation: 0.6, luminance: -0.3),
                                   highlights: ColorGradeZone(hue: 40, saturation: 0.5, luminance: 0.2))
        let bytes = try rgba8(AdvancedColorProcessor.applyColor(to: grayscaleRamp(), curves: .identity,
                                                                ranges: [], grading: grading))
        for (index, gray) in [0, 64, 128, 192, 255].enumerated() {
            let expected = try graded(Double(gray) / 255, grading) * 255
            XCTAssertEqual(Double(bytes[index * 4]), expected.x, accuracy: 2, "\(gray) R")
            XCTAssertEqual(Double(bytes[index * 4 + 1]), expected.y, accuracy: 2, "\(gray) G")
            XCTAssertEqual(Double(bytes[index * 4 + 2]), expected.z, accuracy: 2, "\(gray) B")
        }
    }

    func testMonochromeToningMatchesPreviewAndExport() throws {
        let url = try temporaryPNG()
        let edits = EditSettings(colorProfile: .monochrome, colorGrading: ColorGrading(
            shadows: ColorGradeZone(hue: 220, saturation: 1), highlights: ColorGradeZone(hue: 40, saturation: 0.5)
        ))
        let preview = try ImagePipeline(cachesDevelopment: true).renderPreview(url: url, edits: edits, maxPixel: nil,
                                                                               allowApproximation: true)
        let exact = try ImagePipeline().render(url: url, edits: edits, maxPixel: nil)
        XCTAssertFalse(preview.isApproximate)
        XCTAssertEqual(try rgba8(preview.image), try rgba8(exact))
        let bytes = try rgba8(exact)
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            XCTAssertGreaterThan(Int(bytes[pixel + 2]), Int(bytes[pixel]) + 5, "흑백 위에 그림자 파랑이 보인다")
        }
    }
```

`// MARK: 도우미` 아래(기존 두 함수 뒤)에 추가:

```swift
    private func graded(_ gray: Double, _ grading: ColorGrading) throws -> SIMD3<Double> {
        try AdvancedColorProcessor.transformRGB(SIMD3(repeating: gray), curves: .identity, ranges: [],
                                                grading: grading)
    }

    private func luma(_ rgb: SIMD3<Double>) -> Double {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    private func assertClose(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>, _ accuracy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    private func grayscaleRamp() -> CIImage {
        let data = Data([0, 0, 0, 255, 64, 64, 64, 255, 128, 128, 128, 255,
                         192, 192, 192, 255, 255, 255, 255, 255])
        return CIImage(bitmapData: data, bytesPerRow: 20, size: CGSize(width: 5, height: 1),
                       format: .RGBA8, colorSpace: colorSpace)
    }

    private func rgba8(_ image: CIImage) throws -> Data {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                           bounds: image.extent, format: .RGBA8, colorSpace: colorSpace)
        }
        return data
    }

    private func rgba8(_ image: CGImage) throws -> Data {
        try rgba8(CIImage(cgImage: image))
    }

    private func temporaryPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let bytes = Data([255, 32, 16, 255, 16, 128, 240, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: 8, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter ColorGradingTests`
Expected: 컴파일 실패 — `extra argument 'grading' in call`

- [ ] **Step 3: ColorProcessing 구현**

`AdvancedColorProcessingError`에 case와 메시지 추가:
```swift
    case invalidColorGrading
```
```swift
        case .invalidColorGrading:
            "컬러 그레이딩 조절값이 허용 범위를 벗어났습니다."
```

`transformRGB`와 `applyColor`를 다음으로 교체:
```swift
    public static func transformRGB(_ rgb: SIMD3<Double>, curves: ToneCurves,
                                    ranges: [ColorRangeAdjustment],
                                    grading: ColorGrading = .neutral) throws -> SIMD3<Double> {
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else {
            throw AdvancedColorProcessingError.invalidRGB
        }
        try validate(curves: curves, ranges: ranges, grading: grading)
        if isNeutral(curves: curves, ranges: ranges, grading: grading) { return rgb }
        return transformValidated(rgb, curves: curves, ranges: ranges, grading: grading)
    }

    public static func applyColor(to image: CIImage, curves: ToneCurves,
                                  ranges: [ColorRangeAdjustment],
                                  grading: ColorGrading = .neutral) throws -> CIImage {
        try validate(curves: curves, ranges: ranges, grading: grading)
        if isNeutral(curves: curves, ranges: ranges, grading: grading) { return image }

        let cubeData = cubeCache.data(curves: curves, ranges: ranges, grading: grading) {
            makeCubeData(curves: curves, ranges: ranges, grading: grading)
        }
        guard let encoded = image.matchedFromWorkingSpace(to: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        let filter = CIFilter.colorCube()
        filter.inputImage = encoded
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = cubeData
        guard let changed = filter.outputImage else {
            throw AdvancedColorProcessingError.colorFilterFailed
        }
        guard let restored = changed.matchedToWorkingSpace(from: sRGB) else {
            throw AdvancedColorProcessingError.colorSpaceConversionFailed
        }
        return restored.cropped(to: image.extent)
    }
```

`validate(curves:ranges:)`의 시그니처를 `validate(curves: ToneCurves, ranges: [ColorRangeAdjustment], grading: ColorGrading)`로 바꾸고, 함수 끝(`for` 루프 뒤)에:
```swift
        guard grading.isValid else { throw AdvancedColorProcessingError.invalidColorGrading }
```

`isNeutral`을 교체:
```swift
    private static func isNeutral(curves: ToneCurves, ranges: [ColorRangeAdjustment],
                                  grading: ColorGrading) -> Bool {
        curves.isIdentity && grading.isNeutral && ranges.allSatisfy {
            $0.hue == 0 && $0.saturation == 0 && $0.lightness == 0
        }
    }
```

`makeCubeData` 시그니처에 `grading: ColorGrading`을 더하고, 안쪽 계산 줄을 교체:
```swift
    private static func makeCubeData(curves: ToneCurves, ranges: [ColorRangeAdjustment],
                                     grading: ColorGrading) -> Data {
```
```swift
                        let transformed = applyingGrading(grading, to: applyingRanges(
                            ranges, to: SIMD3(tables[0][red], tables[1][green], tables[2][blue])
                        ))
```

`transformValidated`를 교체:
```swift
    private static func transformValidated(_ rgb: SIMD3<Double>, curves: ToneCurves,
                                           ranges: [ColorRangeAdjustment],
                                           grading: ColorGrading) -> SIMD3<Double> {
        let master = Curve(curves.master)
        let curved = SIMD3(
            Curve(curves.red).value(at: master.value(at: min(1, max(0, rgb.x)))),
            Curve(curves.green).value(at: master.value(at: min(1, max(0, rgb.y)))),
            Curve(curves.blue).value(at: master.value(at: min(1, max(0, rgb.z))))
        )
        return applyingGrading(grading, to: applyingRanges(ranges, to: curved))
    }
```

`applyingRanges` 정의 바로 뒤에 추가:
```swift
    /// 밝기로 영역 가중치를 정한 뒤 명도는 세 채널에 같이 더하고, 밝기 0인 색 방향은 0…1을 벗어나지 않는 만큼만 더한다.
    /// 그래서 틴트는 밝기를 바꾸지 않고 순수한 검정·흰색은 그대로 남는다.
    private static func applyingGrading(_ grading: ColorGrading, to rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard !grading.isNeutral else { return rgb }
        let luma = min(1, max(0, luminance(rgb)))
        let position = pow(luma, pow(2, -grading.balance))
        let edge = 0.05 + 0.45 * grading.blending
        let shadows = 1 - smoothstep(max(0, 1.0 / 3 - edge), 1.0 / 3 + edge, position)
        let highlights = smoothstep(2.0 / 3 - edge, min(1, 2.0 / 3 + edge), position)
        let midtones = max(0, 1 - shadows - highlights)
        let weighted = [(grading.shadows, shadows), (grading.midtones, midtones),
                        (grading.highlights, highlights), (grading.global, 1.0)]
        var lift = 0.0
        var tint = SIMD3<Double>(repeating: 0)
        for (zone, weight) in weighted where weight > 0 {
            lift += weight * zone.luminance * 0.5 * luma * (1 - luma)
            guard zone.saturation > 0 else { continue }
            let color = hslToRGB(HSL(hue: zone.hue, saturation: 1, lightness: 0.5))
            tint += weight * zone.saturation * 0.3 * (color - SIMD3(repeating: luminance(color)))
        }
        let base = (rgb + SIMD3(repeating: lift)).clamped(lowerBound: SIMD3(repeating: 0),
                                                           upperBound: SIMD3(repeating: 1))
        var scale = 1.0
        for channel in 0..<3 where tint[channel] != 0 {
            let room = tint[channel] < 0 ? base[channel] / -tint[channel] : (1 - base[channel]) / tint[channel]
            scale = min(scale, room)
        }
        return base + max(0, scale) * tint
    }

    private static func luminance(_ rgb: SIMD3<Double>) -> Double {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value < edge1 ? 0 : 1 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
```

`ColorCubeCache`의 `Entry`에 `let grading: ColorGrading`를 더하고 `data`를 교체:
```swift
    func data(curves: ToneCurves, ranges: [ColorRangeAdjustment], grading: ColorGrading,
              create: () -> Data) -> Data {
        func matches(_ entry: Entry) -> Bool {
            entry.curves == curves && entry.ranges == ranges && entry.grading == grading
        }
        lock.lock()
        if let index = entries.firstIndex(where: matches) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.data
        }
        lock.unlock()

        let result = create()
        lock.lock()
        if let index = entries.firstIndex(where: matches) {
            let existing = entries.remove(at: index)
            entries.append(existing)
            lock.unlock()
            return existing.data
        }
        entries.append(Entry(curves: curves, ranges: ranges, grading: grading, data: result))
        if entries.count > 4 { entries.removeFirst(entries.count - 4) }
        lock.unlock()
        return result
    }
```

- [ ] **Step 4: 파이프라인 연결**

`Sources/LighthouseCore/ImagePipeline.swift` `composed(...)`:
```swift
        image = try AdvancedColorProcessor.applyColor(to: image, curves: edits.curves,
                                                      ranges: edits.colorRanges, grading: edits.colorGrading)
```

- [ ] **Step 5: 통과 확인**

Run: `swift test --filter ColorGradingTests`
Expected: 12 tests PASS

Run: `swift test --filter "AdvancedColorTests|LightroomToneTests"` (기존 큐브·톤 회귀)
Expected: PASS

- [ ] **Step 6: 체크포인트**

Run: `git diff --check -- Sources/LighthouseCore Tests/LighthouseCoreTests/ColorGradingTests.swift`
Expected: 출력 없음

---

### Task 3: Lightroom 프리셋 키 14개 가져오기

**Files:**
- Modify: `Sources/LighthouseCore/LightroomPresetPayload.swift` (`applying(to:)`, `scalarRanges`, 새 static 키 목록)
- Modify: `Sources/LighthouseCore/LightroomPresetImporter.swift` (`makePreset`의 근사 경고)
- Test: `Tests/LighthouseCoreTests/ColorGradingTests.swift`

**Interfaces:**
- Consumes: Task 1 `ColorGradeRegion.keyPath`, `EditSettings.colorGrading`
- Produces: `LightroomPresetPayload.colorGradingKeys: Set<String>`(internal), 경고 문자열 `"컬러 그레이딩은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다."`

- [ ] **Step 1: 실패하는 가져오기 테스트 작성**

`ColorGradingTests`의 `// MARK: 도우미` 위에 추가:

```swift
    // MARK: 프리셋 가져오기

    private let gradingWarning = "컬러 그레이딩은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다."

    func testImportsAllFourteenKeysFromXMPAttributes() throws {
        let preset = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Grade" crs:SplitToningShadowHue="220" crs:SplitToningShadowSaturation="40"
          crs:SplitToningHighlightHue="360" crs:SplitToningHighlightSaturation="25" crs:SplitToningBalance="-30"
          crs:ColorGradeMidtoneHue="120" crs:ColorGradeMidtoneSat="10" crs:ColorGradeShadowLum="-20"
          crs:ColorGradeMidtoneLum="5" crs:ColorGradeHighlightLum="15" crs:ColorGradeGlobalHue="30"
          crs:ColorGradeGlobalSat="8" crs:ColorGradeGlobalLum="-4" crs:ColorGradeBlending="70"/>
        """), fileName: "grade.xmp")
        let expected = ColorGrading(
            shadows: ColorGradeZone(hue: 220, saturation: 0.4, luminance: -0.2),
            midtones: ColorGradeZone(hue: 120, saturation: 0.1, luminance: 0.05),
            highlights: ColorGradeZone(hue: 0, saturation: 0.25, luminance: 0.15),
            global: ColorGradeZone(hue: 30, saturation: 0.08, luminance: -0.04),
            blending: 0.7, balance: -0.3
        )
        XCTAssertEqual(preset.applied(to: EditSettings()).colorGrading, expected)
        let payload = try XCTUnwrap(preset.lightroom)
        XCTAssertEqual(payload.scalars.count, 14)
        XCTAssertFalse(payload.warnings.contains { $0.contains("제외: SplitToning") || $0.contains("제외: ColorGrade") })
        XCTAssertTrue(payload.warnings.contains(gradingWarning))
    }

    func testImportsColorGradingFromXMPElementsAndLRTemplate() throws {
        let elements = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Grade Elements">
          <crs:SplitToningShadowHue>200</crs:SplitToningShadowHue>
          <crs:ColorGradeBlending>80</crs:ColorGradeBlending>
        </rdf:Description>
        """), fileName: "elements.xmp")
        let fromElements = elements.applied(to: EditSettings()).colorGrading
        XCTAssertEqual(fromElements.shadows.hue, 200)
        XCTAssertEqual(fromElements.blending, 0.8)

        let template = try LightroomPresetImporter.parse(data: Data("""
        s = { title = "Grade Template", type = "Develop", value = { settings = {
          SplitToningHighlightHue = 40, SplitToningHighlightSaturation = 30, ColorGradeGlobalLum = 10,
        } } }
        """.utf8), fileName: "grade.lrtemplate")
        let fromTemplate = template.applied(to: EditSettings()).colorGrading
        XCTAssertEqual(fromTemplate.highlights, ColorGradeZone(hue: 40, saturation: 0.3))
        XCTAssertEqual(fromTemplate.global.luminance, 0.1)
        XCTAssertTrue(try XCTUnwrap(template.lightroom).warnings.contains(gradingWarning))
    }

    func testColorGradingImportRejectsInvalidValuesAndKeepsUnknownKeysExcluded() throws {
        let invalid = [
            #"<rdf:Description crs:SplitToningShadowHue="361"/>"#,
            #"<rdf:Description crs:ColorGradeBlending="abc"/>"#,
            #"<rdf:Description crs:ColorGradeShadowLum="-101"/>"#,
            #"<rdf:Description crs:ColorGradeBlending="40"><crs:ColorGradeBlending>60</crs:ColorGradeBlending></rdf:Description>"#,
        ]
        for description in invalid {
            XCTAssertThrowsError(try LightroomPresetImporter.parse(data: xmp(description), fileName: "bad.xmp"),
                                 description)
        }
        let unknown = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:ColorGradeShadowHue="10" crs:Exposure2012="0.5"/>
        """), fileName: "unknown.xmp")
        let warnings = try XCTUnwrap(unknown.lightroom).warnings
        XCTAssertTrue(warnings.contains("지원하지 않아 제외: ColorGradeShadowHue"))
        XCTAssertFalse(warnings.contains(gradingWarning), "지원 키가 없으면 근사 경고를 붙이지 않는다")
    }

    func testPartialColorGradingPreservesUnspecifiedValues() {
        let target = EditSettings(colorGrading: ColorGrading(
            shadows: ColorGradeZone(hue: 10, saturation: 0.3, luminance: 0.1),
            highlights: ColorGradeZone(hue: 50, saturation: 0.2), blending: 0.8, balance: 0.2
        ))
        let hueOnly = EditPreset(name: "Hue", lightroom: LightroomPresetPayload(
            format: "xmp", scalars: ["SplitToningShadowHue": 200], curves: [:], warnings: []
        ))
        var expected = target.colorGrading
        expected.shadows.hue = 200
        XCTAssertEqual(hueOnly.applied(to: target).colorGrading, expected)

        let zeroBlend = EditPreset(name: "Zero", lightroom: LightroomPresetPayload(
            format: "xmp", scalars: ["ColorGradeBlending": 0], curves: [:], warnings: []
        ))
        XCTAssertEqual(zeroBlend.applied(to: target).colorGrading.blending, 0, "명시한 0은 적용한다")
    }

    func testNeutralSlowFilmStyleKeysLeaveGradingNeutral() throws {
        let preset = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Slow Neutral" crs:SplitToningShadowHue="0" crs:SplitToningShadowSaturation="0"
          crs:SplitToningHighlightHue="0" crs:SplitToningHighlightSaturation="0" crs:SplitToningBalance="0"
          crs:ColorGradeMidtoneHue="0" crs:ColorGradeMidtoneSat="0" crs:ColorGradeShadowLum="0"
          crs:ColorGradeMidtoneLum="0" crs:ColorGradeHighlightLum="0" crs:ColorGradeBlending="50"
          crs:ColorGradeGlobalHue="0" crs:ColorGradeGlobalSat="0" crs:ColorGradeGlobalLum="0"/>
        """), fileName: "slow.xmp")
        XCTAssertEqual(preset.applied(to: EditSettings()).colorGrading, .neutral)
    }
```

`// MARK: 도우미` 아래에 추가:
```swift
    private func xmp(_ descriptions: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            \(descriptions)
          </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter ColorGradingTests`
Expected: 새 테스트 5개 FAIL(예: `XCTAssertEqual failed: ... ColorGrading(...neutral...)`, 14개 키가 제외 경고로 남음). 기존 12개는 PASS.

- [ ] **Step 3: payload 구현**

`LightroomPresetPayload`의 `static let curveChannels` 앞에 추가:
```swift
    /// Lightroom은 그림자·하이라이트 색과 균형을 옛 분할 톤 키에, 나머지를 ColorGrade 키에 저장한다.
    static let colorGradeZoneKeys: [(region: ColorGradeRegion, hue: String, saturation: String, luminance: String)] = [
        (.shadows, "SplitToningShadowHue", "SplitToningShadowSaturation", "ColorGradeShadowLum"),
        (.midtones, "ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum"),
        (.highlights, "SplitToningHighlightHue", "SplitToningHighlightSaturation", "ColorGradeHighlightLum"),
        (.global, "ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum"),
    ]

    static let colorGradingKeys: Set<String> = Set(colorGradeZoneKeys.flatMap {
        [$0.hue, $0.saturation, $0.luminance]
    } + ["SplitToningBalance", "ColorGradeBlending"])
```

`scalarRanges` 클로저의 `return ranges` 앞에 추가:
```swift
        for entry in colorGradeZoneKeys {
            ranges[entry.hue] = 0...360
            ranges[entry.saturation] = 0...100
            ranges[entry.luminance] = -100...100
        }
        ranges["SplitToningBalance"] = -100...100
        ranges["ColorGradeBlending"] = 0...100
```

`applying(to:)`의 `if let colorProfile { ... }` 다음 줄에 추가:
```swift
        for entry in Self.colorGradeZoneKeys {
            let path = entry.region.keyPath
            if let value = scalars[entry.hue] {
                result.colorGrading[keyPath: path].hue = value.truncatingRemainder(dividingBy: 360)
            }
            if let value = scalars[entry.saturation] { result.colorGrading[keyPath: path].saturation = value / 100 }
            if let value = scalars[entry.luminance] { result.colorGrading[keyPath: path].luminance = value / 100 }
        }
        if let value = scalars["ColorGradeBlending"] { result.colorGrading.blending = value / 100 }
        if let value = scalars["SplitToningBalance"] { result.colorGrading.balance = value / 100 }
```

- [ ] **Step 4: importer 경고 추가**

`LightroomPresetImporter.makePreset`에서 `warnings.append("Adobe 현상 엔진과 결과가 다를 수 있습니다.")` 바로 앞에:
```swift
        if scalars.keys.contains(where: LightroomPresetPayload.colorGradingKeys.contains) {
            warnings.append("컬러 그레이딩은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다.")
        }
```
`isUnsupportedSetting`의 접두사 목록은 바꾸지 않는다. 지원 키는 `scalarRanges` 판정이 먼저 잡는다.

- [ ] **Step 5: 통과 확인**

Run: `swift test --filter "ColorGradingTests|LightroomPresetTests"`
Expected: ColorGradingTests 17개, LightroomPresetTests 전부 PASS

- [ ] **Step 6: 체크포인트**

Run: `git diff --check -- Sources/LighthouseCore Tests/LighthouseCoreTests/ColorGradingTests.swift`
Expected: 출력 없음

---

### Task 4: 컬러 그레이딩 UI

**Files:**
- Create: `Sources/Lighthouse/ColorGradingControls.swift`
- Modify: `Sources/Lighthouse/AdvancedColorControls.swift` ("이 색상 초기화" 버튼 뒤, 필름 입자 `Divider()` 앞)
- Create: `Tests/LighthouseTests/ColorGradingFlowTests.swift`

**Interfaces:**
- Consumes: `ColorGrading`, `ColorGradeZone`, `ColorGradeRegion.keyPath`, `LibraryModel.updateEdits(_:continuous:)`, `LibraryModel.endContinuousEdit()`, `SliderRow`
- Produces: `struct ColorGradingControls: View { init(edits: EditSettings) }`, `enum ColorWheelGeometry { static func value(at: CGPoint, size: CGFloat) -> (hue: Double, saturation: Double); static func point(hue: Double, saturation: Double, size: CGFloat) -> CGPoint }`, `ColorGradeRegion.title: String`(앱 확장)

- [ ] **Step 1: 실패하는 앱 테스트 작성**

`Tests/LighthouseTests/ColorGradingFlowTests.swift`:

```swift
import AppKit
import CryptoKit
import Foundation
@testable import Lighthouse
import LighthouseCore
import SwiftUI
import XCTest

@MainActor
final class ColorGradingFlowTests: XCTestCase {
    private var snapshotWindows: [NSWindow] = []

    func testWheelGeometryMapsAnglesAndClampsDistance() {
        func check(_ point: CGPoint, hue: Double, saturation: Double, line: UInt = #line) {
            let value = ColorWheelGeometry.value(at: point, size: 160)
            XCTAssertEqual(value.hue, hue, accuracy: 1e-9, line: line)
            XCTAssertEqual(value.saturation, saturation, accuracy: 1e-9, line: line)
        }
        check(CGPoint(x: 160, y: 80), hue: 0, saturation: 1)
        check(CGPoint(x: 80, y: 0), hue: 90, saturation: 1)
        check(CGPoint(x: 0, y: 80), hue: 180, saturation: 1)
        check(CGPoint(x: 80, y: 160), hue: 270, saturation: 1)
        check(CGPoint(x: 80, y: 80), hue: 0, saturation: 0)
        check(CGPoint(x: 240, y: 80), hue: 0, saturation: 1)
        let nearlyFull = ColorWheelGeometry.value(at: CGPoint(x: 160, y: 80 + 1e-13), size: 160)
        XCTAssertTrue((0..<360).contains(nearlyFull.hue), "계산 오차로 360이 나오지 않는다")

        let point = ColorWheelGeometry.point(hue: 220, saturation: 0.4, size: 160)
        let back = ColorWheelGeometry.value(at: point, size: 160)
        XCTAssertEqual(back.hue, 220, accuracy: 1e-9)
        XCTAssertEqual(back.saturation, 0.4, accuracy: 1e-9)
    }

    func testContinuousGradingEditIsOneUndoStepAndZoneResetRestoresDefaults() async throws {
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        let start = try XCTUnwrap(model.selection).edits
        for saturation in [0.1, 0.2, 0.3] {
            var next = try XCTUnwrap(model.selection).edits
            next.colorGrading.shadows = ColorGradeZone(hue: 220, saturation: saturation)
            model.updateEdits(next, continuous: true)
        }
        model.endContinuousEdit()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits.colorGrading.shadows.saturation, 0.3)
        model.undo()
        XCTAssertEqual(try XCTUnwrap(model.selection).edits, start, "드래그 한 번은 실행 취소 1단계다")
        model.redo()

        var reset = try XCTUnwrap(model.selection).edits
        reset.colorGrading[keyPath: ColorGradeRegion.shadows.keyPath] = ColorGradeZone()
        model.updateEdits(reset)
        XCTAssertEqual(try XCTUnwrap(model.selection).edits.colorGrading, .neutral)
    }

    func testColorGradingPresetAppliesToSelectionAsOneStepAndReloads() async throws {
        let (model, root, urls) = try await TestSupport.startedModel(self, photos: 2)
        let originalHashes = try urls.map(Self.sha256)
        let input = root.appendingPathComponent("grading-presets", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let xmp = input.appendingPathComponent("grade.xmp")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            <rdf:Description crs:Name="Teal Orange" crs:SplitToningShadowHue="200"
              crs:SplitToningShadowSaturation="35" crs:SplitToningHighlightHue="35"
              crs:SplitToningHighlightSaturation="30" crs:SplitToningBalance="10"/>
          </rdf:RDF>
        </x:xmpmeta>
        """.utf8).write(to: xmp)

        model.importLightroomPresets(from: [xmp])
        try await TestSupport.wait("color grading preset import") { !model.isPresetImporting }
        let preset = try XCTUnwrap(model.presets.first { $0.name == "Teal Orange" })

        model.selectAllVisible()
        let starting = EditSettings(exposure: 0.4, colorGrading: ColorGrading(
            midtones: ColorGradeZone(hue: 90, saturation: 0.2), blending: 0.8
        ))
        for photo in model.photos { model.updatePhoto(photo.id) { $0.edits = starting } }
        model.applyPreset(preset)
        XCTAssertTrue(model.photos.allSatisfy {
            $0.edits.colorGrading.shadows == ColorGradeZone(hue: 200, saturation: 0.35) &&
            $0.edits.colorGrading.highlights == ColorGradeZone(hue: 35, saturation: 0.3) &&
            $0.edits.colorGrading.balance == 0.1 &&
            $0.edits.colorGrading.midtones == starting.colorGrading.midtones &&
            $0.edits.colorGrading.blending == 0.8 && $0.edits.exposure == 0.4
        }, "프리셋에 없는 영역·혼합은 유지한다")
        model.undo()
        XCTAssertTrue(model.photos.allSatisfy { $0.edits == starting }, "다중 적용을 한 번에 실행 취소한다")
        model.redo()

        try model.flushSave()
        let reloaded = LibraryModel()
        reloaded.start()
        try await TestSupport.wait("color grading catalog reload") { reloaded.catalogLoaded && reloaded.foldersLoaded }
        XCTAssertEqual(reloaded.photos.map(\.edits), model.photos.map(\.edits))
        XCTAssertEqual(reloaded.presets, model.presets)
        XCTAssertEqual(try urls.map(Self.sha256), originalHashes, "원본 bytes를 바꾸지 않는다")
    }

    func testRenderColorGradingControlsWhenSnapshotDirectoryIsProvided() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LIGHTHOUSE_SNAPSHOT_DIR"] else {
            throw XCTSkip("LIGHTHOUSE_SNAPSHOT_DIR를 주면 컬러 그레이딩 화면을 PNG로 그린다.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let (model, _, _) = try await TestSupport.startedModel(self, photos: 1)
        var edits = try XCTUnwrap(model.selection).edits
        edits.colorGrading = ColorGrading(shadows: ColorGradeZone(hue: 200, saturation: 0.35, luminance: -0.1),
                                          highlights: ColorGradeZone(hue: 35, saturation: 0.3),
                                          blending: 0.6, balance: 0.1)
        model.updateEdits(edits)
        try await renderSnapshot(ColorGradingControls(edits: edits)
            .padding(12)
            .background(Color(red: 0.145, green: 0.152, blue: 0.164)), model: model,
                                 size: CGSize(width: 300, height: 520), name: "color-grading-300", directory: directory)
        try await renderSnapshot(InspectorView(photo: try XCTUnwrap(model.selection)), model: model,
                                 size: CGSize(width: 300, height: 2600), name: "color-grading-inspector-300",
                                 directory: directory)
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func renderSnapshot<V: View>(_ view: V, model: LibraryModel, size: CGSize,
                                         name: String, directory: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AnyView(view.environmentObject(model).preferredColorScheme(.dark)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        snapshotWindows.append(window)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter ColorGradingFlowTests`
Expected: 컴파일 실패 — `cannot find 'ColorWheelGeometry' in scope`

- [ ] **Step 3: UI 구현**

`Sources/Lighthouse/ColorGradingControls.swift`:

```swift
import SwiftUI
import LighthouseCore

/// 컬러 그레이딩: 영역 하나를 골라 색상 바퀴와 슬라이더로 조절한다. 혼합·균형은 모든 영역에 공통이다.
struct ColorGradingControls: View {
    @EnvironmentObject private var model: LibraryModel
    let edits: EditSettings
    @State private var region: ColorGradeRegion = .shadows

    var body: some View {
        Group {
            Divider()
            Text("컬러 그레이딩").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(ColorGradeRegion.allCases, id: \.self) { item in
                    regionButton(item)
                }
            }
            ColorWheel(hue: zone.hue, saturation: zone.saturation,
                       change: { hue, saturation in
                           updateZone(continuous: true) { $0.hue = hue; $0.saturation = saturation }
                       },
                       end: { model.endContinuousEdit() },
                       reset: { resetZone() })
                .frame(width: 160, height: 160)
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel("\(region.title) 색상 바퀴")
                .accessibilityValue("색조 \(Int(zone.hue.rounded()))도, 채도 \(Int((zone.saturation * 100).rounded()))")
                .help("끌어서 색조와 채도를 고릅니다. 두 번 누르면 이 영역을 초기화합니다.")
            gradingSlider("색조", value: zone.hue, range: 0...359, format: "%.0f°", defaultValue: 0) { value in
                updateZone(continuous: true) { $0.hue = value.isFinite ? min(359, max(0, value)) : 0 }
            }
            gradingSlider("채도", value: zone.saturation * 100, range: 0...100, format: "%.0f", defaultValue: 0) { value in
                updateZone(continuous: true) { $0.saturation = value.isFinite ? min(1, max(0, value / 100)) : 0 }
            }
            gradingSlider("명도", value: zone.luminance * 100, range: -100...100, format: "%+.0f",
                          defaultValue: 0) { value in
                updateZone(continuous: true) { $0.luminance = value.isFinite ? min(1, max(-1, value / 100)) : 0 }
            }
            gradingSlider("혼합", value: grading.blending * 100, range: 0...100, format: "%.0f",
                          defaultValue: ColorGrading.neutral.blending * 100) { value in
                update(continuous: true) { $0.blending = value.isFinite ? min(1, max(0, value / 100)) : 0.5 }
            }
            gradingSlider("균형", value: grading.balance * 100, range: -100...100, format: "%+.0f",
                          defaultValue: 0) { value in
                update(continuous: true) { $0.balance = value.isFinite ? min(1, max(-1, value / 100)) : 0 }
            }
            Button("\(region.title) 초기화") { resetZone() }
                .disabled(zone == ColorGradeZone())
                .accessibilityLabel("\(region.title) 컬러 그레이딩 초기화")
        }
    }

    private var grading: ColorGrading { edits.colorGrading }
    private var zone: ColorGradeZone { grading[keyPath: region.keyPath] }

    private func regionButton(_ item: ColorGradeRegion) -> some View {
        let itemZone = grading[keyPath: item.keyPath]
        return Button { region = item } label: {
            HStack(spacing: 3) {
                Text(item.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                if !itemZone.isNeutral {
                    Circle().fill(Color(hue: itemZone.hue / 360, saturation: 1, brightness: 1))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(region == item ? Color.accentColor : nil)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(region == item ? .isSelected : [])
    }

    private func update(continuous: Bool = false, _ change: (inout ColorGrading) -> Void) {
        var next = edits
        change(&next.colorGrading)
        model.updateEdits(next, continuous: continuous)
    }

    private func updateZone(continuous: Bool = false, _ change: (inout ColorGradeZone) -> Void) {
        let path = region.keyPath
        update(continuous: continuous) { change(&$0[keyPath: path]) }
    }

    private func resetZone() {
        updateZone { $0 = ColorGradeZone() }
    }

    /// 두 번 누르면 `defaultValue`로 돌아간다.
    private func gradingSlider(_ title: String, value: Double, range: ClosedRange<Double>, format: String,
                               defaultValue: Double, set: @escaping @MainActor (Double) -> Void) -> some View {
        SliderRow(title: title, value: value, range: range, valueText: String(format: format, value),
                  set: { set($0) }, end: { model.endContinuousEdit() },
                  reset: { set(defaultValue); model.endContinuousEdit() })
    }
}

extension ColorGradeRegion {
    var title: String {
        switch self {
        case .shadows: "그림자"
        case .midtones: "중간톤"
        case .highlights: "하이라이트"
        case .global: "전체"
        }
    }
}

/// 0°(빨강)가 오른쪽이고 반시계 방향으로 도는 바퀴. 중심에서의 거리가 채도다. 좌표는 SwiftUI처럼 y가 아래로 커진다.
enum ColorWheelGeometry {
    static func value(at location: CGPoint, size: CGFloat) -> (hue: Double, saturation: Double) {
        let radius = Double(size) / 2
        let dx = Double(location.x) - radius
        let dy = radius - Double(location.y)
        guard radius > 0, dx != 0 || dy != 0 else { return (0, 0) }
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        if hue >= 360 { hue = 0 }
        return (hue, min(1, (dx * dx + dy * dy).squareRoot() / radius))
    }

    static func point(hue: Double, saturation: Double, size: CGFloat) -> CGPoint {
        let radius = Double(size) / 2
        let angle = hue * .pi / 180
        return CGPoint(x: radius + cos(angle) * saturation * radius,
                       y: radius - sin(angle) * saturation * radius)
    }
}

private struct ColorWheel: View {
    let hue: Double
    let saturation: Double
    let change: (Double, Double) -> Void
    let end: () -> Void
    let reset: () -> Void

    /// AngularGradient는 화면에서 시계 방향으로 진행하므로 색조를 거꾸로 놓아 반시계 방향 바퀴를 만든다.
    private static let hueStops = stride(from: 360, through: 0, by: -30).map {
        Color(hue: Double($0 % 360) / 360, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let marker = ColorWheelGeometry.point(hue: hue, saturation: saturation, size: size)
            ZStack {
                Circle().fill(AngularGradient(colors: Self.hueStops, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: size / 2))
                Circle().stroke(Color.secondary.opacity(0.4))
                Circle().stroke(Color.white, lineWidth: 3)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .frame(width: 12, height: 12)
                    .position(marker)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let picked = ColorWheelGeometry.value(at: value.location, size: size)
                    change(picked.hue, picked.saturation)
                }
                .onEnded { _ in end() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        }
    }
}
```

`Sources/Lighthouse/AdvancedColorControls.swift`에서 다음 블록 바로 뒤:
```swift
            Button("이 색상 초기화") { resetRange() }
                .disabled(rangeAdjustment == ColorRangeAdjustment(band: band))
                .accessibilityLabel("\(band.koreanName) HSL 초기화")
```
한 줄 추가:
```swift
            ColorGradingControls(edits: edits)
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter ColorGradingFlowTests`
Expected: 3 PASS, 1 skipped(스냅샷)

Run: `LIGHTHOUSE_SNAPSHOT_DIR=.artifacts/color-grading-20261009/snapshots swift test --filter ColorGradingFlowTests/testRenderColorGradingControlsWhenSnapshotDirectoryIsProvided`
Expected: PASS. 생성된 `color-grading-300.png`, `color-grading-inspector-300.png`를 Read로 열어 다음을 확인한다: 영역 버튼 4개가 잘리지 않음("하이라이트" 포함), 바퀴 위쪽=초록 계열(90°)·왼쪽=청록(180°), 그림자·하이라이트 버튼에 색 점, 슬라이더 값 표시, 300px에서 겹침 없음. 잘리면 `minimumScaleFactor`·`spacing`만 조정하고 다시 그린다.

- [ ] **Step 5: 체크포인트**

Run: `git diff --check -- Sources/Lighthouse Tests/LighthouseTests/ColorGradingFlowTests.swift`
Expected: 출력 없음

---

### Task 5: 문서, 실제 RW2·앱 검증, 통합

**Files:**
- Modify: `docs/lightroom-presets.md` (지원 표, 제외 문장, 사용 안내)
- Modify: `docs/advanced-editing.md` (새 절, 일괄 적용 문장)
- Create: `docs/color-grading-verification.md`
- Create (Git 제외 산출물): `.artifacts/color-grading-20261009/grading-probe.swift`, `run-probe.sh`, `pixels/`

**Interfaces:**
- Consumes: Task 1–4 전체

- [ ] **Step 1: 사용 안내 갱신**

`docs/lightroom-presets.md` 지원 표의 `| 기본 프로필·흑백 | ... |` 행 다음에:
```markdown
| 컬러 그레이딩·분할 톤 | 그림자·중간톤·하이라이트·전체의 색조·채도·명도, 혼합, 균형. 옛 분할 톤 키도 같은 값으로 읽음 |
```
제외 문장에서 `컬러 그레이딩·분할 톤, `을 삭제한다. "## 새 조절값 사용하기" 절 첫 문단 뒤에 추가:
```markdown
**색상 → 컬러 그레이딩**에서 그림자·중간톤·하이라이트·전체 중 하나를 고르고 바퀴를 끌어 색조와 채도를 정합니다. 명도는 해당 밝기대만 밝히거나 어둡게 합니다. 혼합은 영역 경계의 부드러움, 균형은 그림자와 하이라이트의 경계 위치입니다. 흑백 프로필과 함께 쓰면 분할 톤 흑백 사진을 만들 수 있습니다. 색 변환은 Lighthouse 고유 수식이며 Adobe 결과와 같은 픽셀을 보장하지 않습니다.
```

`docs/advanced-editing.md`의 `## 필름 입자` 앞에 새 절:
```markdown
## 컬러 그레이딩

색상 범위 HSL 아래에서 그림자·중간톤·하이라이트·전체 영역의 색을 바꿉니다. 바퀴의 방향이 색조, 중심에서의 거리가 채도입니다. 틴트는 밝기를 바꾸지 않으며 순수한 검정과 흰색은 그대로 남습니다. 혼합을 높이면 영역 경계가 부드러워지고, 균형을 +로 하면 하이라이트 영역이 넓어집니다. 부분 보정 마스크에는 적용되지 않습니다.
```
`## 일괄 적용과 LUT의 범위`의 첫 문장을 `전체 보정 복사에는 곡선·색상 범위·컬러 그레이딩·입자가 포함됩니다.`로 바꾼다.

- [ ] **Step 2: 실제 S9 RW2·색상표 렌더 프로브 작성**

`.artifacts/color-grading-20261009/grading-probe.swift`:
```swift
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LighthouseCore

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent(".artifacts/color-grading-20261009/pixels")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rawURL = root.appendingPathComponent(".artifacts/samples/LUMIX-S9.RW2")
let chartURL = root.appendingPathComponent(".artifacts/lightroom-presets-20261007/fixtures/color-study.png")
let xmpURL = root.appendingPathComponent(".artifacts/lightroom-presets-20261007/downloaded-presets/my.slow.film.xmp")
let originals = [rawURL, chartURL, xmpURL]
func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
let before = try originals.map(sha)

let slow = try LightroomPresetImporter.load(url: xmpURL)
precondition(slow.applied(to: .neutral).colorGrading == .neutral, "my.slow.film의 그레이딩 값은 중립이다")
precondition(!slow.lightroom!.warnings.contains { $0.contains("제외: SplitToning") || $0.contains("제외: ColorGrade") })

let teal = ColorGrading(shadows: ColorGradeZone(hue: 200, saturation: 0.35),
                        highlights: ColorGradeZone(hue: 35, saturation: 0.3), balance: 0.1)
let cases: [(String, EditSettings)] = [
    ("neutral", EditSettings()),
    ("blend-only", EditSettings(colorGrading: ColorGrading(blending: 0.9))),
    ("teal-orange", EditSettings(colorGrading: teal)),
    ("mono-split", EditSettings(colorProfile: .monochrome, colorGrading: teal)),
    ("slow-film", slow.applied(to: .neutral)),
]
let pipeline = ImagePipeline()
var means: [String: [Double]] = [:]
for source in [rawURL, chartURL] {
    for (name, edits) in cases {
        let image = try pipeline.render(url: source, edits: edits, maxPixel: 1600)
        let label = source.deletingPathExtension().lastPathComponent + "-" + name
        let destination = CGImageDestinationCreateWithURL(
            outDir.appendingPathComponent(label + ".jpg") as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = Double(image.width * image.height)
        means[label] = (0..<3).map { channel in
            stride(from: channel, to: bytes.count, by: 4).reduce(0.0) { $0 + Double(bytes[$1]) } / count
        }
        print(label, means[label]!.map { String(format: "%.2f", $0) }.joined(separator: " "))
    }
}
for prefix in ["LUMIX-S9", "color-study"] {
    precondition(means["\(prefix)-neutral"] == means["\(prefix)-blend-only"], "혼합만 바꾸면 픽셀이 같다")
    precondition(means["\(prefix)-neutral"] == means["\(prefix)-slow-film"], "중립 프리셋은 픽셀이 같다")
    precondition(means["\(prefix)-neutral"] != means["\(prefix)-teal-orange"], "그레이딩이 실제로 보인다")
}
precondition(try originals.map(sha) == before, "원본 bytes가 그대로다")
print("ALL_OK original-sha256", before)
```

`.artifacts/color-grading-20261009/run-probe.sh`:
```sh
#!/bin/zsh
set -eu
cd /Users/joon/rian/lighthouse
swift build
swiftc -I .build/arm64-apple-macosx/debug/Modules .artifacts/color-grading-20261009/grading-probe.swift \
  .build/arm64-apple-macosx/debug/LighthouseCore.build/*.o -o .artifacts/color-grading-20261009/grading-probe
.artifacts/color-grading-20261009/grading-probe
```

Run: `zsh .artifacts/color-grading-20261009/run-probe.sh`
Expected: 케이스별 평균 RGB 10줄과 `ALL_OK`. 링크 오류가 나면 `.artifacts/lightroom-tone-20261007/run-probe.sh`와 같은 방식인지 확인한다. 그래도 안 되면 프로브 대신 같은 내용을 opt-in XCTest로 옮기고, 그 사실을 검증 문서에 적는다.

`LUMIX-S9-teal-orange.jpg`, `LUMIX-S9-mono-split.jpg`를 Read로 열어 그림자가 청록, 밝은 부분이 주황 쪽인지 눈으로 확인한다.

- [ ] **Step 3: 전체 검증**

Run: `swift test 2>&1 | tail -20`
Expected: 0 failures(opt-in skip은 개수 기록)

Run: `swift build`
Expected: Build complete

Run: `./scripts/build-app.sh && codesign --verify --deep --strict dist/Lighthouse.app`
Expected: 빌드 성공, codesign 출력 없음

- [ ] **Step 4: 실제 앱 실행**

```sh
export LIGHTHOUSE_DATA_DIR="$(mktemp -d /private/tmp/claude-501/-Users-joon-rian-lighthouse/6d395dc4-3f77-436c-a2e7-934f20ef2c48/scratchpad/lh-data.XXXX)"
dist/Lighthouse.app/Contents/MacOS/Lighthouse & echo $! > "$LIGHTHOUSE_DATA_DIR/pid"
```
창이 뜨고 바로 종료되지 않는지 확인한다(`ps -p $(cat "$LIGHTHOUSE_DATA_DIR/pid")`). 같은 번들 ID의 다른 Lighthouse가 이미 실행 중이면 그 프로세스는 건드리지 않고 이 사실을 기록한다. 접근성 권한이 있으면 컬러 그레이딩 바퀴를 끌어 미리보기 변화와 ⌘Z 1회 복구를 확인하고, 없으면 실제 UI 조작은 `not_run`으로 기록한다. 끝나면 `kill $(cat "$LIGHTHOUSE_DATA_DIR/pid")`로 **이 PID만** 종료한다.

- [ ] **Step 5: 검증 기록**

`docs/color-grading-verification.md`에 실제 결과만 적는다: 실행한 명령과 통과/실패/skip 수, 프로브 평균 RGB 표와 `ALL_OK`, 원본 SHA256 3개, 스냅샷 확인 결과, release·codesign, 실제 앱 PID와 실행 여부, 실제 UI 조작 `not_run` 여부와 이유, "Adobe와의 시각적 일치는 검증하지 않음". 결과가 다르면 그대로 적고 완료로 표시하지 않는다.

Run: `git diff --check`
Expected: 출력 없음

- [ ] **Step 6: 인계 기록**

```sh
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3 '/Users/joon/rian/rian-obsidian/90 System/scripts/continuity.py' record --tool claude --cwd /Users/joon/rian/lighthouse --title '컬러 그레이딩 구현·검증' --body -
```
본문: 목표 / 결정 / 변경 파일 / 실제 검증·미실행 / 다음(2번 텍스처·디헤이즈·WB, 3번 DCP 타당성 실험). 커밋 여부는 사용자에게 묻는다.
