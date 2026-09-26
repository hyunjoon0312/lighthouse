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

    /// 출력 좌표에서 만든 값 노이즈를 sRGB 값에 더한다(필름 입자).
    static let grain = compile("""
        [[stitchable]] float4 lighthouseGrain(coreimage::sample_t pixel, float grainSize, float amount, float seed,
                                              coreimage::destination dest) {
            float2 position = dest.coord() / grainSize;
            float2 cell = floor(position);
            float2 blend = fract(position);
            blend = blend * blend * (3.0 - 2.0 * blend);
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
