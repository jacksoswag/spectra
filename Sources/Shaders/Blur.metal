#include "SpectraCommon.h"

// Blur effects. Each fragment function samples the effect input on texture(0),
// the original (for compositing) on texture(1), reads parameters in declaration
// order from u.params[], and composites via spectra_compositeRGBA. Single-pass
// blurs use golden-angle disc sampling for even, artifact-free coverage with a
// bounded tap count. The separable Gaussian declares two passes and reads
// u.direction to orient its 1D kernel.

// Unit-direction spiral, float2(cos(a), sin(a)) for a = (i+0.5)·goldenAngle
// (goldenAngle = 2.39996322972865332).
// The angle depends only on the tap index, so it is a frame- and fragment-uniform
// constant table — baked here so the per-tap cos/sin disappear from the gather loops
// (verified: the Metal compiler does NOT hoist them out of the rolled loop). Holds
// only the unit direction (tap-count-independent); the per-tap radius keeps its cheap
// runtime sqrt, so one 48-entry table serves both the 48-tap and 32-tap callers.
constant float2 kBlurSpiralDir[48] = {
    float2(0.36237489, 0.93203242), float2(-0.89678282, -0.44247098), float2(0.96014460, -0.27950376),
    float2(-0.51917867, 0.85466573), float2(-0.19449222, -0.98090406), float2(0.80600368, 0.59191052),
    float2(-0.99415184, 0.10799126), float2(0.66010958, -0.75116932), float2(0.02066332, 0.99978649),
    float2(-0.69058256, -0.72325357), float2(0.99776486, 0.06682285), float2(-0.78085894, 0.62470738),
    float2(0.15379731, -0.98810242), float2(0.55404825, 0.83248456), float2(-0.97087317, -0.23959399),
    float2(0.87773508, -0.47914625), float2(-0.32355589, 0.94620906), float2(-0.40057500, -0.91626398),
    float2(0.91429896, 0.40504002), float2(-0.94777620, 0.31893617), float2(0.48342239, -0.87538723),
    float2(0.23485495, 0.97203043), float2(-0.82977185, -0.55810274), float2(0.98884093, -0.14897524),
    float2(-0.62850920, 0.77780215), float2(-0.06195468, -0.99807896), float2(0.71987611, 0.69410258),
    float2(-0.99967379, -0.02554031), float2(0.75438058, -0.65643731), float2(-0.11283973, 0.99361320),
    float2(-0.58797157, -0.80888159), float2(0.97994360, 0.19927502), float2(-0.85718826, 0.51500319),
    float2(0.28418429, -0.95876968), float2(0.43809096, 0.89893065), float2(-0.93025357, -0.36691729),
    float2(0.93378910, -0.35782387), float2(-0.44684047, 0.89461366), float2(-0.27481658, -0.96149667),
    float2(0.85212286, 0.52334179), float2(-0.98184118, 0.18970478), float2(0.59583539, -0.80310659),
    float2(0.10314023, 0.99466682), float2(-0.74794018, -0.66376614), float2(0.99987540, -0.01578584),
    float2(-0.72661381, 0.68704612), float2(0.07168943, -0.99742700), float2(0.62089070, 0.78389714),
};

// Sample a filled disc around `uv` using a fixed golden-angle spiral. The spiral
// distributes the bounded tap count evenly over the disc, so with enough taps the
// result is smooth — no per-pixel jitter, which would inject high-frequency noise
// instead of a clean blur. `radiusUV` is the disc radius in UV space.
inline float3 fx_blur_discSample(texture2d<float> src, float2 uv,
                                 float2 radiusUV, int taps) {
    float3 sum = spectra_tex(src, uv).rgb;
    float total = 1.0;
    float fTaps = float(taps);
    for (int i = 0; i < taps; i++) {
        float r = sqrt((float(i) + 0.5) / fTaps);
        float2 offset = kBlurSpiralDir[i] * r;
        sum += spectra_tex(src, uv + offset * radiusUV).rgb;
        total += 1.0;
    }
    return sum / total;
}

// MARK: - Gaussian Blur (downsample → separable blur → upsample)
//
// A large-radius blur sampled directly at full resolution would need hundreds of
// taps; a bounded tap count spaced across the radius undersamples sharp edges and
// produces structured "noise". Instead the blur runs at half resolution: a box
// downsample pre-averages detail, the separable Gaussian then covers the (halved)
// radius densely with few taps, and a final pass bilinearly upsamples and
// composites. The result is smooth at any radius and cheaper.

// 4-tap box downsample of the full-resolution source into the half-resolution
// target (scale 0.5). Offsets are a quarter of the target texel = half a source
// texel, so the four taps cover the 2×2 source block under each target pixel.
fragment float4 fx_blur_downsample(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float2 o = u.texelSize * 0.25;
    float3 c = spectra_tex(src, in.uv + float2(-o.x, -o.y)).rgb
             + spectra_tex(src, in.uv + float2( o.x, -o.y)).rgb
             + spectra_tex(src, in.uv + float2(-o.x,  o.y)).rgb
             + spectra_tex(src, in.uv + float2( o.x,  o.y)).rgb;
    return float4(c * 0.25, 1.0);
}

// Shared 1D separable Gaussian, run on the half-resolution image. `dir` is the
// unit axis to sample along (float2(1,0) for H, float2(0,1) for V). The radius
// is scaled by the pass scale so the visual blur width matches the full-res
// radius, and densely sampled (≤1.3px apart in half-res space) for a smooth
// falloff.
inline float3 fx_blur_gaussian1D(texture2d<float> src, float2 uv,
                                 float2 dir, constant SpectraUniforms &u) {
    float radiusPx = max(u.params[0], 0.0) * max(u.passScale, 0.001);
    if (radiusPx < 0.5) { return spectra_tex(src, uv).rgb; }

    float sigma = max(radiusPx * 0.5, 1.0);
    float twoSigma2 = 2.0 * sigma * sigma;
    const int kMaxTaps = 24;                       // discrete taps per side (bounded)
    int taps = clamp(int(ceil(radiusPx)), 3, kMaxTaps);
    float spacing = radiusPx / float(taps);        // cover [0, radius] evenly

    float3 sum = spectra_tex(src, uv).rgb;         // centre, weight 1
    float wsum = 1.0;
    // Linear-sampling Gaussian: each adjacent pair of discrete taps is fetched in a
    // SINGLE bilinear read at their weight-averaged position. With a linear sampler
    // that read reconstructs the two-tap weighted sum, so this halves the texture
    // reads per side (~taps/2 instead of taps) for a visually identical blur.
    for (int i = 1; i <= kMaxTaps; i += 2) {
        if (i > taps) break;
        float d0 = float(i) * spacing;
        float w0 = exp(-d0 * d0 / twoSigma2);
        float d, w;
        if (i + 1 <= taps) {
            float d1 = float(i + 1) * spacing;
            float w1 = exp(-d1 * d1 / twoSigma2);
            w = w0 + w1;
            d = (w0 * d0 + w1 * d1) / w;           // weight-averaged sample position
        } else {
            d = d0; w = w0;                        // odd leftover tap, sampled singly
        }
        float2 o = dir * u.texelSize * d;
        sum += spectra_tex(src, uv + o).rgb * w;
        sum += spectra_tex(src, uv - o).rgb * w;
        wsum += 2.0 * w;
    }
    return sum / wsum;
}

// Horizontal and vertical half-resolution passes (intermediate, no composite).
// Each pass hardcodes its sampling axis so the separable blur is correct
// regardless of what u.direction carries from the descriptor.
fragment float4 fx_blur_gaussian_h(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    return float4(fx_blur_gaussian1D(src, in.uv, float2(1.0, 0.0), u), 1.0);
}

fragment float4 fx_blur_gaussian_v(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    return float4(fx_blur_gaussian1D(src, in.uv, float2(0.0, 1.0), u), 1.0);
}

// Final pass (full resolution): bilinearly upsample the blurred half-res result
// and composite against the original.
fragment float4 fx_blur_gaussian_up(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = spectra_tex(src, in.uv).rgb;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Lens Blur (disc bokeh)

// params[0] = radius (px)
// Half-resolution disc gather (intermediate; the shared upsample pass composites).
// Radius is scaled by the pass scale so the UV radius matches the full-res value.
fragment float4 fx_blur_lens(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float radiusPx = max(u.params[0], 0.0) * max(u.passScale, 0.001);
    float2 radiusUV = u.texelSize * radiusPx;
    float3 processed = fx_blur_discSample(src, in.uv, radiusUV, 48);
    return float4(processed, 1.0);
}

// MARK: - Directional Blur

// params[0] = angle (degrees), params[1] = length (px)
fragment float4 fx_blur_directional(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float angle = u.params[0] * 0.017453292519943295; // deg -> rad
    float lengthPx = max(u.params[1], 0.0);
    float2 dir = float2(cos(angle), sin(angle)) * u.texelSize * lengthPx;

    const int kHalf = 10;
    float3 sum = spectra_tex(src, in.uv).rgb;
    float total = 1.0;
    for (int i = 1; i <= kHalf; i++) {
        float t = float(i) / float(kHalf);
        float2 o = dir * t;
        sum += spectra_tex(src, in.uv + o).rgb;
        sum += spectra_tex(src, in.uv - o).rgb;
        total += 2.0;
    }
    float3 processed = sum / total;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Motion Blur (directional with trailing falloff)

// params[0] = angle (degrees), params[1] = amount (px)
fragment float4 fx_blur_motion(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float angle = u.params[0] * 0.017453292519943295; // deg -> rad
    float amountPx = max(u.params[1], 0.0);
    float2 dir = float2(cos(angle), sin(angle)) * u.texelSize * amountPx;

    const int kTaps = 16;
    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < kTaps; i++) {
        float t = float(i) / float(kTaps - 1);   // 0..1 trailing the motion
        float w = 1.0 - t * 0.85;                 // linear falloff along the trail
        sum += spectra_tex(src, in.uv - dir * t).rgb * w;
        total += w;
    }
    float3 processed = sum / max(total, 1.0e-4);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Zoom Blur

// params[0..1] = center point, params[2] = strength
fragment float4 fx_blur_zoom(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 center = float2(u.params[0], u.params[1]);
    float strength = max(u.params[2], 0.0);
    float2 dir = in.uv - center;

    const int kTaps = 18;
    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < kTaps; i++) {
        float t = float(i) / float(kTaps - 1);
        // Pull samples toward the center, scaled by strength.
        float scale = 1.0 - t * strength;
        float w = 1.0 - t * 0.5;
        sum += spectra_tex(src, center + dir * scale).rgb * w;
        total += w;
    }
    float3 processed = sum / max(total, 1.0e-4);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Bokeh Blur (disc with highlight boost)

// params[0] = radius (px), params[1] = intensity (highlight boost). Half-res
// intermediate; the shared upsample pass composites.
fragment float4 fx_blur_bokeh(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float radiusPx = max(u.params[0], 0.0) * max(u.passScale, 0.001);
    float intensity = max(u.params[1], 0.0);
    float2 radiusUV = u.texelSize * radiusPx;

    // Highlight-weighted disc gather: bright samples bloom into bokeh discs. Fixed
    // spiral (no per-pixel jitter) so the discs stay clean instead of noisy.
    const int kTaps = 48;
    float fTaps = float(kTaps);
    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < kTaps; i++) {
        float r = sqrt((float(i) + 0.5) / fTaps);
        float2 offset = kBlurSpiralDir[i] * r;
        float3 s = spectra_tex(src, in.uv + offset * radiusUV).rgb;
        float lum = spectra_luma(s);
        float w = 1.0 + intensity * pow(smoothstep(0.6, 1.0, lum), 2.0) * 4.0;
        sum += s * w;
        total += w;
    }
    float3 processed = sum / max(total, 1.0e-4);
    return float4(processed, 1.0);
}

// MARK: - Depth Blur (blur grows with distance from a focus band)

// params[0..1] = focus center point, params[2] = focus range, params[3] = strength
fragment float4 fx_blur_depth(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 focus = float2(u.params[0], u.params[1]);
    float range = max(u.params[2], 0.001);
    float strength = max(u.params[3], 0.0);

    // Radial "depth" proxy: distance from the focus point, in-focus inside range.
    float d = distance(in.uv, focus);
    float blurAmt = smoothstep(range, range + 0.5, d);

    float radiusPx = blurAmt * strength;
    float2 radiusUV = u.texelSize * radiusPx;
    float3 processed = fx_blur_discSample(src, in.uv, radiusUV, 32);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Tilt Shift (horizontal in-focus band)

// params[0] = focusY, params[1] = bandWidth, params[2] = strength
fragment float4 fx_blur_tiltShift(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float focusY = u.params[0];
    float bandWidth = max(u.params[1], 0.001);
    float strength = max(u.params[2], 0.0);

    // In-focus inside the band, ramping to full blur over a transition margin.
    float dist = abs(in.uv.y - focusY);
    float halfBand = bandWidth * 0.5;
    float blurAmt = smoothstep(halfBand, halfBand + bandWidth, dist);

    float radiusPx = blurAmt * strength;
    float2 radiusUV = u.texelSize * radiusPx;
    float3 processed = fx_blur_discSample(src, in.uv, radiusUV, 32);
    return spectra_compositeRGBA(base, processed, u);
}
