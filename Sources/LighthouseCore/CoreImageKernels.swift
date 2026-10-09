import CoreImage

/// Core Image 전용 커널. 폐기된 Core Image Kernel Language 대신 Metal 소스를 실행 중에 컴파일한다.
/// 여러 함수를 한 소스로 컴파일하면 일부 커널이 0을 돌려주는 경우가 있어 커널마다 따로 컴파일한다.
enum CoreImageKernels {
    /// 중간 톤 위주로 `fine - coarse` 대비를 더한다(명료도).
    static let clarity = compile("""
        [[stitchable]] float4 lighthouseClarity(coreimage::sample_t image, coreimage::sample_t fine,
                                                coreimage::sample_t coarse, float amount) {
            float luma = dot(image.rgb, float3(0.2126, 0.7152, 0.0722));
            float tone = pow(clamp(luma, 0.0, 1.0), 0.4545);
            float midtones = clamp(4.0 * tone * (1.0 - tone), 0.0, 1.0);
            return float4(image.rgb + amount * midtones * (fine.rgb - coarse.rgb), image.a);
        }
        """)

    /// 세 채널 중 가장 작은 값(0…1로 자름)을 회색으로 낸다(디헤이즈의 어두운 채널).
    static let minimumChannel = compile("""
        [[stitchable]] float4 lighthouseMinimumChannel(coreimage::sample_t pixel) {
            float m = clamp(min(min(pixel.r, pixel.g), pixel.b), 0.0, 1.0);
            return float4(m, m, m, 1.0);
        }
        """)

    /// 밝기 Y(0 이상)를 회색으로 낸다(Adaptive 톤의 밝기 지도).
    static let luminance = compile("""
        [[stitchable]] float4 lighthouseLuminance(coreimage::sample_t pixel) {
            float y = max(dot(pixel.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0);
            return float4(y, y, y, 1.0);
        }
        """)

    /// Adaptive 톤. 흐린 밝기 `Yb`로 `clamp((Yb / 0.18)^(-strength), 0.5, 4)`를 정해 RGB에 곱한다(선형 값).
    static let adaptiveGain = compile("""
        [[stitchable]] float4 lighthouseAdaptiveGain(coreimage::sample_t pixel, coreimage::sample_t blurred, float strength) {
            float gain = clamp(pow(max(blurred.r, 0.0001) / 0.18, -strength), 0.5, 4.0);
            return float4(pixel.rgb * gain, pixel.a);
        }
        """)

    /// 디헤이즈. 양수는 대기광을 흰색으로 보고 `(I - 1) / t + 1`로 안개를 걷고, 음수는 회색(0.6) 안개를 섞는다.
    /// 0…1 안에서 계산하고 밖의 초과분은 그대로 더해 확장 범위를 보존한다.
    static let dehaze = compile("""
        [[stitchable]] float4 lighthouseDehaze(coreimage::sample_t pixel, coreimage::sample_t dark, float amount) {
            float3 original = pixel.rgb;
            float3 base = clamp(original, 0.0, 1.0);
            float3 changed;
            if (amount > 0.0) {
                float t = max(0.3, 1.0 - 0.7 * amount * clamp(dark.r, 0.0, 1.0));
                changed = (base - 1.0) / t + 1.0;
            } else {
                changed = mix(base, float3(0.6), -0.25 * amount);
            }
            return float4(original + (clamp(changed, 0.0, 1.0) - base), pixel.a);
        }
        """)

    /// 0…range의 선형 값을 `log2(1 + gain·x) / log2(1 + gain·range)`로 0…1에 접는다(DCP 큐브 입력). 음수는 0이다.
    static let logShape = compile("""
        [[stitchable]] float4 lighthouseLogShape(coreimage::sample_t pixel, float gain, float range) {
            float3 x = max(pixel.rgb, float3(0.0));
            return float4(min(log2(1.0 + gain * x) / log2(1.0 + gain * range), float3(1.0)), pixel.a);
        }
        """)

    /// `logShape`의 역(DCP 큐브 출력).
    static let logUnshape = compile("""
        [[stitchable]] float4 lighthouseLogUnshape(coreimage::sample_t pixel, float gain, float range) {
            return float4((exp2(pixel.rgb * log2(1.0 + gain * range)) - 1.0) / gain, pixel.a);
        }
        """)

    /// 캘리브레이션 그림자 틴트. 밝기 0.25 아래에 밝기 0인 마젠타(+)·초록(-) 방향을 더한다. 선형 값이며 틴트로 0 아래로 내리지 않는다.
    static let shadowTint = compile("""
        [[stitchable]] float4 lighthouseShadowTint(coreimage::sample_t pixel, float amount) {
            float y = dot(pixel.rgb, float3(0.2126, 0.7152, 0.0722));
            float t = clamp(y / 0.25, 0.0, 1.0);
            float weight = 4.0 * clamp(y, 0.0, 0.25) * (1.0 - t) * (1.0 - t);
            float3 direction = float3(0.7152, -0.2848, 0.7152);
            float3 changed = pixel.rgb + 0.2 * amount * weight * direction;
            return float4(max(changed, min(pixel.rgb, float3(0.0))), pixel.a);
        }
        """)

    /// sRGB 값에 0과 1을 그대로 두는 3차 S자 곡선을 건다(대비). 가운데(0.5)의 기울기는 `1 + strength / 4`이고,
    /// strength가 -2…2(대비 0.5…1.5)이면 곡선이 단조 증가한다. 0…1 밖의 값은 바꾸지 않는다.
    static let contrast = compile("""
        [[stitchable]] float4 lighthouseContrast(coreimage::sample_t pixel, float strength) {
            float3 x = pixel.rgb;
            float3 curved = x + strength * (x - 0.5) * x * (1.0 - x);
            float3 inside = step(float3(0.0), x) * step(x, float3(1.0));
            return float4(mix(x, curved, inside), pixel.a);
        }
        """)

    /// sRGB 값의 섀도·하이라이트·흰색·검정 범위를 독립적으로 움직인다.
    /// 0…1 밖은 가까운 끝점의 이동량을 더해 확장 범위 차이를 보존하고, 원래 알파를 유지한다.
    static let additionalTone = compile("""
        [[stitchable]] float4 lighthouseAdditionalTone(coreimage::sample_t pixel, float highlight,
                                                       float shadow, float whites, float blacks) {
            if (pixel.a <= 0.0) { return pixel; }
            float3 original = pixel.rgb / pixel.a;
            float3 base = clamp(original, 0.0, 1.0);
            float3 x = base;
            x += shadow * 0.8 * x * pow(1.0 - x, float3(2.0));
            x += highlight * 0.8 * x * x * (1.0 - x);
            x += whites * 0.25 * smoothstep(float3(0.5), float3(1.0), x);
            x += blacks * 0.25 * (1.0 - smoothstep(float3(0.0), float3(0.5), x));
            float3 changed = original + (clamp(x, 0.0, 1.0) - base);
            return float4(changed * pixel.a, pixel.a);
        }
        """)

    /// 출력 좌표에서 만든 값 노이즈를 sRGB 값에 더한다(필름 입자).
    static let grain = compile("""
        [[stitchable]] float4 lighthouseGrain(coreimage::sample_t pixel, float grainSize, float amount, float seed,
                                              float roughness,
                                              coreimage::destination dest) {
            float2 position = dest.coord() / grainSize;
            float2 cell = floor(position);
            float2 linearBlend = fract(position);
            float2 smoothBlend = linearBlend * linearBlend * (3.0 - 2.0 * linearBlend);
            float2 blend = roughness <= 0.5
                ? mix(linearBlend, smoothBlend, roughness * 2.0)
                : mix(smoothBlend, step(float2(0.5), linearBlend), (roughness - 0.5) * 2.0);
            float n00 = fract(sin(dot(cell, float2(12.9898, 78.233)) + seed) * 43758.5453);
            float n10 = fract(sin(dot(cell + float2(1.0, 0.0), float2(12.9898, 78.233)) + seed) * 43758.5453);
            float n01 = fract(sin(dot(cell + float2(0.0, 1.0), float2(12.9898, 78.233)) + seed) * 43758.5453);
            float n11 = fract(sin(dot(cell + float2(1.0, 1.0), float2(12.9898, 78.233)) + seed) * 43758.5453);
            float noise = mix(mix(n00, n10, blend.x), mix(n01, n11, blend.x), blend.y);
            float3 changed = clamp(pixel.rgb + (noise - 0.5) * amount * 0.22, 0.0, 1.0);
            return float4(changed, pixel.a);
        }
        """)

    /// 복제한 패치의 저주파 밝기·색을 목적지에 맞춘다(스팟 복구).
    static let healCorrection = compile("""
        [[stitchable]] float4 lighthouseHealCorrection(coreimage::sample_t source, coreimage::sample_t lowTarget,
                                                       coreimage::sample_t lowSource) {
            return float4(clamp(source.rgb + lowTarget.rgb - lowSource.rgb, 0.0, 1.0), source.a);
        }
        """)

    /// 확장 범위 현상과 보통 현상의 밝기 비율(1…16)을 세 채널에 넣는다(HDR 배율). 기본 혼합 필터는 0…1로 잘라 쓰지 않는다.
    static let brightnessRatio = compile("""
        [[stitchable]] float4 lighthouseBrightnessRatio(coreimage::sample_t standard, coreimage::sample_t extended) {
            float3 weights = float3(0.2126, 0.7152, 0.0722);
            float ratio = (dot(extended.rgb, weights) + 0.002) / (dot(standard.rgb, weights) + 0.002);
            return float4(float3(clamp(ratio, 1.0, 16.0)), 1.0);
        }
        """)

    /// 선형 값에 배율을 곱한다. 1을 넘는 값을 그대로 둔다.
    static let applyGain = compile("""
        [[stitchable]] float4 lighthouseApplyGain(coreimage::sample_t image, coreimage::sample_t gain) {
            return float4(image.rgb * gain.r, image.a);
        }
        """)

    /// 방향 적용된 이미지의 좌상단 기준 위치에서 밴딩 보정 EV를 계산해 선형 RGB에 곱한다.
    static let flickerCorrection = compile("""
        [[stitchable]] float4 lighthouseFlickerCorrection(
            coreimage::sample_t pixel, float direction, float cycles, float phase, float amount,
            float colorAmount, float originX, float originY, float width, float height,
            float4 redA, float4 redB, float4 greenA, float4 greenB, float4 blueA, float4 blueB,
            coreimage::destination dest) {
            float coordinate = direction < 0.5
                ? (originY + height - dest.coord().y) / height
                : (dest.coord().x - originX) / width;
            float baseAngle = 6.28318530718 * (cycles * coordinate + phase);
            float3 correction = float3(0.0);
            correction.r = redA.x * sin(baseAngle) + redA.y * cos(baseAngle)
                         + redA.z * sin(2.0 * baseAngle) + redA.w * cos(2.0 * baseAngle)
                         + redB.x * sin(3.0 * baseAngle) + redB.y * cos(3.0 * baseAngle);
            correction.g = greenA.x * sin(baseAngle) + greenA.y * cos(baseAngle)
                         + greenA.z * sin(2.0 * baseAngle) + greenA.w * cos(2.0 * baseAngle)
                         + greenB.x * sin(3.0 * baseAngle) + greenB.y * cos(3.0 * baseAngle);
            correction.b = blueA.x * sin(baseAngle) + blueA.y * cos(baseAngle)
                         + blueA.z * sin(2.0 * baseAngle) + blueA.w * cos(2.0 * baseAngle)
                         + blueB.x * sin(3.0 * baseAngle) + blueB.y * cos(3.0 * baseAngle);
            float luminance = dot(correction, float3(0.2126, 0.7152, 0.0722));
            correction = mix(float3(luminance), correction, colorAmount);
            float3 multiplier = exp2(-clamp(correction * amount, float3(-2.0), float3(2.0)));
            return float4(pixel.rgb * multiplier, pixel.a);
        }
        """)

    private static func compile(_ body: String) -> CIColorKernel? {
        let source = """
            #include <metal_stdlib>
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            \(body)
            """
        return (try? CIKernel.kernels(withMetalString: source))?.first as? CIColorKernel
    }
}
