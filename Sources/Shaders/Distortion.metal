#include "SpectraCommon.h"

// Distortion effects. Each fragment function samples the effect input on
// texture(0) at a *modified* uv, computes the original (for compositing) from
// texture(1) at the *unmodified* uv, reads parameters in declaration order from
// u.params[]. `strength` scales the displacement (the warped uv is lerped from
// the unmodified uv) and the result composites with `spectra_compositeFull` — so
// a partial-strength warp is subtler, never a ghost of the unwarped image.
//
// These are UV-remap effects: geometry is computed in an aspect-corrected space
// so radial shapes stay circular regardless of the render target's shape, then
// converted back to texture coordinates for sampling.

// Aspect ratio (width / height) of the render target, guarded against zero.
inline float fx_distort_aspect(constant SpectraUniforms &u) {
    return max(u.resolution.x, 1.0) / max(u.resolution.y, 1.0);
}

// Convert a uv offset from a center into aspect-corrected space where one unit
// is square on screen (x scaled by aspect so circles look circular).
inline float2 fx_distort_toAspect(float2 d, float aspect) {
    return float2(d.x * aspect, d.y);
}

// Inverse of fx_distort_toAspect.
inline float2 fx_distort_fromAspect(float2 d, float aspect) {
    return float2(d.x / aspect, d.y);
}

// MARK: - Warp (center, amount): radial sinusoidal warp

fragment float4 fx_distort_warp(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 center = float2(u.params[0], u.params[1]);
    float amount = u.params[2];

    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r = length(d);
    float2 dir = r > 1.0e-5 ? d / r : float2(0.0);
    // Concentric sinusoidal ridges that push samples in/out along the radius.
    float wave = sin(r * 28.0) * amount * 0.06;
    float2 offset = fx_distort_fromAspect(dir * wave, aspect);
    float2 uv = in.uv + offset;

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Bulge (center, radius, amount): magnify outward

fragment float4 fx_distort_bulge(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 center = float2(u.params[0], u.params[1]);
    float radius = max(u.params[2], 1.0e-3);
    float amount = u.params[3];

    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r = length(d);
    float t = clamp(r / radius, 0.0, 1.0);
    // Falloff that is 1 at the center, 0 at the radius edge.
    float falloff = 1.0 - smoothstep(0.0, 1.0, t);
    // Pull samples toward the center to magnify the interior.
    float scale = 1.0 - amount * falloff;
    float2 nd = d * scale;
    float2 uv = center + fx_distort_fromAspect(nd, aspect);

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Pinch (center, radius, amount): squeeze inward

fragment float4 fx_distort_pinch(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 center = float2(u.params[0], u.params[1]);
    float radius = max(u.params[2], 1.0e-3);
    float amount = u.params[3];

    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r = length(d);
    float t = clamp(r / radius, 0.0, 1.0);
    float falloff = 1.0 - smoothstep(0.0, 1.0, t);
    // Push samples away from the center to shrink the interior (the inverse of
    // bulge): with amount > 0 the image squeezes toward the center point.
    float scale = 1.0 + amount * falloff;
    float2 nd = d * scale;
    float2 uv = center + fx_distort_fromAspect(nd, aspect);

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Fish Eye (amount): strong barrel

fragment float4 fx_distort_fishEye(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float amount = u.params[0];

    float2 center = float2(0.5, 0.5);
    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r = length(d);
    // Spherize: map planar radius to a fisheye radius. amount in [0,1].
    float k = amount * 1.2;
    float rn = r * (1.0 + k * (r * r - 1.0));
    float2 dir = r > 1.0e-5 ? d / r : float2(0.0);
    float2 nd = dir * rn;
    float2 uv = center + fx_distort_fromAspect(nd, aspect);

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Barrel Distortion (k1, k2): lens barrel/pincushion

fragment float4 fx_distort_barrel(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float k1 = u.params[0];
    float k2 = u.params[1];

    float2 center = float2(0.5, 0.5);
    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r2 = dot(d, d);
    // Brown-Conrady radial model. Positive k => barrel, negative => pincushion.
    float factor = 1.0 + k1 * r2 + k2 * r2 * r2;
    float2 nd = d * factor;
    float2 uv = center + fx_distort_fromAspect(nd, aspect);

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Chromatic Distortion (amount): per-channel radial scale (RGB fringing)

fragment float4 fx_distort_chromatic(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float amount = u.params[0];

    float2 center = float2(0.5, 0.5);
    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r2 = dot(d, d);
    // Each channel uses a slightly different radial scale; fringing grows with
    // radius so edges separate more than the center.
    float spread = amount * 0.15 * clamp(u.strength, 0.0, 1.0);   // strength scales fringing
    float2 dr = fx_distort_fromAspect(d * (1.0 + spread * r2), aspect);
    float2 db = fx_distort_fromAspect(d * (1.0 - spread * r2), aspect);
    float red = spectra_tex(src, center + dr).r;
    float green = spectra_tex(src, in.uv).g;
    float blue = spectra_tex(src, center + db).b;

    float3 c = float3(red, green, blue);
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Heat Distortion (intensity, speed): animated noise warp

fragment float4 fx_distort_heat(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float t = u.time * speed;
    // Two decorrelated noise fields drive horizontal/vertical displacement; the
    // vertical bias mimics rising heat shimmer.
    float2 p = in.uv * float2(9.0, 14.0);
    float nx = spectra_simplex(p + float2(t * 1.3, t * 2.1));
    float ny = spectra_simplex(p + float2(31.4 - t * 1.7, 11.2 + t * 2.6));
    float2 offset = float2(nx, ny + 0.5) * intensity * 0.02;
    float2 uv = in.uv + offset;

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Wave (amplitude, frequency, speed): animated sine displacement

fragment float4 fx_distort_wave(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float amplitude = u.params[0];
    float frequency = u.params[1];
    float speed = u.params[2];

    float t = u.time * speed;
    // Cross-coupled sine displacement: vertical position drives horizontal shift
    // and vice versa for an organic ripple-cloth motion.
    float2 offset;
    offset.x = sin(in.uv.y * frequency * 6.28318530718 + t) * amplitude * 0.03;
    offset.y = cos(in.uv.x * frequency * 6.28318530718 + t * 1.3) * amplitude * 0.03;
    float2 uv = in.uv + offset;

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Ripple (center, amplitude, frequency, speed): animated concentric ripples

fragment float4 fx_distort_ripple(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 center = float2(u.params[0], u.params[1]);
    float amplitude = u.params[2];
    float frequency = u.params[3];
    float speed = u.params[4];

    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r = length(d);
    float2 dir = r > 1.0e-5 ? d / r : float2(0.0);
    // Outward-traveling concentric ripples that decay with distance.
    float phase = r * frequency * 6.28318530718 - u.time * speed;
    float decay = exp(-r * 2.5);
    float disp = sin(phase) * amplitude * 0.03 * decay;
    float2 offset = fx_distort_fromAspect(dir * disp, aspect);
    float2 uv = in.uv + offset;

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Swirl (center, angle, radius): rotate uv by angle falling off with radius

fragment float4 fx_distort_swirl(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 center = float2(u.params[0], u.params[1]);
    float angleDeg = u.params[2];
    float radius = max(u.params[3], 1.0e-3);

    float angle = angleDeg * 0.01745329252; // degrees -> radians
    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r = length(d);
    float t = clamp(r / radius, 0.0, 1.0);
    // Rotation strongest at the center, smoothly easing to zero at the radius.
    float falloff = 1.0 - smoothstep(0.0, 1.0, t);
    // Strength scales the rotation ANGLE (not the uv): a partial swirl is a smaller
    // twist. Lerping positions here would chord-interpolate the rotation, collapsing
    // the vortex radius (to zero at 180°) instead of spinning less.
    float2 rd = spectra_rotate(d, angle * falloff * clamp(u.strength, 0.0, 1.0));
    float2 uv = center + fx_distort_fromAspect(rd, aspect);

    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Shockwave (center, speed, width, amplitude): animated ring

fragment float4 fx_distort_shockwave(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 center = float2(u.params[0], u.params[1]);
    float speed = u.params[2];
    float width = max(u.params[3], 1.0e-3);
    float amplitude = u.params[4];

    float aspect = fx_distort_aspect(u);
    float2 d = fx_distort_toAspect(in.uv - center, aspect);
    float r = length(d);
    float2 dir = r > 1.0e-5 ? d / r : float2(0.0);
    // Ring radius expands with time and recycles so the wave repeats.
    float ringR = fract(u.time * speed * 0.25) * 1.4;
    float band = (r - ringR) / width;
    // A single positive/negative lobe centered on the ring (derivative of a
    // gaussian) gives the classic compress-then-expand shock profile.
    float pulse = band * exp(-band * band);
    float disp = pulse * amplitude * 0.08;
    float2 offset = fx_distort_fromAspect(dir * disp, aspect);
    float2 uv = in.uv + offset;

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Perspective Warp (horizontal, vertical): keystone-style uv skew

fragment float4 fx_distort_perspective(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float horizontal = u.params[0];
    float vertical = u.params[1];

    float2 p = in.uv - 0.5;
    // Keystone: scale each axis by a factor that varies linearly across the
    // opposite axis, producing a trapezoid (perspective) remap.
    float hk = 1.0 + horizontal * p.y * 2.0;
    float vk = 1.0 + vertical * p.x * 2.0;
    float2 np = float2(p.x * hk, p.y * vk);
    float2 uv = np + 0.5;

    // Strength scales the displacement (subtler warp), never a cross-fade with the
    // unwarped image — cross-fading a displaced image ghosts it into a double image.
    uv = mix(in.uv, uv, clamp(u.strength, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;
    return spectra_compositeFullRGBA(base, c, u);
}
