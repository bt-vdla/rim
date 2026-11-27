#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * noise(p);
        p = p * 2.03 + float2(17.1, 9.4);
        a *= 0.5;
    }
    return v;
}

/// Large, slowly folding fields of colour, like Apple Music's lyrics backdrop.
/// Domain-warped noise picks between four palette colours; the breath lifts brightness and slows the fold.
[[ stitchable ]] half4 aurora(
    float2 position, half4 color,
    float2 size, float time, float full, float zoom, float2 head, float pull,
    half4 c0, half4 c1, half4 c2, half4 c3
) {
    // The field breathes: it swells toward you on the inhale and settles back on the exhale.
    // Gravity: the field leans toward the light on the edge, as if it had weight.
    float2 toward = head - position;
    float reach = size.y * 0.38;
    float2 warped = position + toward * pull * exp(-dot(toward, toward) / (2.0 * reach * reach));
    float2 p = (warped - size * 0.5) / size.y * (1.5 - 0.32 * zoom);
    float t = time * 0.045;

    float2 q = float2(fbm(p + float2(0.0, t)), fbm(p + float2(5.2, -t * 0.8)));
    float2 r = float2(fbm(p + 2.2 * q + float2(1.7, 9.2) + t * 0.6),
                      fbm(p + 2.2 * q + float2(8.3, 2.8) - t * 0.5));
    float n = fbm(p + 2.0 * r);

    half3 col = mix(c0.rgb, c1.rgb, half(smoothstep(0.38, 0.62, n)));
    col = mix(col, c2.rgb, half(smoothstep(0.42, 0.68, r.y)));
    col = mix(col, c3.rgb, half(smoothstep(0.5, 0.8, q.x) * 0.7));
    // Push saturation like a blurred album cover.
    half l = dot(col, half3(0.299, 0.587, 0.114));
    col = clamp(mix(half3(l), col, half(1.75)), 0.0, 1.0);

    // Keep the centre a little deeper so words stay legible, and let the breath lift the whole field.
    float2 uv = position / size - 0.5;
    float centre = exp(-dot(uv * float2(1.6, 1.0), uv * float2(1.6, 1.0)) * 7.0);
    // Brightness and the dark centre both follow the breath: full lungs open the light up.
    float lift = 0.2 + 0.42 * full;
    half3 lit = col * half(lift * (1.0 - (0.55 - 0.25 * full) * centre));

    // A soft pool of colour gathers where it is pulled.
    float near = exp(-dot(toward, toward) / (2.0 * (reach * 0.6) * (reach * 0.6)));
    lit += col * half(near * pull * 0.6);

    // A whisper of grain stops large soft gradients banding.
    lit += half((hash(position + fract(time)) - 0.5) / 255.0 * 2.0);
    return half4(lit, 1.0);
}
