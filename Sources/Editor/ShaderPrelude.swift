import Foundation

/// Self-contained Metal prelude prepended to runtime-compiled custom shaders so
/// they can use the full Spectra helper library (uniform struct, color, noise,
/// blend, compositing). Generated from `Sources/Shaders/SpectraCommon.h` — keep in
/// sync if that header changes. Custom shaders must NOT re-include <metal_stdlib>.
enum ShaderPrelude {
    static let source: String = ##"""
// SpectraCommon.h
//
// Shared Metal prelude for every Spectra effect shader. Provides the uniform
// contract, sampling helpers, color-space conversions, a procedural noise
// framework, blend operators, and the universal compositing helper.
//
// All free functions are marked `inline` so the header can be included by many
// translation units without producing duplicate symbols when linked into a
// single metallib.

#ifndef SPECTRA_COMMON_H
#define SPECTRA_COMMON_H

#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex output

struct RasterizerData {
    float4 position [[position]];
    float2 uv;
};

// MARK: - Uniform contract (mirrors SpectraUniforms in Uniforms.swift)

struct SpectraUniforms {
    float2 resolution;   // render target size in pixels
    float2 texelSize;    // 1 / resolution
    float  time;         // seconds since engine start
    float  frameIndex;   // monotonic frame counter
    float  strength;     // universal intensity (0..1)
    float  opacity;      // universal opacity (0..1)
    float  blendAmount;  // amount of blend-mode applied (0..1)
    float  blendMode;    // BlendMode raw value
    float  seed;         // per-instance random seed (0..1)
    float  passIndex;    // current pass index for multi-pass effects
    float2 direction;    // direction vector for separable/directional passes
    float  passScale;    // render target scale for this pass
    float  _reserved;
    float  params[64];   // effect-specific parameters (declaration order)
};

// MARK: - Sampling

inline float4 spectra_tex(texture2d<float> t, float2 uv) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return t.sample(s, uv);
}

inline float4 spectra_texPoint(texture2d<float> t, float2 uv) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    return t.sample(s, uv);
}

inline float4 spectra_texWrap(texture2d<float> t, float2 uv) {
    constexpr sampler s(address::repeat, filter::linear);
    return t.sample(s, uv);
}

// MARK: - Color helpers

inline float spectra_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
inline float spectra_lumaRec601(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

inline float3 spectra_toLinear(float3 c) {
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}
inline float3 spectra_toSRGB(float3 c) {
    return select(c * 12.92, 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055, c > 0.0031308);
}

inline float3 spectra_rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

inline float3 spectra_hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// YIQ used for NTSC-style processing.
inline float3 spectra_rgb2yiq(float3 c) {
    return float3(
        dot(c, float3(0.299, 0.587, 0.114)),
        dot(c, float3(0.596, -0.274, -0.322)),
        dot(c, float3(0.211, -0.523, 0.312)));
}
inline float3 spectra_yiq2rgb(float3 c) {
    return float3(
        dot(c, float3(1.0, 0.956, 0.621)),
        dot(c, float3(1.0, -0.272, -0.647)),
        dot(c, float3(1.0, -1.106, 1.703)));
}

// MARK: - Hashing (Dave Hoskins, MIT)

inline float spectra_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

inline float spectra_hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float2 spectra_hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

inline float3 spectra_hash33(float3 p3) {
    p3 = fract(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// MARK: - Noise framework

inline float spectra_valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = spectra_hash21(i + float2(0, 0));
    float b = spectra_hash21(i + float2(1, 0));
    float c = spectra_hash21(i + float2(0, 1));
    float d = spectra_hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float spectra_gradientNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float2 ga = spectra_hash22(i + float2(0, 0)) * 2.0 - 1.0;
    float2 gb = spectra_hash22(i + float2(1, 0)) * 2.0 - 1.0;
    float2 gc = spectra_hash22(i + float2(0, 1)) * 2.0 - 1.0;
    float2 gd = spectra_hash22(i + float2(1, 1)) * 2.0 - 1.0;
    float va = dot(ga, f - float2(0, 0));
    float vb = dot(gb, f - float2(1, 0));
    float vc = dot(gc, f - float2(0, 1));
    float vd = dot(gd, f - float2(1, 1));
    return 0.5 + 0.7 * mix(mix(va, vb, u.x), mix(vc, vd, u.x), u.y);
}

inline float2 spectra_mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
inline float3 spectra_mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
inline float3 spectra_permute(float3 x) { return spectra_mod289(((x * 34.0) + 1.0) * x); }

inline float spectra_simplex(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                            -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = spectra_mod289(i);
    float3 p = spectra_permute(spectra_permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

inline float spectra_fbm(float2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * spectra_valueNoise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// Worley / cellular noise. Returns (F1, F2) feature distances.
inline float2 spectra_cellular(float2 p) {
    float2 ip = floor(p);
    float2 fp = fract(p);
    float d1 = 8.0;
    float d2 = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 g = float2(x, y);
            float2 o = spectra_hash22(ip + g);
            float2 r = g + o - fp;
            float d = dot(r, r);
            if (d < d1) { d2 = d1; d1 = d; }
            else if (d < d2) { d2 = d; }
        }
    }
    return float2(sqrt(d1), sqrt(d2));
}

// Gaussian-distributed white noise via Box-Muller.
inline float spectra_gaussianNoise(float2 p) {
    float u1 = max(spectra_hash21(p), 1.0e-6);
    float u2 = spectra_hash21(p + 17.13);
    return sqrt(-2.0 * log(u1)) * cos(6.28318530718 * u2);
}

// MARK: - Geometry helpers

inline float2 spectra_rotate(float2 p, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

inline float spectra_remap(float v, float inMin, float inMax, float outMin, float outMax) {
    return outMin + (outMax - outMin) * clamp((v - inMin) / (inMax - inMin), 0.0, 1.0);
}

// MARK: - Blend operators (raw values match BlendMode.swift)

inline float3 spectra_blendOverlay(float3 b, float3 s) {
    return select(2.0 * b * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), b > 0.5);
}
inline float3 spectra_blendSoftLight(float3 b, float3 s) {
    return select(2.0 * b * s + b * b * (1.0 - 2.0 * s),
                  sqrt(b) * (2.0 * s - 1.0) + 2.0 * b * (1.0 - s), s > 0.5);
}
inline float3 spectra_blendColorDodge(float3 b, float3 s) {
    return select(min(float3(1.0), b / max(1.0 - s, 1.0e-4)), float3(1.0), s >= 1.0);
}
inline float3 spectra_blendColorBurn(float3 b, float3 s) {
    return select(1.0 - min(float3(1.0), (1.0 - b) / max(s, 1.0e-4)), float3(0.0), s <= 0.0);
}

inline float3 spectra_blend(float3 base, float3 s, float modeF) {
    int mode = int(modeF + 0.5);
    switch (mode) {
        case 0: return s;                                          // normal
        case 1: return base * s;                                   // multiply
        case 2: return 1.0 - (1.0 - base) * (1.0 - s);             // screen
        case 3: return spectra_blendOverlay(base, s);              // overlay
        case 4: return spectra_blendSoftLight(base, s);            // soft light
        case 5: return spectra_blendOverlay(s, base);              // hard light
        case 6: return min(float3(1.0), base + s);                 // add
        case 7: return max(float3(0.0), base - s);                 // subtract
        case 8: return abs(base - s);                              // difference
        case 9: return max(base, s);                               // lighten
        case 10: return min(base, s);                              // darken
        case 11: return spectra_blendColorDodge(base, s);          // color dodge
        case 12: return spectra_blendColorBurn(base, s);           // color burn
        case 13: return base + s - 2.0 * base * s;                 // exclusion
        case 14: return clamp(base + 2.0 * s - 1.0, 0.0, 1.0);     // linear light
        default: return s;
    }
}

// MARK: - Universal compositing

// Combine an effect's processed output with its input using the universal
// parameters (blend mode + amount, then strength * opacity).
inline float3 spectra_composite(float3 base, float3 processed, constant SpectraUniforms &u) {
    float3 blended = spectra_blend(base, processed, u.blendMode);
    float3 mixed = mix(processed, blended, clamp(u.blendAmount, 0.0, 1.0));
    float k = clamp(u.strength, 0.0, 1.0) * clamp(u.opacity, 0.0, 1.0);
    return mix(base, mixed, k);
}

inline float4 spectra_compositeRGBA(float3 base, float3 processed, constant SpectraUniforms &u) {
    return float4(spectra_composite(base, processed, u), 1.0);
}

#endif /* SPECTRA_COMMON_H */
"""##
}
