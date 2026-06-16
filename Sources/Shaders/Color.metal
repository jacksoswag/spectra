#include "SpectraCommon.h"

// Color grading effects. Each fragment function samples the effect input on
// texture(0), the original (for compositing) on texture(1), reads parameters in
// declaration order from u.params[], and composites via spectra_compositeRGBA.
//
// The pointwise (single-tap) color ops below are factored into `colorproc_*`
// device functions that take the input colour and a pointer to this op's
// parameter slots. The standalone `fx_*` fragments call them, AND so does the
// fused interpreter `fx_color_fused` — so a run of consecutive pointwise colour
// effects collapses into ONE render pass (one read, one write) with output
// identical to running them as separate passes. See ResolvedEffect.fused / the
// chain resolver for the CPU side; opcodes MUST match `fusionOpcode` in
// ColorEffects.swift.

// MARK: - Pointwise colour ops (shared by fx_* and the fused interpreter)

inline float3 colorproc_brightness(float3 c, constant float *p) {
    return c + p[0];
}
inline float3 colorproc_contrast(float3 c, constant float *p) {
    return (c - 0.5) * (1.0 + p[0]) + 0.5;
}
inline float3 colorproc_saturation(float3 c, constant float *p) {
    float l = spectra_luma(c);
    return mix(float3(l), c, max(0.0, 1.0 + p[0]));
}
inline float3 colorproc_vibrance(float3 c, constant float *p) {
    float l = spectra_luma(c);
    float sat = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
    float boost = 1.0 + p[0] * (1.0 - sat) * 2.0;
    return mix(float3(l), c, max(0.0, boost));
}
inline float3 colorproc_exposure(float3 c, constant float *p) {
    return c * exp2(p[0]);
}
inline float3 colorproc_gamma(float3 c, constant float *p) {
    return pow(max(c, 0.0), 1.0 / max(p[0], 0.01));
}
inline float3 colorproc_highlights(float3 c, constant float *p) {
    float w = smoothstep(0.4, 1.0, spectra_luma(c));
    return c + p[0] * w * 0.5;
}
inline float3 colorproc_shadows(float3 c, constant float *p) {
    float w = 1.0 - smoothstep(0.0, 0.6, spectra_luma(c));
    return c + p[0] * w * 0.5;
}
inline float3 colorproc_whites(float3 c, constant float *p) {
    float w = smoothstep(0.65, 1.0, spectra_luma(c));
    return c * (1.0 + p[0] * w);
}
inline float3 colorproc_blacks(float3 c, constant float *p) {
    float w = 1.0 - smoothstep(0.0, 0.35, spectra_luma(c));
    return c + p[0] * w * 0.4;
}
inline float3 colorproc_blackPoint(float3 c, constant float *p) {
    float pt = min(p[0], 0.99);
    return clamp((c - pt) / (1.0 - pt), 0.0, 1.0);
}
inline float3 colorproc_whitePoint(float3 c, constant float *p) {
    return clamp(c / max(p[0], 0.01), 0.0, 1.0);
}
inline float3 colorproc_temperature(float3 c, constant float *p) {
    float t = p[0];
    float3 gain = float3(1.0 + 0.18 * t, 1.0 + 0.03 * t, 1.0 - 0.18 * t);
    float3 shifted = c * gain;
    float lin = spectra_luma(c), lout = max(spectra_luma(shifted), 1.0e-4);
    return shifted * mix(1.0, lin / lout, 0.6);
}
inline float3 colorproc_tint(float3 c, constant float *p) {
    float t = p[0];
    float3 gain = float3(1.0 + 0.12 * t, 1.0 - 0.12 * t, 1.0 + 0.12 * t);
    float3 shifted = c * gain;
    float lin = spectra_luma(c), lout = max(spectra_luma(shifted), 1.0e-4);
    return shifted * mix(1.0, lin / lout, 0.6);
}
inline float3 colorproc_sepia(float3 c, constant float *p) {
    float3 sepia = float3(
        dot(c, float3(0.393, 0.769, 0.189)),
        dot(c, float3(0.349, 0.686, 0.168)),
        dot(c, float3(0.272, 0.534, 0.131)));
    return mix(c, sepia, p[0]);
}
inline float3 colorproc_invert(float3 c, constant float *p) {
    return mix(c, 1.0 - c, p[0]);
}
inline float3 colorproc_posterize(float3 c, constant float *p) {
    float n = max(2.0, floor(p[0] + 0.5));
    return clamp(floor(c * n) / (n - 1.0), 0.0, 1.0);
}
inline float3 colorproc_solarize(float3 c, constant float *p) {
    return mix(c, 1.0 - c, step(p[0], c));
}
inline float3 colorproc_colorBalance(float3 c, constant float *p) {
    float l = spectra_luma(c);
    float shadowMask = 1.0 - smoothstep(0.0, 0.5, l);
    float highMask = smoothstep(0.5, 1.0, l);
    float midMask = max(0.0, 1.0 - abs(l - 0.5) * 2.0);
    float3 mid = float3(p[0], p[1], p[2]) * 0.5 * midMask;
    float3 sh  = float3(p[3], p[4], p[5]) * 0.5 * shadowMask;
    float3 hi  = float3(p[6], p[7], p[8]) * 0.5 * highMask;
    return c + mid + sh + hi;
}
inline float3 colorproc_levels(float3 c, constant float *p) {
    float inBlack = p[0];
    float inWhite = p[1];
    float gamma = max(p[2], 0.01);
    float outBlack = p[3];
    float outWhite = p[4];
    float3 normalized = clamp((c - inBlack) / max(inWhite - inBlack, 0.001), 0.0, 1.0);
    float3 corrected = pow(normalized, 1.0 / gamma);
    return outBlack + corrected * (outWhite - outBlack);
}
inline float3 colorproc_hueShift(float3 c, constant float *p) {
    float3 hsv = spectra_rgb2hsv(c);
    hsv.x = fract(hsv.x + p[0] / 360.0);
    return spectra_hsv2rgb(hsv);
}
inline float3 colorproc_channelMixer(float3 c, constant float *p) {
    return float3(
        dot(c, float3(p[0], p[1], p[2])),
        dot(c, float3(p[3], p[4], p[5])),
        dot(c, float3(p[6], p[7], p[8])));
}
inline float3 colorproc_toneCurve(float3 c, constant float *p) {
    float lift = p[0];
    float gamma = max(p[1], 0.01);
    float gain = p[2];
    float contrast = p[3];
    float3 x = c * gain + lift;
    x = pow(max(x, 0.0), 1.0 / gamma);
    return (x - 0.5) * (1.0 + contrast) + 0.5;
}

// Dispatch by opcode (matches fusionOpcode in ColorEffects.swift). An unknown
// opcode is a pass-through (the resolver only ever emits known opcodes).
inline float3 spectra_colorproc(int opcode, float3 c, constant float *p) {
    switch (opcode) {
        case 0:  return colorproc_brightness(c, p);
        case 1:  return colorproc_contrast(c, p);
        case 2:  return colorproc_saturation(c, p);
        case 3:  return colorproc_vibrance(c, p);
        case 4:  return colorproc_exposure(c, p);
        case 5:  return colorproc_gamma(c, p);
        case 6:  return colorproc_highlights(c, p);
        case 7:  return colorproc_shadows(c, p);
        case 8:  return colorproc_whites(c, p);
        case 9:  return colorproc_blacks(c, p);
        case 10: return colorproc_blackPoint(c, p);
        case 11: return colorproc_whitePoint(c, p);
        case 12: return colorproc_temperature(c, p);
        case 13: return colorproc_tint(c, p);
        case 14: return colorproc_sepia(c, p);
        case 15: return colorproc_invert(c, p);
        case 16: return colorproc_posterize(c, p);
        case 17: return colorproc_solarize(c, p);
        case 18: return colorproc_colorBalance(c, p);
        case 19: return colorproc_levels(c, p);
        case 20: return colorproc_hueShift(c, p);
        case 21: return colorproc_channelMixer(c, p);
        case 22: return colorproc_toneCurve(c, p);
        default: return c;
    }
}

// MARK: - Fused colour interpreter
//
// One render pass that applies a run of pointwise colour ops in sequence. The op
// list is a flat float buffer at buffer(1): [count, then per op a 16-float stride
// of (opcode, strength, opacity, blendAmount, blendMode, params[9], pad, pad)].
// Layout mirrors ResolvedEffect.fused in Swift.

constant int kFusedOpStride = 16;
constant int kFusedMaxOps = 16;

struct FusedColorOps {
    float count;
    float ops[256];   // kFusedOpStride * kFusedMaxOps
};

fragment float4 fx_color_fused(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]],
                               constant FusedColorOps &fused [[buffer(1)]]) {
    float3 c = spectra_tex(src, in.uv).rgb;
    int n = min(int(fused.count), kFusedMaxOps);
    for (int i = 0; i < n; i++) {
        int b = i * kFusedOpStride;
        int opcode = int(fused.ops[b + 0]);
        float strength = fused.ops[b + 1];
        float opacity = fused.ops[b + 2];
        float blendAmount = fused.ops[b + 3];
        float blendMode = fused.ops[b + 4];
        constant float *p = &fused.ops[b + 5];
        float3 processed = spectra_colorproc(opcode, c, p);
        c = spectra_compositeExplicit(c, processed, strength, opacity, blendAmount, blendMode);
    }
    return float4(c, 1.0);
}

// MARK: - Standalone pointwise colour fragments
//
// Each is a thin wrapper over its colorproc_* op so the standalone and fused
// paths can never diverge.

fragment float4 fx_brightness(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_brightness(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_contrast(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_contrast(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_saturation(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_saturation(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_vibrance(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_vibrance(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_exposure(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_exposure(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_gamma(RasterizerData in [[stage_in]],
                         texture2d<float> src [[texture(0)]],
                         texture2d<float> orig [[texture(1)]],
                         constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_gamma(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_highlights(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_highlights(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_shadows(RasterizerData in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           texture2d<float> orig [[texture(1)]],
                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_shadows(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_whites(RasterizerData in [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          texture2d<float> orig [[texture(1)]],
                          constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_whites(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_blacks(RasterizerData in [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          texture2d<float> orig [[texture(1)]],
                          constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_blacks(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_blackPoint(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_blackPoint(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_whitePoint(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_whitePoint(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_temperature(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_temperature(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_tint(RasterizerData in [[stage_in]],
                        texture2d<float> src [[texture(0)]],
                        texture2d<float> orig [[texture(1)]],
                        constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_tint(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_sepia(RasterizerData in [[stage_in]],
                         texture2d<float> src [[texture(0)]],
                         texture2d<float> orig [[texture(1)]],
                         constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_sepia(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_invert(RasterizerData in [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          texture2d<float> orig [[texture(1)]],
                          constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_invert(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_posterize(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_posterize(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_solarize(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_solarize(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_colorBalance(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_colorBalance(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_levels(RasterizerData in [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          texture2d<float> orig [[texture(1)]],
                          constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_levels(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_hueShift(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_hueShift(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_channelMixer(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_channelMixer(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

fragment float4 fx_toneCurve(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = colorproc_toneCurve(spectra_tex(src, in.uv).rgb, u.params);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Curves (1D LUT, texture 2)

// Applies an editable tone curve (baked to a 256×1 R16F lookup at texture 2) to
// each channel independently. No uniform params; the curve is the auxiliary
// texture, the universal strength controls intensity.
fragment float4 fx_color_curves(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                texture2d<float> curveLUT [[texture(2)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 processed = float3(
        curveLUT.sample(s, float2(clamp(c.r, 0.0, 1.0), 0.5)).r,
        curveLUT.sample(s, float2(clamp(c.g, 0.0, 1.0), 0.5)).r,
        curveLUT.sample(s, float2(clamp(c.b, 0.0, 1.0), 0.5)).r);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Color LUT (3D lookup, texture 2)

// Applies a 3D color lookup table (a built-in look baked to a 33³ RGBA texture
// at texture 2). params[0] = amount (mix toward the graded result).
fragment float4 fx_color_lut(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             texture3d<float> lut [[texture(2)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = clamp(spectra_tex(src, in.uv).rgb, 0.0, 1.0);
    float amount = u.params[0];
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    const float n = 33.0;
    float3 uvw = c * ((n - 1.0) / n) + (0.5 / n);   // avoid edge bias
    float3 graded = lut.sample(s, uvw).rgb;
    float3 processed = mix(c, graded, clamp(amount, 0.0, 1.0));
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Gradient Map (1D LUT, texture 2)

// Remaps luminance through an editable color gradient (baked to a 256×1 RGBA
// lookup at texture 2). params[0] = amount.
fragment float4 fx_color_gradientMap(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     texture2d<float> grad [[texture(2)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = u.params[0];
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float l = clamp(spectra_luma(c), 0.0, 1.0);
    float3 mapped = grad.sample(s, float2(l, 0.5)).rgb;
    float3 processed = mix(c, mapped, clamp(amount, 0.0, 1.0));
    return spectra_compositeRGBA(base, processed, u);
}
