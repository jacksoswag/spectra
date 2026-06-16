#include "SpectraCommon.h"

// VHS tape effects. Magnetic-tape artifacts: tracking errors, wrinkles,
// dropouts, chroma drift, head-switching noise, jitter, roll, noise bands,
// damage, generation loss and color smear.
//
// Each fragment function samples the effect input on texture(0), the original
// (for compositing) on texture(1), reads parameters in declaration order from
// u.params[], and composites via spectra_compositeRGBA.

// MARK: - Category helpers

// Smooth pseudo-random walk in [-1,1] driven by a continuous coordinate. Used to
// give tracking / wrinkle bands an organic, non-repeating drift.
inline float fx_vhs_drift(float x) {
    return spectra_valueNoise(float2(x, 0.0)) * 2.0 - 1.0;
}

// Synthesized audio envelope from time: a few detuned sines rectified into a
// pulsing 0..1 signal that feels like a music transient hitting the tape.
inline float fx_vhs_audioEnv(float t) {
    float a = sin(t * 8.0) * 0.5 + 0.5;
    float b = sin(t * 13.3 + 1.7) * 0.5 + 0.5;
    float beat = pow(max(sin(t * 2.0), 0.0), 6.0);
    float env = a * 0.35 + b * 0.25 + beat * 0.7;
    return clamp(env, 0.0, 1.0);
}

// MARK: - Tracking Errors

fragment float4 fx_vhs_tracking(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float speed = u.params[1];
    // Fold strength into the displacement (and the noise), then composite at full:
    // cross-fading a *displaced* image back over the original ghosts it into a
    // doubled, jittery band — the "unwarped screen showing through" look. Scaling
    // the geometry by strength keeps the warp clean and proportional instead.
    float strength = clamp(u.strength, 0.0, 1.0);

    float3 base = spectra_tex(orig, in.uv).rgb;

    // A tracking band that drifts vertically over time.
    float bandY = fract(u.time * speed * 0.15 + u.seed);
    float dist = abs(in.uv.y - bandY);
    float band = smoothstep(0.18, 0.0, dist);

    // Within the band the line is shoved sideways by a noisy amount.
    float n = fx_vhs_drift(in.uv.y * 24.0 + u.time * speed * 4.0);
    float shift = n * band * intensity * 0.05 * strength;

    float2 uv = in.uv;
    uv.x += shift;
    float3 c = spectra_tex(src, uv).rgb;

    // Add a faint horizontal noise smear inside the band core.
    float core = smoothstep(0.04, 0.0, dist);
    float grain = spectra_hash21(float2(in.uv.y * 700.0, u.time * 60.0));
    c = mix(c, float3(grain), core * intensity * 0.5 * strength);

    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Tape Wrinkle

fragment float4 fx_vhs_wrinkle(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float position = u.params[1];
    float speed = u.params[2];
    float strength = clamp(u.strength, 0.0, 1.0);   // fold into geometry, not a cross-fade

    float3 base = spectra_tex(orig, in.uv).rgb;

    float center = position + sin(u.time * speed) * 0.02;
    float dist = abs(in.uv.y - center);
    float band = smoothstep(0.09, 0.0, dist);

    // A warped horizontal band: vertical pinch plus a wavy horizontal slip.
    float wave = sin(in.uv.x * 18.0 + u.time * speed * 3.0) * 0.5
               + sin(in.uv.x * 47.0 - u.time * speed * 2.0) * 0.5;
    float2 uv = in.uv;
    uv.x += wave * band * intensity * 0.05 * strength;
    uv.y += band * intensity * 0.03 * sign(in.uv.y - center) * strength;

    float3 c = spectra_tex(src, uv).rgb;

    // Bright tape-stretch streak at the crease.
    float crease = smoothstep(0.02, 0.0, dist);
    c += crease * intensity * 0.35 * strength;

    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Dropouts

fragment float4 fx_vhs_dropouts(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float density = u.params[0];
    float speed = u.params[1];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    // Quantize to scanlines; each line gets a moving streak chance.
    float line = floor(in.uv.y * u.resolution.y / 3.0);
    float t = floor(u.time * speed * 12.0);
    float seedLine = spectra_hash21(float2(line, t) + u.seed);

    if (seedLine < density * 0.4) {
        // A horizontal streak of random start/length on this line.
        float start = spectra_hash21(float2(line * 1.7, t));
        float len = 0.04 + spectra_hash21(float2(line * 3.1, t)) * 0.25;
        float inStreak = step(start, in.uv.x) * step(in.uv.x, start + len);
        // White or black dropout.
        float white = step(0.5, spectra_hash21(float2(line * 5.3, t)));
        float3 dropColor = white > 0.5 ? float3(1.0) : float3(0.02);
        c = mix(c, dropColor, inStreak);
    }

    return spectra_compositeRGBA(base, c, u);
}

// MARK: - Chromatic Drift

fragment float4 fx_vhs_chromaDrift(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float amount = u.params[0];

    float3 base = spectra_tex(orig, in.uv).rgb;

    float off = amount * 0.02;
    // Luma from the centered sample; chroma pulled from a horizontally offset
    // sample, mimicking the displaced color-under signal of VHS.
    float3 cCenter = spectra_tex(src, in.uv).rgb;
    float3 cLeft = spectra_tex(src, in.uv - float2(off, 0.0)).rgb;
    float3 cRight = spectra_tex(src, in.uv + float2(off, 0.0)).rgb;

    float luma = spectra_luma(cCenter);
    float3 chromaSrc = (cLeft + cRight) * 0.5;
    float3 chromaYiq = spectra_rgb2yiq(chromaSrc);
    float3 outYiq = float3(luma, chromaYiq.y, chromaYiq.z);
    float3 c = spectra_yiq2rgb(outYiq);

    return spectra_compositeRGBA(base, c, u);
}

// MARK: - Head Switching Noise

fragment float4 fx_vhs_headSwitch(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float height = u.params[0];
    float intensity = u.params[1];
    float strength = clamp(u.strength, 0.0, 1.0);   // fold into geometry, not a cross-fade

    float3 base = spectra_tex(orig, in.uv).rgb;

    // Torn, noisy strip pinned to the bottom of the frame.
    float edge = height;
    float inStrip = smoothstep(edge, edge - 0.005, in.uv.y);

    // The tear: rows below the edge are slipped horizontally by a per-row offset
    // that grows toward the very bottom.
    float depth = saturate((edge - in.uv.y) / max(edge, 1e-4));
    float rowNoise = fx_vhs_drift(in.uv.y * 60.0 + u.time * 30.0);
    float2 uv = in.uv;
    uv.x += rowNoise * depth * 0.15 * inStrip * strength;

    float3 c = spectra_tex(src, uv).rgb;

    // Static hash noise blended into the strip, strongest at the bottom.
    float grain = spectra_hash21(float2(in.uv.x * 900.0, in.uv.y * 900.0 + u.time * 90.0));
    float noiseMix = inStrip * intensity * (0.3 + depth * 0.7) * strength;
    c = mix(c, float3(grain), noiseMix);

    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Horizontal Jitter

fragment float4 fx_vhs_jitter(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float amount = u.params[0];
    float speed = u.params[1];
    float strength = clamp(u.strength, 0.0, 1.0);   // fold into geometry, not a cross-fade

    float3 base = spectra_tex(orig, in.uv).rgb;

    // Per-scanline horizontal shake. Each line picks an offset that updates over
    // time; a slow common term shifts the whole frame for a wobble feel.
    float line = floor(in.uv.y * u.resolution.y);
    float t = u.time * speed * 8.0;
    float perLine = (spectra_hash21(float2(line, floor(t))) - 0.5);
    float common = sin(u.time * speed * 11.0) * 0.5;
    float shift = (perLine + common) * amount * 0.03 * strength;

    float2 uv = in.uv;
    uv.x += shift;
    float3 c = spectra_tex(src, uv).rgb;

    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Vertical Roll

fragment float4 fx_vhs_roll(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float speed = u.params[0];
    float strength = clamp(u.strength, 0.0, 1.0);   // fold into geometry, not a cross-fade

    float3 base = spectra_tex(orig, in.uv).rgb;

    // Wrap-sample so the image scrolls vertically and rejoins seamlessly.
    float roll = u.time * speed * 0.2 * strength;
    float2 uv = float2(in.uv.x, fract(in.uv.y + roll));
    float3 c = spectra_texWrap(src, uv).rgb;

    // A dim seam bar where the picture wraps, like a vertical-hold tear.
    float seam = fract(in.uv.y + roll);
    float bar = smoothstep(0.012, 0.0, seam) + smoothstep(0.012, 0.0, 1.0 - seam);
    c *= 1.0 - bar * 0.6 * strength;

    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Noise Bands

fragment float4 fx_vhs_noiseBands(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float count = u.params[1];
    float speed = u.params[2];

    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    // Several soft horizontal bands sliding upward.
    float n = max(1.0, floor(count + 0.5));
    float phase = in.uv.y * n - u.time * speed;
    float band = pow(0.5 + 0.5 * sin(phase * 6.28318530718), 4.0);

    float grain = spectra_hash21(float2(in.uv.x * 800.0, in.uv.y * 800.0 + u.time * 70.0));
    float3 noisy = mix(c, float3(grain), 0.85);

    c = mix(c, noisy, band * intensity);

    return spectra_compositeRGBA(base, c, u);
}

// MARK: - Tape Damage

fragment float4 fx_vhs_damage(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float speed = u.params[1];
    float strength = clamp(u.strength, 0.0, 1.0);   // fold into geometry, not a cross-fade

    float3 base = spectra_tex(orig, in.uv).rgb;

    // Combined: a roaming tear band shifts lines, dropouts punch streaks, and a
    // general grain rides over everything.
    float bandY = fract(u.time * speed * 0.1 + u.seed);
    float dist = abs(in.uv.y - bandY);
    float tear = smoothstep(0.07, 0.0, dist);
    float n = fx_vhs_drift(in.uv.y * 30.0 + u.time * speed * 5.0);

    float2 uv = in.uv;
    uv.x += n * tear * intensity * 0.12 * strength;
    float3 c = spectra_tex(src, uv).rgb;

    // Dropouts.
    float line = floor(in.uv.y * u.resolution.y / 2.0);
    float t = floor(u.time * speed * 14.0);
    float seedLine = spectra_hash21(float2(line, t) + u.seed);
    if (seedLine < intensity * 0.25) {
        float start = spectra_hash21(float2(line * 2.3, t));
        float len = 0.03 + spectra_hash21(float2(line * 4.7, t)) * 0.2;
        float inStreak = step(start, in.uv.x) * step(in.uv.x, start + len);
        float white = step(0.5, spectra_hash21(float2(line * 6.1, t)));
        c = mix(c, white > 0.5 ? float3(1.0) : float3(0.0), inStreak * strength);
    }

    // Overall grain.
    float grain = spectra_hash21(float2(in.uv * u.resolution * 0.5 + u.time * 50.0));
    c = mix(c, c * (0.7 + grain * 0.6), intensity * 0.4 * strength);

    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Generation Loss (not animated)

fragment float4 fx_vhs_genLoss(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float amount = u.params[0];

    float3 base = spectra_tex(orig, in.uv).rgb;

    float2 px = u.texelSize;

    // Softening: small horizontal blur (tape loses high-frequency luma).
    float blurSpan = amount * 2.5;
    float3 soft = spectra_tex(src, in.uv).rgb * 0.4;
    soft += spectra_tex(src, in.uv + float2(px.x * blurSpan, 0.0)).rgb * 0.24;
    soft += spectra_tex(src, in.uv - float2(px.x * blurSpan, 0.0)).rgb * 0.24;
    soft += spectra_tex(src, in.uv + float2(px.x * blurSpan * 2.0, 0.0)).rgb * 0.06;
    soft += spectra_tex(src, in.uv - float2(px.x * blurSpan * 2.0, 0.0)).rgb * 0.06;

    // Chroma bleed: pull chroma from a wider horizontal smear, keep luma sharp-ish.
    float lumaC = spectra_luma(soft);
    float chromaSpan = amount * 6.0;
    float3 cl = spectra_tex(src, in.uv - float2(px.x * chromaSpan, 0.0)).rgb;
    float3 cr = spectra_tex(src, in.uv + float2(px.x * chromaSpan, 0.0)).rgb;
    float3 chromaYiq = spectra_rgb2yiq((cl + cr) * 0.5);
    float3 bled = spectra_yiq2rgb(float3(lumaC, chromaYiq.yz));

    float3 c = mix(soft, bled, 0.6);

    // Slight desaturation.
    float l = spectra_luma(c);
    c = mix(c, float3(l), amount * 0.3);

    // Static noise (stable per-pixel, not animated).
    float grain = spectra_hash21(in.uv * u.resolution) - 0.5;
    c += grain * amount * 0.08;

    float3 processed = mix(spectra_tex(src, in.uv).rgb, c, saturate(amount));
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Color Smear

fragment float4 fx_vhs_smear(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float amount = u.params[0];

    float3 base = spectra_tex(orig, in.uv).rgb;

    float2 px = u.texelSize;
    float3 center = spectra_tex(src, in.uv).rgb;
    float luma = spectra_luma(center);

    // Accumulate chroma from samples trailing to the left (the smear lag).
    float span = amount * 14.0;
    float2 chromaAcc = float2(0.0);
    float wsum = 0.0;
    const int taps = 8;
    for (int i = 0; i < taps; i++) {
        float fi = float(i) / float(taps - 1);
        float w = 1.0 - fi;
        float3 s = spectra_tex(src, in.uv - float2(px.x * span * fi, 0.0)).rgb;
        chromaAcc += spectra_rgb2yiq(s).yz * w;
        wsum += w;
    }
    float2 chroma = chromaAcc / max(wsum, 1e-4);

    float3 c = spectra_yiq2rgb(float3(luma, chroma));

    return spectra_compositeRGBA(base, c, u);
}

// MARK: - Audio-Reactive Tracking

fragment float4 fx_vhs_audioTracking(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float speed = u.params[1];
    float strength = clamp(u.strength, 0.0, 1.0);   // fold into geometry, not a cross-fade

    float3 base = spectra_tex(orig, in.uv).rgb;

    float env = fx_vhs_audioEnv(u.time * speed);

    // Tracking band whose strength pulses with the audio envelope.
    float bandY = fract(u.time * speed * 0.12 + u.seed);
    float dist = abs(in.uv.y - bandY);
    float band = smoothstep(0.2, 0.0, dist);

    float n = fx_vhs_drift(in.uv.y * 26.0 + u.time * speed * 6.0);
    float pulse = intensity * (0.25 + env * 1.2);
    float shift = n * band * pulse * 0.07 * strength;

    float2 uv = in.uv;
    uv.x += shift;
    // Whole-frame vertical nudge on strong transients.
    uv.y += env * env * pulse * 0.01 * strength;

    float3 c = spectra_tex(src, uv).rgb;

    // Noise burst inside the band scaled by the envelope.
    float core = smoothstep(0.05, 0.0, dist);
    float grain = spectra_hash21(float2(in.uv.y * 650.0, u.time * 80.0));
    c = mix(c, float3(grain), core * pulse * env * 0.6 * strength);

    return spectra_compositeFullRGBA(base, c, u);
}
