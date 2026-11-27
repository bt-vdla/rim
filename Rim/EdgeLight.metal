#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float roundedBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static half3 palette(float t, half4 c0, half4 c1, half4 c2) {
    t = fract(t) * 3.0;
    if (t < 1.0) return mix(c0.rgb, c1.rgb, half(t));
    if (t < 2.0) return mix(c1.rgb, c2.rgb, half(t - 1.0));
    return mix(c2.rgb, c0.rgb, half(t - 2.0));
}

/// A band of light hugging the screen edge. Trail points (x, y, weight) light the band; the head
/// alone swells it inward, so the moving head reads as a soft bulge on a clean, even line.
[[ stitchable ]] half4 edgeLight(
    float2 position, half4 color,
    float2 size, float radius,
    device const float *trail, int count,
    half4 c0, half4 c1, half4 c2,
    float base, float bulge, float pulse, float intensity
) {
    float2 center = size * 0.5;
    float depth = -roundedBox(position - center, center, radius);
    if (depth > 140.0) return half4(0.0);

    // The trail only sets brightness. Thickness comes from the head alone, so the band keeps an even
    // width along its length and swells once, smoothly, where the breath is.
    float energy = 0.0;
    float head = 0.0;
    float swell = 0.0;
    for (int i = 0; i + 2 < count; i += 3) {
        float2 point = float2(trail[i], trail[i + 1]);
        float w = trail[i + 2];
        float d = distance(position, point);
        float g = w * exp(-(d * d) / (2.0 * 40.0 * 40.0));
        energy = max(energy, g);
        if (i == 0) {
            head = w * exp(-(d * d) / (2.0 * 22.0 * 22.0));
            swell = w * exp(-(d * d) / (2.0 * 48.0 * 48.0));
        }
    }
    float lit = max(energy, pulse);
    float thickness = base + bulge * swell + 2.5 * pulse;

    float core = 1.0 - smoothstep(thickness - 1.2, thickness + 1.2, depth);
    float spill = max(depth - thickness, 0.0);
    float glow = exp(-spill / (5.0 + 16.0 * max(energy, pulse * 0.5))) * lit * 0.4;
    float brightness = core * (0.14 + 0.86 * lit) + glow;

    float angle = atan2(position.y - center.y, position.x - center.x) / (2.0 * M_PI_F) + 0.5;
    half3 tint = palette(angle, c0, c1, c2);
    tint = mix(tint, half3(1.0), half(clamp(head * core * 0.65, 0.0, 1.0)));

    float a = clamp(brightness * intensity, 0.0, 1.0);
    return half4(tint * half(a), half(a));
}
