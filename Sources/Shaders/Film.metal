#include "SpectraCommon.h"

// Film effects. Each fragment function samples the effect input on texture(0),
// the original (for compositing) on texture(1), reads parameters in declaration
// order from u.params[], and composites via spectra_compositeRGBA. Animated
// effects (grain, dust, scratches, weave, leaks, flicker, burn) drive their
// variation from u.time and u.seed. Helpers below are 'inline' and prefixed with
// the category key to avoid link collisions in the shared metallib.

// MARK: - Shared film helpers

// Animated, signed luminance grain in [-1, 1]. Grain cells scale with `size`
// (larger size = chunkier grain). The time term advances the noise field so it
// resamples each frame, matching real emulsion shimmer.
inline float fx_film_grainField(float2 uv, float2 resolution, float size,
                                float time, float seed, float rate) {
    float cell = max(size, 0.25);
    float2 gp = (uv * resolution) / cell;
    // Quantize time so the grain pattern resamples on a stable cadence of `rate`
    // resamples/second rather than smearing continuously. A lower rate gives slow,
    // gently evolving grain (e.g. a disposable-camera look); 24 matches projector
    // shimmer.
    float t = floor(time * max(rate, 0.05));
    float2 jitter = float2(t * 1.7 + seed * 91.3, t * 2.3 + seed * 53.7);
    return spectra_gaussianNoise(gp + jitter);
}

// Soft highlight mask used by halation and bloom. Returns 0 below `threshold`,
// ramping to 1 as luma approaches white.
inline float fx_film_highlightMask(float3 c, float threshold) {
    float l = spectra_luma(c);
    return smoothstep(threshold, min(threshold + 0.35, 1.0), l);
}

// Radial blur of the highlight mask, weighting bright neighbours. Used to spread
// a glow around blown-out regions. `radiusUV` is the spread radius in UV space.
inline float3 fx_film_glowGather(texture2d<float> src, float2 uv,
                                 float2 radiusUV, float threshold) {
    const float golden = 2.39996322972865332;
    const int taps = 24;
    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < taps; i++) {
        float fi = float(i) + 0.5;
        float r = sqrt(fi / float(taps));
        float a = fi * golden;
        float2 o = float2(cos(a), sin(a)) * r * radiusUV;
        float3 s = spectra_tex(src, uv + o).rgb;
        float w = fx_film_highlightMask(s, threshold) * (1.0 - r * 0.5);
        sum += s * w;
        total += w;
    }
    return total > 1.0e-4 ? sum / total : float3(0.0);
}

// MARK: - 16mm

// Heavier grain, gate weave, and a punchy contrast curve. The weave is a slow
// low-frequency drift of the sampling uv to mimic the film transport wobble of a
// 16mm gate.
fragment float4 fx_film_16mm(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float grainAmt = u.params[0];
    float weaveAmt = u.params[1];
    float contrast = u.params[2];

    float t = u.time;
    float2 weave = float2(
        spectra_simplex(float2(t * 0.6 + u.seed * 17.0, 3.1)) * 1.4,
        spectra_simplex(float2(t * 0.9 + u.seed * 41.0, 8.7)));
    float2 weaveUV = in.uv + weave * weaveAmt * 0.012;

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, weaveUV).rgb;

    // Slightly warm, contrasty 16mm transfer.
    c = (c - 0.5) * (1.0 + contrast) + 0.5;
    c = pow(max(c, 0.0), float3(0.96, 0.98, 1.04));

    float g = fx_film_grainField(in.uv, u.resolution, 2.4, t, u.seed, 24.0);
    float lumaResp = mix(0.6, 1.0, 1.0 - spectra_luma(c)); // more grain in shadows
    float3 processed = clamp(c + g * grainAmt * 0.16 * lumaResp, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - 35mm

// Classic cinema look: fine grain plus warm halation glow around highlights.
fragment float4 fx_film_35mm(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float grainAmt = u.params[0];
    float halationAmt = u.params[1];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    // Gentle filmic toe/shoulder.
    c = (c - 0.5) * 1.06 + 0.5;
    c = pow(max(c, 0.0), float3(0.99, 1.0, 1.02));

    // Warm halation bleed.
    float2 radius = u.texelSize * 9.0;
    float3 glow = fx_film_glowGather(src, in.uv, radius, 0.62);
    float3 halaTint = float3(1.0, 0.55, 0.32);
    c += glow * halaTint * halationAmt * 0.6;

    float g = fx_film_grainField(in.uv, u.resolution, 1.6, u.time, u.seed, 24.0);
    float3 processed = clamp(c + g * grainAmt * 0.1, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - 70mm

// Large-format clean look: very low grain, rich saturation and contrast.
fragment float4 fx_film_70mm(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float grainAmt = u.params[0];
    float richness = u.params[1];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    // Richness lifts saturation and local contrast subtly.
    float l = spectra_luma(c);
    c = mix(float3(l), c, 1.0 + richness * 0.4);
    c = (c - 0.5) * (1.0 + richness * 0.25) + 0.5;

    float g = fx_film_grainField(in.uv, u.resolution, 1.1, u.time, u.seed, 24.0);
    float3 processed = clamp(c + g * grainAmt * 0.05, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Kodak

// Warm color science: warm highlights, teal-leaning shadows, gentle s-curve.
fragment float4 fx_film_kodak(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float amount = u.params[0];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float l = spectra_luma(c);
    float hi = smoothstep(0.5, 1.0, l);
    float sh = 1.0 - smoothstep(0.0, 0.5, l);

    float3 graded = c;
    graded += float3(0.06, 0.025, -0.04) * hi;   // warm highlights
    graded += float3(-0.03, 0.01, 0.05) * sh;    // teal shadows
    graded = (graded - 0.5) * 1.05 + 0.5;        // light s-curve
    graded = mix(float3(spectra_luma(graded)), graded, 1.06); // a touch of pop

    float3 processed = clamp(mix(c, graded, amount), 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Fuji

// Cooler, greener color science with protected, slightly muted skin range.
fragment float4 fx_film_fuji(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float amount = u.params[0];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float l = spectra_luma(c);
    float hi = smoothstep(0.5, 1.0, l);
    float sh = 1.0 - smoothstep(0.0, 0.5, l);

    float3 graded = c;
    graded += float3(-0.03, 0.04, 0.0) * hi;     // green-cool highlights
    graded += float3(-0.02, 0.0, 0.04) * sh;     // cool shadows
    graded.g += 0.015;                           // overall green bias
    graded = (graded - 0.5) * 1.04 + 0.5;
    graded = mix(float3(spectra_luma(graded)), graded, 0.97); // gentle desat

    float3 processed = clamp(mix(c, graded, amount), 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Film Grain

// Animated luminance grain with adjustable intensity and grain size.
fragment float4 fx_film_grain(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float size = u.params[1];
    float speed = u.params[2];
    // Resample rate in Hz: speed 1 = 24Hz (projector shimmer), lower = slow evolve.
    float rate = mix(1.0, 24.0, clamp(speed, 0.0, 1.0));

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float g = fx_film_grainField(in.uv, u.resolution, size, u.time, u.seed, rate);
    // Grain is most visible in midtones, fading toward pure black/white.
    float l = spectra_luma(c);
    float vis = 1.0 - pow(abs(l - 0.5) * 2.0, 1.5);
    float3 processed = clamp(c + g * intensity * 0.2 * vis, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Dust

// Animated dust specks: sparse bright/dark flecks that flash and relocate over
// time, like debris on the film and gate.
fragment float4 fx_film_dust(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float density = u.params[0];
    float speed = u.params[1];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    // Frame-quantized time so specks pop per-frame rather than smear.
    float frame = floor(u.time * (6.0 + speed * 30.0));
    // Cell grid sized by density; more density = finer grid = more specks.
    float grid = mix(30.0, 140.0, clamp(density, 0.0, 1.0));
    float2 cell = floor(in.uv * grid);
    float2 f = fract(in.uv * grid);

    float3 speck = float3(0.0);
    // Hash decides if this cell carries a speck this frame.
    float roll = spectra_hash21(cell + frame * 1.31 + u.seed * 77.0);
    float thresh = mix(0.995, 0.93, clamp(density, 0.0, 1.0));
    if (roll > thresh) {
        float2 center = spectra_hash22(cell + frame * 2.17 + u.seed * 19.0);
        float d = distance(f, center);
        float radius = mix(0.06, 0.16, spectra_hash21(cell + frame));
        float speckShape = 1.0 - smoothstep(0.0, radius, d);
        // Mix of dark (dirt) and bright (lint) specks.
        float polarity = spectra_hash21(cell + frame * 3.7) > 0.5 ? 1.0 : -1.0;
        speck = float3(speckShape * polarity);
    }

    float3 processed = clamp(c + speck, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Scratches

// Animated vertical scratches that wander horizontally and flicker in and out,
// emulating emulsion damage running through the gate.
fragment float4 fx_film_scratches(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float density = u.params[0];
    float speed = u.params[1];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float t = u.time * (0.3 + speed);
    int count = int(mix(2.0, 14.0, clamp(density, 0.0, 1.0)));

    float scratch = 0.0;
    for (int i = 0; i < 14; i++) {
        if (i >= count) break;
        float fi = float(i);
        float id = fi + u.seed * 13.0;
        // Each scratch lives at a slowly drifting horizontal position.
        float baseX = spectra_hash11(id * 1.7);
        float drift = spectra_simplex(float2(t * 0.25 + id, id * 4.0)) * 0.04;
        float xPos = fract(baseX + drift);
        // Flicker the scratch on and off so it does not persist every frame.
        float life = spectra_simplex(float2(t * 0.8 + id * 3.0, id));
        float on = smoothstep(0.2, 0.6, life);
        float dx = abs(in.uv.x - xPos);
        float width = mix(0.0006, 0.002, spectra_hash11(id * 5.3));
        float line = 1.0 - smoothstep(0.0, width, dx);
        scratch = max(scratch, line * on);
    }

    // Scratches read as bright emulsion lines, slightly desaturating.
    float3 processed = clamp(c + scratch * 0.5, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Gate Weave

// Animated uv jitter: combined vertical and horizontal weave plus a faint
// per-frame jump, the signature unsteadiness of a film gate.
fragment float4 fx_film_gateWeave(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float amount = u.params[0];
    float speed = u.params[1];

    float t = u.time * (0.5 + speed);
    float2 weave = float2(
        spectra_simplex(float2(t * 0.7 + u.seed * 23.0, 1.3)),
        spectra_simplex(float2(t * 1.1 + u.seed * 47.0, 6.9)) * 1.6);
    // Occasional sharp per-frame jump on top of the smooth weave.
    float frame = floor(t * 24.0);
    float jump = (spectra_hash11(frame + u.seed * 31.0) - 0.5) * 0.3;
    weave.y += jump;

    float2 weaveUV = in.uv + weave * amount * 0.02;

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 processed = spectra_tex(src, weaveUV).rgb;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Light Leaks

// Animated colored leak that breathes in from a chosen edge, drifting in hue and
// position over time like stray light striking the film.
fragment float4 fx_film_lightLeaks(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float position = u.params[1];   // 0..1 around the frame perimeter
    float speed = u.params[2];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float t = u.time * (0.2 + speed * 0.8);

    // Map `position` to a point on the perimeter and an inward direction.
    float ang = position * 6.28318530718 + u.seed * 6.28318530718;
    float2 dir = float2(cos(ang), sin(ang));
    float2 source = float2(0.5) + dir * 0.65;

    // Distance from the leak source, modulated by slow noise for an organic edge.
    float2 d = in.uv - source;
    float dist = length(d);
    float wobble = spectra_simplex(float2(t * 0.6, dot(in.uv, float2(2.3, 1.7)) + t * 0.3));
    float falloff = smoothstep(1.1, 0.1, dist + wobble * 0.18);

    // Breathing pulse and drifting warm hue.
    float pulse = 0.6 + 0.4 * sin(t * 1.3 + u.seed * 10.0);
    float hue = fract(0.04 + 0.08 * sin(t * 0.5) + position * 0.1);
    float3 leakColor = spectra_hsv2rgb(float3(hue, 0.6, 1.0));

    float3 leak = leakColor * falloff * pulse * intensity;
    // Screen the leak over the image so highlights bloom naturally.
    float3 processed = 1.0 - (1.0 - c) * (1.0 - leak);
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - Glow pipeline (shared by Bloom and Halation)
//
// A soft highlight glow spreads bright pixels across a wide radius. Doing that
// with a sparse wide-radius tap gather undersamples the disc and leaves visible
// spiral speckle that shimmers as content moves — the artifact this pipeline
// replaces. Instead the glow is built like the Gaussian blur: extract and
// pre-average highlights into a half-resolution buffer, run a dense separable
// Gaussian over it, then upsample and composite. Dense sampling at reduced
// resolution is both artifact-free and cache-friendly.

// On-screen glow radius in full-resolution pixels. The blur passes scale this by
// their pass scale so the half-res Gaussian covers the same spread densely.
constant float kFilmGlowRadius = 26.0;

// Soft-knee highlight extraction. Below `threshold` the output is black; the knee
// ramps contribution in smoothly so there is no hard edge (which would band and
// pulse as highlights cross the threshold).
inline float3 fx_film_prefilterHighlights(float3 c, float threshold) {
    float knee = max(threshold, 1.0e-3) * 0.5;
    float br = max(c.r, max(c.g, c.b));
    float soft = clamp(br - threshold + knee, 0.0, 2.0 * knee);
    soft = (soft * soft) / (4.0 * knee + 1.0e-4);
    float contribution = max(soft, br - threshold) / max(br, 1.0e-4);
    return c * max(contribution, 0.0);
}

// Pass 1 (half-res): box-downsample the full-res source with a Karis luma weight,
// then extract highlights. The Karis weight (1/(1+luma)) keeps an isolated very
// bright pixel from dominating its 2×2 block, which would otherwise make the
// bloom flicker ("fireflies"). params[0] = threshold.
fragment float4 fx_film_glow_prefilter(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]]) {
    float threshold = u.params[0];
    // Four taps at ±0.5 source texels cover the 2×2 source block under this pixel.
    float2 o = u.texelSize * 0.25;
    float3 s0 = spectra_tex(src, in.uv + float2(-o.x, -o.y)).rgb;
    float3 s1 = spectra_tex(src, in.uv + float2( o.x, -o.y)).rgb;
    float3 s2 = spectra_tex(src, in.uv + float2(-o.x,  o.y)).rgb;
    float3 s3 = spectra_tex(src, in.uv + float2( o.x,  o.y)).rgb;
    float w0 = 1.0 / (1.0 + spectra_luma(s0));
    float w1 = 1.0 / (1.0 + spectra_luma(s1));
    float w2 = 1.0 / (1.0 + spectra_luma(s2));
    float w3 = 1.0 / (1.0 + spectra_luma(s3));
    float3 avg = (s0 * w0 + s1 * w1 + s2 * w2 + s3 * w3) / (w0 + w1 + w2 + w3);
    return float4(fx_film_prefilterHighlights(avg, threshold), 1.0);
}

// Shared separable Gaussian over the half-res highlight buffer. `u.direction`
// orients the 1D kernel; the radius is fixed (kFilmGlowRadius, scaled by the pass
// scale) and densely sampled (≤1px apart in this pass's space) for a smooth,
// speckle-free falloff.
inline float3 fx_film_glowBlur1D(texture2d<float> src, float2 uv,
                                 constant SpectraUniforms &u) {
    float radiusPx = kFilmGlowRadius * max(u.passScale, 0.001);
    float sigma = max(radiusPx * 0.5, 1.0);
    float twoSigma2 = 2.0 * sigma * sigma;
    const int kMaxTaps = 20;                        // discrete taps per side (bounded)
    int taps = clamp(int(ceil(radiusPx)), 3, kMaxTaps);
    float spacing = radiusPx / float(taps);         // cover [0, radius] evenly
    float3 sum = spectra_tex(src, uv).rgb;          // centre, weight 1
    float wsum = 1.0;
    // Linear-sampling Gaussian: fetch each adjacent pair of taps in ONE bilinear
    // read at their weight-averaged position (halves texture reads, identical result
    // with a linear sampler). See fx_blur_gaussian1D for the full rationale.
    for (int i = 1; i <= kMaxTaps; i += 2) {
        if (i > taps) break;
        float d0 = float(i) * spacing;
        float w0 = exp(-d0 * d0 / twoSigma2);
        float d, w;
        if (i + 1 <= taps) {
            float d1 = float(i + 1) * spacing;
            float w1 = exp(-d1 * d1 / twoSigma2);
            w = w0 + w1;
            d = (w0 * d0 + w1 * d1) / w;
        } else {
            d = d0; w = w0;
        }
        float2 off = u.direction * u.texelSize * d;
        sum += spectra_tex(src, uv + off).rgb * w;
        sum += spectra_tex(src, uv - off).rgb * w;
        wsum += 2.0 * w;
    }
    return sum / wsum;
}

// Passes 2 & 3 (half-res): horizontal then vertical Gaussian over the highlights.
fragment float4 fx_film_glow_blur(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    return float4(fx_film_glowBlur1D(src, in.uv, u), 1.0);
}

// MARK: - Halation (prefilter → separable blur → warm combine)

// Final pass (full-res): tint the upsampled glow warm and add it onto the
// original, preserving full-resolution sharpness. params[1] = intensity.
fragment float4 fx_film_halation_combine(RasterizerData in [[stage_in]],
                                         texture2d<float> src [[texture(0)]],
                                         texture2d<float> orig [[texture(1)]],
                                         constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = max(u.params[1], 0.0);
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 glow = max(spectra_tex(src, in.uv).rgb, 0.0);
    float3 tint = float3(1.0, 0.45, 0.22);
    float3 processed = base + glow * tint * intensity;
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - Bloom (prefilter → separable blur → screen combine)

// Final pass (full-res): screen the upsampled, intensity-scaled glow over the
// original. params[1] = intensity.
fragment float4 fx_film_bloom_combine(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = max(u.params[1], 0.0);
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 glow = clamp(max(spectra_tex(src, in.uv).rgb, 0.0) * intensity, 0.0, 1.0);
    float3 processed = 1.0 - (1.0 - base) * (1.0 - glow);
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - Flicker

// Animated exposure flicker: a base wobble plus occasional dips, mimicking the
// unsteady brightness of a projector arc or aging stock.
fragment float4 fx_film_flicker(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float speed = u.params[1];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float t = u.time * (4.0 + speed * 16.0);
    // Layered sine wobble for an irregular flutter.
    float wob = sin(t) * 0.5 + sin(t * 2.37 + 1.7) * 0.3 + sin(t * 5.11 + 4.2) * 0.2;
    // Occasional deeper dip from frame-quantized noise.
    float frame = floor(t);
    float dip = spectra_hash11(frame + u.seed * 12.0);
    dip = smoothstep(0.85, 1.0, dip) * 0.6;

    float exposure = 1.0 + wob * intensity * 0.25 - dip * intensity;
    float3 processed = clamp(c * exposure, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Film Burn

// Animated burn: a moving hotspot blows out to white through an orange scorch
// ring, like a frame catching in a hot projector gate.
fragment float4 fx_film_burn(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float speed = u.params[1];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float t = u.time * (0.3 + speed * 0.7);

    // Hotspot wanders across the frame.
    float2 hot = float2(
        0.5 + 0.4 * sin(t * 0.9 + u.seed * 7.0),
        0.5 + 0.4 * cos(t * 0.7 + u.seed * 13.0));
    float2 d = in.uv - hot;
    float dist = length(d);

    // Ragged burn edge from noise so the front is irregular.
    float edge = spectra_fbm(in.uv * 6.0 + t * 0.5, 4) * 0.25;
    float burnRadius = (0.15 + 0.25 * (0.5 + 0.5 * sin(t * 1.1))) * (0.5 + intensity);
    float r = dist + edge;

    float core = 1.0 - smoothstep(0.0, burnRadius, r);            // blown-out core
    float ring = smoothstep(burnRadius * 1.4, burnRadius, r) * core; // scorch ring

    float3 scorch = float3(1.0, 0.42, 0.08);
    float3 processed = c;
    processed = mix(processed, scorch, ring * intensity);          // orange ring
    processed = mix(processed, float3(1.0), core * intensity);     // white core
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}
