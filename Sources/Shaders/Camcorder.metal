#include "SpectraCommon.h"

// Camcorder effects. Consumer-grade tape and digital handycam looks plus a
// fully procedural running-camcorder on-screen display. Each fragment function
// samples the effect input on texture(0), the original (for compositing) on
// texture(1), reads parameters in declaration order from u.params[], and
// composites via spectra_compositeRGBA.
//
// New helpers introduced here are marked `inline` and prefixed `fx_cam_` to
// avoid link collisions in the shared metallib.

// MARK: - Shared camcorder helpers

// Field-interlacing: alternate scan lines belong to fields captured 1/60s apart.
// We darken/offset the field that is "between frames" so motion shows a subtle
// comb while static areas stay clean. Returns a multiplier and a horizontal
// chroma smear offset (in uv) for the current row.
inline float fx_cam_fieldFactor(float2 uv, constant SpectraUniforms &u, float strength) {
    float row = uv.y * u.resolution.y;
    float field = step(0.5, fract(row * 0.5));            // 0 for even rows, 1 for odd
    // Which field is "active" this frame alternates at ~60Hz.
    float activeField = step(0.5, fract(u.time * 60.0));
    float inactive = abs(field - activeField);            // 1 when this row is the stale field
    float darken = 1.0 - inactive * 0.16 * strength;
    return darken;
}

// Unsharp-mask style sharpening using a small cross of taps.
inline float3 fx_cam_sharpen(texture2d<float> src, float2 uv, float2 texel, float amount) {
    float3 c = spectra_tex(src, uv).rgb;
    float3 blur = spectra_tex(src, uv + float2(texel.x, 0.0)).rgb
                + spectra_tex(src, uv - float2(texel.x, 0.0)).rgb
                + spectra_tex(src, uv + float2(0.0, texel.y)).rgb
                + spectra_tex(src, uv - float2(0.0, texel.y)).rgb;
    blur *= 0.25;
    return c + (c - blur) * amount;
}

// Tape-style horizontal chroma bleed: smear I/Q (color) to the right while
// keeping luma sharp, mimicking limited chroma bandwidth on analog tape.
inline float3 fx_cam_chromaBleed(texture2d<float> src, float2 uv, float2 texel, float amount) {
    float3 c = spectra_tex(src, uv).rgb;
    float3 yiq = spectra_rgb2yiq(c);
    float3 a = spectra_rgb2yiq(spectra_tex(src, uv - float2(texel.x * 2.0, 0.0)).rgb);
    float3 b = spectra_rgb2yiq(spectra_tex(src, uv - float2(texel.x * 4.0, 0.0)).rgb);
    float3 d = spectra_rgb2yiq(spectra_tex(src, uv - float2(texel.x * 6.0, 0.0)).rgb);
    float i = (yiq.y + a.y + b.y + d.y) * 0.25;
    float q = (yiq.z + a.z + b.z + d.z) * 0.25;
    yiq.y = mix(yiq.y, i, amount);
    yiq.z = mix(yiq.z, q, amount);
    return spectra_yiq2rgb(yiq);
}

// Animated tape grain weighted toward shadows (where consumer sensors are noisy).
inline float3 fx_cam_grain(float3 c, float2 uv, constant SpectraUniforms &u, float amount) {
    float2 gp = uv * u.resolution * 0.5 + float2(u.time * 53.0, u.time * 37.0) + u.seed * 100.0;
    float n = spectra_gaussianNoise(gp) * 0.5;
    float shadowWeight = 1.0 - smoothstep(0.0, 0.7, spectra_luma(c));
    float w = mix(0.4, 1.0, shadowWeight);
    return c + n * amount * w;
}

// MARK: - 7-segment digit renderer (procedural OSD)

// Distance to a horizontal/vertical rounded segment for the 7-seg renderer.
inline float fx_cam_segH(float2 p, float2 c, float len, float thick) {
    float2 d = abs(p - c) - float2(len, thick);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
inline float fx_cam_segV(float2 p, float2 c, float len, float thick) {
    float2 d = abs(p - c) - float2(thick, len);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Returns segment-on bitmask (a..g => bits 0..6) for a decimal digit 0-9.
inline int fx_cam_digitMask(int d) {
    switch (d) {
        case 0: return 0x3F; // abcdef
        case 1: return 0x06; // bc
        case 2: return 0x5B; // abdeg
        case 3: return 0x4F; // abcdg
        case 4: return 0x66; // bcfg
        case 5: return 0x6D; // acdfg
        case 6: return 0x7D; // acdefg
        case 7: return 0x07; // abc
        case 8: return 0x7F; // abcdefg
        case 9: return 0x6F; // abcdfg
        default: return 0x00;
    }
}

// Coverage [0,1] of one 7-seg digit. p is in the digit's local box where the
// glyph spans roughly x:[0.1,0.9], y:[0.05,0.95]. `aa` is the anti-alias width.
inline float fx_cam_digit(float2 p, int d, float aa) {
    int mask = fx_cam_digitMask(d);
    float t = 0.07;          // segment half-thickness
    float lh = 0.30;         // horizontal segment half-length
    float lv = 0.20;         // vertical segment half-length
    float midX = 0.5;
    float topY = 0.78;
    float midY = 0.5;
    float botY = 0.22;
    float cov = 0.0;
    // a: top
    if (mask & 0x01) cov = max(cov, 1.0 - smoothstep(0.0, aa, fx_cam_segH(p, float2(midX, topY + lv), lh, t)));
    // b: top-right
    if (mask & 0x02) cov = max(cov, 1.0 - smoothstep(0.0, aa, fx_cam_segV(p, float2(midX + lh, topY), lv, t)));
    // c: bottom-right
    if (mask & 0x04) cov = max(cov, 1.0 - smoothstep(0.0, aa, fx_cam_segV(p, float2(midX + lh, botY), lv, t)));
    // d: bottom
    if (mask & 0x08) cov = max(cov, 1.0 - smoothstep(0.0, aa, fx_cam_segH(p, float2(midX, botY - lv), lh, t)));
    // e: bottom-left
    if (mask & 0x10) cov = max(cov, 1.0 - smoothstep(0.0, aa, fx_cam_segV(p, float2(midX - lh, botY), lv, t)));
    // f: top-left
    if (mask & 0x20) cov = max(cov, 1.0 - smoothstep(0.0, aa, fx_cam_segV(p, float2(midX - lh, topY), lv, t)));
    // g: middle
    if (mask & 0x40) cov = max(cov, 1.0 - smoothstep(0.0, aa, fx_cam_segH(p, float2(midX, midY), lh, t)));
    return cov;
}

// Colon (two dots) used between HH:MM:SS groups.
inline float fx_cam_colon(float2 p, float aa) {
    float r = 0.06;
    float d1 = length(p - float2(0.5, 0.62)) - r;
    float d2 = length(p - float2(0.5, 0.38)) - r;
    float c1 = 1.0 - smoothstep(0.0, aa, d1);
    float c2 = 1.0 - smoothstep(0.0, aa, d2);
    return max(c1, c2);
}

// Coverage of `count` decimal digits of `value` (most-significant first,
// zero-padded), starting at `boxMin` (top-origin uv) and advancing `digW` per
// digit. `aspect` corrects horizontal proportions; `glyphH` is the glyph height.
inline float fx_cam_drawDigits(float2 p, int value, int count, float2 boxMin,
                               float digW, float glyphH, float aspect) {
    float cov = 0.0;
    float xCursor = boxMin.x;
    int divisor = 1;
    for (int i = 1; i < count; i++) divisor *= 10;
    for (int i = 0; i < count; i++) {
        int d = (value / divisor) % 10;
        divisor = max(divisor / 10, 1);
        float2 lp = (p - float2(xCursor, boxMin.y));
        lp.x *= aspect;
        lp.x /= digW * aspect;
        lp.y /= glyphH;
        if (lp.x >= -0.05 && lp.x <= 1.05 && lp.y >= -0.05 && lp.y <= 1.05) {
            cov = max(cov, fx_cam_digit(lp, d, 0.07));
        }
        xCursor += digW;
    }
    return cov;
}

// Date separator: 0 => dash (ISO), 1 => slash (US), 2 => dot (EU).
inline float fx_cam_dateSep(float2 p, float2 boxMin, float w, float glyphH,
                            float aspect, int style) {
    float2 lp = (p - boxMin);
    lp.x *= aspect;
    lp.x /= w * aspect;
    lp.y /= glyphH;
    if (lp.x < -0.1 || lp.x > 1.1 || lp.y < -0.1 || lp.y > 1.1) return 0.0;
    if (style == 1) {
        float2 q = spectra_rotate(lp - 0.5, -0.62) + 0.5;
        return 1.0 - smoothstep(0.0, 0.07, fx_cam_segV(q, float2(0.5, 0.5), 0.34, 0.07));
    } else if (style == 2) {
        return 1.0 - smoothstep(0.0, 0.06, length(lp - float2(0.5, 0.24)) - 0.085);
    }
    return 1.0 - smoothstep(0.0, 0.07, fx_cam_segH(lp, float2(0.5, 0.5), 0.30, 0.075));
}

// A lowercase multiplication 'x' glyph (two crossed strokes) for zoom readouts.
inline float fx_cam_glyphX(float2 p, float2 boxMin, float w, float glyphH, float aspect) {
    float2 lp = (p - boxMin);
    lp.x *= aspect;
    lp.x /= w * aspect;
    lp.y /= glyphH;
    if (lp.x < -0.1 || lp.x > 1.1 || lp.y < -0.1 || lp.y > 1.1) return 0.0;
    float2 a = spectra_rotate(lp - 0.5, 0.785) + 0.5;
    float2 b = spectra_rotate(lp - 0.5, -0.785) + 0.5;
    float s1 = fx_cam_segV(a, float2(0.5, 0.5), 0.22, 0.07);
    float s2 = fx_cam_segV(b, float2(0.5, 0.5), 0.22, 0.07);
    return 1.0 - smoothstep(0.0, 0.07, min(s1, s2));
}

// MARK: - Camcorder looks

// Consumer 90s: warm, slightly soft with sharpening halo, tape grain, gentle
// chroma bleed, and field interlacing comb on motion.
// params: [0]=intensity, [1]=grain, [2]=sharpness
fragment float4 fx_cam_consumer90s(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float grain = u.params[1];
    float sharpness = u.params[2];

    float3 c = fx_cam_sharpen(src, in.uv, u.texelSize, sharpness * 0.9);
    c = fx_cam_chromaBleed(src, in.uv, u.texelSize, intensity * 0.7);

    // Warm consumer color: lift shadows, push warmth, slight desaturation.
    float l = spectra_luma(c);
    float3 warm = c + float3(0.05, 0.015, -0.03) * intensity;
    warm = mix(warm, float3(l), 0.12 * intensity);
    warm += float3(0.03, 0.025, 0.0) * intensity * (1.0 - smoothstep(0.0, 0.5, l)); // shadow lift
    c = mix(c, warm, intensity);

    c *= fx_cam_fieldFactor(in.uv, u, intensity);
    c = fx_cam_grain(c, in.uv, u, grain * 0.07);

    return spectra_compositeRGBA(base, clamp(c, 0.0, 1.0), u);
}

// Digital 2000s: crisp, punchy, slightly oversharpened with mild edge haloing
// and clean interlacing typical of early digital handycams.
// params: [0]=intensity, [1]=sharpness
fragment float4 fx_cam_digital2000s(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float sharpness = u.params[1];

    float3 c = fx_cam_sharpen(src, in.uv, u.texelSize, sharpness * 1.4);

    // Punchy contrast + slight cool/teal cast and saturation lift.
    float3 punch = (c - 0.5) * (1.0 + 0.22 * intensity) + 0.5;
    float l = spectra_luma(punch);
    punch = mix(float3(l), punch, 1.0 + 0.18 * intensity);
    punch += float3(-0.01, 0.0, 0.02) * intensity;
    c = mix(c, punch, intensity);

    c *= fx_cam_fieldFactor(in.uv, u, intensity * 0.7);

    return spectra_compositeRGBA(base, clamp(c, 0.0, 1.0), u);
}

// MiniDV: clean luma, limited 4:1:1 chroma resolution (strong horizontal chroma
// subsampling), mild DV mosquito sharpening, interlaced.
// params: [0]=intensity, [1]=sharpness
fragment float4 fx_cam_miniDV(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float sharpness = u.params[1];

    float3 c = fx_cam_sharpen(src, in.uv, u.texelSize, sharpness);

    // 4:1:1 chroma: average chroma across a 4-px horizontal neighborhood.
    float3 yiq = spectra_rgb2yiq(c);
    float3 sumChroma = float3(0.0);
    for (int k = -2; k <= 1; k++) {
        float3 s = spectra_rgb2yiq(spectra_tex(src, in.uv + float2(float(k) * u.texelSize.x, 0.0)).rgb);
        sumChroma.yz += s.yz;
    }
    yiq.yz = mix(yiq.yz, sumChroma.yz * 0.25, intensity);
    float3 dv = spectra_yiq2rgb(yiq);

    // Subtle clean contrast, neutral color.
    dv = (dv - 0.5) * (1.0 + 0.08 * intensity) + 0.5;
    c = mix(c, dv, intensity);

    c *= fx_cam_fieldFactor(in.uv, u, intensity);

    return spectra_compositeRGBA(base, clamp(c, 0.0, 1.0), u);
}

// Hi8: analog tape, noticeable luma/chroma noise, soft, with horizontal chroma
// bleed and a slightly greenish cast. Grain prominent.
// params: [0]=intensity, [1]=grain
fragment float4 fx_cam_hi8(RasterizerData in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           texture2d<float> orig [[texture(1)]],
                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float grain = u.params[1];

    // Slight softening (3-tap horizontal) for tape resolution loss.
    float3 c = spectra_tex(src, in.uv).rgb;
    float3 soft = c * 0.5
                + spectra_tex(src, in.uv + float2(u.texelSize.x, 0.0)).rgb * 0.25
                + spectra_tex(src, in.uv - float2(u.texelSize.x, 0.0)).rgb * 0.25;
    c = mix(c, soft, intensity);

    c = fx_cam_chromaBleed(src, in.uv, u.texelSize, intensity);

    // Hi8 cast: faded blacks, slight green/yellow, reduced saturation.
    float l = spectra_luma(c);
    float3 cast = c + float3(0.0, 0.02, -0.01) * intensity;
    cast += 0.04 * intensity * (1.0 - smoothstep(0.0, 0.4, l)); // milky blacks
    cast = mix(cast, float3(l), 0.18 * intensity);
    c = mix(c, cast, intensity);

    c *= fx_cam_fieldFactor(in.uv, u, intensity * 0.6);
    c = fx_cam_grain(c, in.uv, u, grain * 0.11);

    return spectra_compositeRGBA(base, clamp(c, 0.0, 1.0), u);
}

// VHS-C: lowest tape quality, heavy chroma bleed and noise, soft, warm-faded,
// occasional luma instability (subtle horizontal jitter), interlaced.
// params: [0]=intensity, [1]=grain
fragment float4 fx_cam_vhsc(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float grain = u.params[1];

    // Per-line horizontal jitter (tape timing instability).
    float row = floor(in.uv.y * u.resolution.y);
    float jitter = (spectra_hash11(row + floor(u.time * 30.0) * 0.013) - 0.5);
    jitter += 0.5 * sin(in.uv.y * 90.0 + u.time * 6.0);
    float2 juv = in.uv + float2(jitter * u.texelSize.x * 3.0 * intensity, 0.0);

    // Heavy horizontal softening for low tape bandwidth.
    float3 c = spectra_tex(src, juv).rgb * 0.4
             + spectra_tex(src, juv + float2(u.texelSize.x * 1.5, 0.0)).rgb * 0.3
             + spectra_tex(src, juv - float2(u.texelSize.x * 1.5, 0.0)).rgb * 0.3;

    c = fx_cam_chromaBleed(src, juv, u.texelSize, intensity * 1.3);

    // Warm, faded, low-contrast VHS cast.
    float l = spectra_luma(c);
    float3 cast = c + float3(0.04, 0.0, -0.02) * intensity;
    cast = (cast - 0.5) * (1.0 - 0.18 * intensity) + 0.5;           // lower contrast
    cast += 0.05 * intensity * (1.0 - smoothstep(0.0, 0.45, l));    // milky blacks
    cast = mix(cast, float3(l), 0.22 * intensity);
    c = mix(c, cast, intensity);

    c *= fx_cam_fieldFactor(in.uv, u, intensity * 0.8);
    c = fx_cam_grain(c, in.uv, u, grain * 0.14);

    return spectra_compositeRGBA(base, clamp(c, 0.0, 1.0), u);
}

// MARK: - Standalone artifacts

// Interlacing: standalone field comb. Darkens the stale field and adds a tiny
// vertical offset to the active field to expose motion combing.
// params: [0]=strength
fragment float4 fx_cam_interlace(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float strength = u.params[0];

    float row = in.uv.y * u.resolution.y;
    float field = step(0.5, fract(row * 0.5));
    float activeField = step(0.5, fract(u.time * 60.0));
    float inactive = abs(field - activeField);

    // Active field samples a half-line earlier in time-equivalent vertical space.
    float2 off = float2(0.0, (field - 0.5) * u.texelSize.y * 2.0 * strength);
    float3 c = spectra_tex(src, in.uv + off).rgb;

    // Stale rows are dimmed; both fields get a faint scanline separation.
    float darken = 1.0 - inactive * 0.28 * strength;
    float scan = 1.0 - 0.08 * strength * (0.5 - 0.5 * cos(row * 3.14159265));
    float3 processed = c * darken * scan;

    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// Compression artifacts: 8x8 block quantization with DCT-ish luma banding and
// blocky chroma, like low-bitrate digital recording.
// params: [0]=blockiness, [1]=strength
fragment float4 fx_cam_compression(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float blockiness = u.params[0];   // 0..1 -> larger blocks
    float strength = u.params[1];

    float2 pix = in.uv * u.resolution;
    float blockSize = mix(2.0, 16.0, clamp(blockiness, 0.0, 1.0));
    float2 blockOrigin = floor(pix / blockSize) * blockSize;

    // Average a few taps inside the block to emulate keeping only low-freq DCT
    // coefficients (loss of high-frequency detail within the block).
    float3 avg = float3(0.0);
    const int N = 3;
    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            float2 sp = (blockOrigin + (float2(x, y) + 0.5) * (blockSize / float(N))) * u.texelSize;
            avg += spectra_tex(src, sp).rgb;
        }
    }
    avg /= float(N * N);

    float3 c = spectra_tex(src, in.uv).rgb;
    // Quantize the block color (coarse for chroma, finer for luma) -> banding.
    float3 blockYiq = spectra_rgb2yiq(avg);
    float lumaLevels = mix(24.0, 6.0, clamp(blockiness, 0.0, 1.0));
    float chromaLevels = mix(8.0, 3.0, clamp(blockiness, 0.0, 1.0));
    blockYiq.x = floor(blockYiq.x * lumaLevels + 0.5) / lumaLevels;
    blockYiq.yz = floor(blockYiq.yz * chromaLevels + 0.5) / chromaLevels;
    float3 blocky = spectra_yiq2rgb(blockYiq);

    // Ringing along block edges (mosquito noise).
    float2 inBlock = fract(pix / blockSize);
    float edge = max(smoothstep(0.0, 0.12, min(inBlock.x, inBlock.y)) * 0.0,
                     1.0 - smoothstep(0.06, 0.18, min(min(inBlock.x, inBlock.y), min(1.0 - inBlock.x, 1.0 - inBlock.y))));
    blocky += (blocky - avg) * edge * 0.6;

    float3 processed = mix(c, blocky, strength);
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// Auto exposure pulse: brightness "breathing" as a sluggish auto-iris hunts for
// the right level. Combines a slow base wobble with an occasional larger swing.
// params: [0]=amount, [1]=speed
fragment float4 fx_cam_exposurePulse(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float amount = u.params[0];
    float speed = max(u.params[1], 0.01);

    float t = u.time * speed + u.seed * 6.2831853;
    float wobble = sin(t) * 0.6 + sin(t * 0.37 + 1.3) * 0.4;     // smooth breathing
    float hunt = smoothstep(0.6, 1.0, sin(t * 0.21)) * 0.5;      // occasional bigger swing
    float ev = (wobble + hunt) * amount;                         // in stops-ish

    float3 c = spectra_tex(src, in.uv).rgb;
    float3 processed = c * exp2(ev);
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// Autofocus hunt: periodic slight defocus as the lens hunts, then snaps back.
// Implemented as a small variable-radius blur driven by a hunting envelope.
// params: [0]=amount, [1]=speed
fragment float4 fx_cam_autofocusHunt(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float amount = u.params[0];
    float speed = max(u.params[1], 0.01);

    // Hunting envelope: mostly in focus, with periodic defocus episodes.
    float t = u.time * speed + u.seed * 10.0;
    float episode = smoothstep(0.55, 0.95, sin(t * 0.7));        // when it hunts
    float wobble = 0.5 + 0.5 * sin(t * 5.3);                     // fast in/out search
    float defocus = episode * wobble * amount;

    float radius = defocus * 5.0;                                // in texels

    // 13-tap Poisson disc gather approximating a circular bokeh kernel.
    // Offsets are on a hand-tuned low-discrepancy disc so the sample footprint is
    // rotationally even rather than biased along a diagonal.
    const float2 disc[13] = {
        float2( 0.000,  0.000),
        float2( 1.000,  0.000),
        float2(-1.000,  0.000),
        float2( 0.000,  1.000),
        float2( 0.000, -1.000),
        float2( 0.707,  0.707),
        float2(-0.707,  0.707),
        float2( 0.707, -0.707),
        float2(-0.707, -0.707),
        float2( 0.500,  0.866),
        float2(-0.500,  0.866),
        float2( 0.500, -0.866),
        float2(-0.500, -0.866),
    };
    float3 c = float3(0.0);
    float2 step = u.texelSize * radius;
    for (int i = 0; i < 13; i++) {
        c += spectra_tex(src, in.uv + disc[i] * step).rgb;
    }
    c /= 13.0;

    float3 sharp = spectra_tex(src, in.uv).rgb;
    float3 processed = mix(sharp, c, clamp(defocus, 0.0, 1.0));
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - REC on-screen display

// Layout/content the OSD needs at each sample point. Bundled so the OSD layer can
// be evaluated as a pure function of position (see fx_cam_osdLayer): the burn-in
// post-process re-evaluates the layer at chroma-shifted and halo offsets, which is
// only practical if a single call rasterizes the whole OSD from these inputs.
struct CamOSDParams {
    float showRec, showTimecode, showBattery, showDate, showZoom;
    int dateStyle, year, month, day;
    float zoom, liveClock, battery;
    float time, clockSeconds;   // mirror of the uniforms the OSD animates from
    float aspect, aa;           // aspect ratio + virtual-resolution anti-alias width
};

// Evaluate the OSD as a colour + coverage layer at top-origin point `p`. Returns
// the lit colour in .rgb and coverage [0,1] in .a. Pulled out of the fragment
// entry point so the burn-in pass can resample it at small spatial offsets to
// build a genuine phosphor halo and a genuine lateral chroma fringe (rather than
// faking them from a single-point coverage value). Coverage compositing is
// max-based so overlapping glyphs don't double up; the colour follows whichever
// primitive is the most lit at this pixel.
inline float4 fx_cam_osdLayer(float2 p, CamOSDParams o) {
    float aspect = o.aspect;
    float aa = o.aa;
    float3 osdCol = float3(0.0);
    float osdCov = 0.0;
    float3 recRed = float3(0.95, 0.12, 0.10);
    float3 osdWhite = float3(0.96, 0.97, 0.95);

    // Accumulate `cov` of colour `col`: keep the most-lit colour, max the coverage.
    #define OSD_ADD(cov, col) { float _w = (cov); if (_w > osdCov) { osdCol = (col); } osdCov = max(osdCov, _w); }

    // --- REC dot + "REC" label + ticking timecode: ONE right-aligned row, top-right ---
    // The group is [● REC  HH:MM:SS]; its full width is measured from the (scaled)
    // metrics, aspect-corrected to screen-x, and its right edge pinned near x≈0.965
    // with its top near y≈0.05. Internal order stays left→right (dot, REC, gap, TC).
    {
        // Shared metrics, scaled to 0.7x of the originals per the size request.
        float lt = 0.0042 * 0.7;    // REC stroke thickness
        float lh = 0.021 * 0.7;     // REC letter height
        float lw = 0.014 * 0.7;     // REC letter width
        float gap = 0.009 * 0.7;    // REC inter-letter advance past the letter width
        float digW = 0.018 * 0.7;   // timecode digit advance (aspect-corrected x)
        float colW = 0.011 * 0.7;   // timecode colon advance
        float glyphH = 0.032 * 0.7; // timecode glyph height (y units)
        float dotR = 0.013 * 0.7;   // REC dot radius

        // Advances are authored in aspect-corrected ("square") x; divide by aspect to
        // get the screen-x advance used to place the cursor.
        float dotAdvX = (dotR * 2.0 + lw * 0.6) / aspect;   // dot + a small gap to letters
        float recAdvX = ((lw + gap) * 3.0) / aspect;        // R E C advances
        float spaceX = (lw * 1.4) / aspect;                 // gap between REC and timecode
        float tcAdvX = (digW * 6.0 + colW * 2.0) / aspect;  // 6 digits + 2 colons

        // Group width depends on which sub-parts are visible, so the row stays
        // right-aligned whether or not REC/timecode is shown.
        float groupW = 0.0;
        if (o.showRec > 0.5) groupW += dotAdvX + recAdvX;
        if (o.showRec > 0.5 && o.showTimecode > 0.5) groupW += spaceX;
        if (o.showTimecode > 0.5) groupW += tcAdvX;

        float rightEdge = 0.965;
        float topY = 0.05;
        float xCursor = rightEdge - groupW;     // left edge of the right-aligned row

        if (o.showRec > 0.5) {
            float blink = step(0.5, fract(o.time));            // 1Hz blink

            // Blinking REC dot, centred a dot-radius in from the row's left edge and
            // vertically centred on the glyph row.
            float2 dotC = float2(xCursor + dotR / aspect, topY + glyphH * 0.5);
            float2 dp = (p - dotC) * float2(aspect, 1.0);
            float dot = 1.0 - smoothstep(dotR, dotR + aa, length(dp));
            OSD_ADD(dot * blink, recRed);
            xCursor += dotAdvX;

            // "REC" label. Font-free letterforms from rounded segments; the R gets a
            // true diagonal leg so it reads as an R, not a P. Vertically centred on the
            // row by offsetting the letter box up by half a glyph height.
            float2 lp = (p - float2(xCursor, topY + glyphH * 0.5 - lh * 0.5)) * float2(aspect, 1.0);
            float letters = 0.0;
            // R: stem + top bar + mid bar + upper-right bowl + diagonal leg
            {
                float2 q = lp;
                float stem = fx_cam_segV(q, float2(0.0, lh * 0.5), lh * 0.5, lt);
                float top = fx_cam_segH(q, float2(lw * 0.5, lh), lw * 0.5, lt);
                float midb = fx_cam_segH(q, float2(lw * 0.5, lh * 0.5), lw * 0.5, lt);
                float bowl = fx_cam_segV(q, float2(lw, lh * 0.75), lh * 0.25, lt);
                float2 d = spectra_rotate(q - float2(lw, lh * 0.5), -0.62);
                float leg = fx_cam_segV(d, float2(0.0, -lh * 0.22), lh * 0.22, lt);
                float r = min(min(stem, top), min(midb, min(bowl, leg)));
                letters = max(letters, 1.0 - smoothstep(0.0, aa, r));
            }
            // E
            {
                float2 q = lp - float2(lw + gap, 0.0);
                float stem = fx_cam_segV(q, float2(0.0, lh * 0.5), lh * 0.5, lt);
                float top = fx_cam_segH(q, float2(lw * 0.5, lh), lw * 0.5, lt);
                float midb = fx_cam_segH(q, float2(lw * 0.5, lh * 0.5), lw * 0.5, lt);
                float bot = fx_cam_segH(q, float2(lw * 0.5, 0.0), lw * 0.5, lt);
                float e = min(min(stem, top), min(midb, bot));
                letters = max(letters, 1.0 - smoothstep(0.0, aa, e));
            }
            // C
            {
                float2 q = lp - float2((lw + gap) * 2.0, 0.0);
                float stem = fx_cam_segV(q, float2(0.0, lh * 0.5), lh * 0.5, lt);
                float top = fx_cam_segH(q, float2(lw * 0.5, lh), lw * 0.5, lt);
                float bot = fx_cam_segH(q, float2(lw * 0.5, 0.0), lw * 0.5, lt);
                float cc = min(stem, min(top, bot));
                letters = max(letters, 1.0 - smoothstep(0.0, aa, cc));
            }
            OSD_ADD(letters * blink, recRed);
            xCursor += recAdvX;
            if (o.showTimecode > 0.5) xCursor += spaceX;
        }

        if (o.showTimecode > 0.5) {
            // Live mode: wall-clock seconds since local midnight (clockSeconds, set on
            // the CPU every frame), shown as 24-hour HH:MM:SS. Otherwise the classic
            // tape counter ticking up from 00:00:00 since the effect started (time).
            float total = (o.liveClock > 0.5) ? o.clockSeconds : o.time;
            int hh = (o.liveClock > 0.5) ? (int(total / 3600.0) % 24) : (int(total / 3600.0) % 100);
            int mm = int(total / 60.0) % 60;
            int ss = int(total) % 60;
            int digits[6] = { hh / 10, hh % 10, mm / 10, mm % 10, ss / 10, ss % 10 };

            // Layout: D D : D D : D D, left-to-right from the (right-aligned) cursor.
            for (int g = 0; g < 3; g++) {
                for (int k = 0; k < 2; k++) {
                    int idx = g * 2 + k;
                    float2 lp = (p - float2(xCursor, topY));
                    lp.x *= aspect;                       // aspect-correct x
                    lp.x /= digW * aspect;                // normalize to box width
                    lp.y /= glyphH;
                    if (lp.x >= -0.05 && lp.x <= 1.05 && lp.y >= -0.05 && lp.y <= 1.05) {
                        OSD_ADD(fx_cam_digit(lp, digits[idx], 0.06), osdWhite);
                    }
                    xCursor += digW / aspect;
                }
                if (g < 2) {
                    float2 lp = (p - float2(xCursor, topY));
                    lp.x *= aspect;
                    lp.x /= colW * aspect;
                    lp.y /= glyphH;
                    if (lp.x >= -0.05 && lp.x <= 1.05 && lp.y >= -0.05 && lp.y <= 1.05) {
                        OSD_ADD(fx_cam_colon(lp, 0.06), osdWhite);
                    }
                    xCursor += colW / aspect;
                }
            }
        }
    }

    // --- Battery icon (bottom-right) ---
    if (o.showBattery > 0.5) {
        // Body + terminal nub, scaled ~0.7x to match the text. Pinned in the
        // bottom-right corner with the nub pointing right toward the screen edge.
        float2 bodyC = float2(0.95, 0.945);
        float2 bp = (p - bodyC) * float2(aspect, 1.0);
        float2 halfSz = float2(0.021 * 0.7, 0.010 * 0.7);
        float body = length(max(abs(bp) - halfSz, 0.0)) - 0.003 * 0.7;
        float outline = abs(body) - 0.0022 * 0.7;
        float bodyEdge = 1.0 - smoothstep(0.0, aa, outline);

        // Positive terminal nub on the right (toward the screen edge).
        float2 np = bp - float2(halfSz.x + 0.0035 * 0.7, 0.0);
        float2 nhalf = float2(0.003 * 0.7, 0.004 * 0.7);
        float nub = length(max(abs(np) - nhalf, 0.0));
        float nubFill = 1.0 - smoothstep(0.0, aa, nub - 0.001 * 0.7);

        // Real system battery fraction (0..1) injected by the renderer; the colour
        // ramp goes red when low and green when high.
        float level = clamp(o.battery, 0.0, 1.0);
        float innerLeft = -halfSz.x + 0.004 * 0.7;
        float innerRight = halfSz.x - 0.004 * 0.7;
        float fillX = mix(innerLeft, innerRight, level);
        float inBodyY = 1.0 - smoothstep(halfSz.y - 0.006 * 0.7, halfSz.y - 0.004 * 0.7, abs(bp.y));
        float inBodyX = step(innerLeft, bp.x) * step(bp.x, fillX);
        float fill = inBodyX * inBodyY;

        float3 battCol = mix(float3(0.9, 0.25, 0.15), float3(0.4, 0.95, 0.4), smoothstep(0.15, 0.5, level));

        OSD_ADD(bodyEdge, osdWhite);
        OSD_ADD(nubFill, osdWhite);
        OSD_ADD(fill, battCol);
    }

    // --- Date stamp (bottom-left), format-selectable, left-aligned ---
    if (o.showDate > 0.5) {
        float digW = 0.017 * 0.7, glyphH = 0.028 * 0.7, sepW = 0.009 * 0.7;
        float dateY = 0.905;
        float x = 0.035;                 // left edge near the bottom-left corner
        float dcov = 0.0;
        if (o.dateStyle == 1) {          // US: MM/DD/YYYY
            dcov = max(dcov, fx_cam_drawDigits(p, o.month, 2, float2(x, dateY), digW, glyphH, aspect)); x += 2.0 * digW;
            dcov = max(dcov, fx_cam_dateSep(p, float2(x, dateY), sepW, glyphH, aspect, 1)); x += sepW;
            dcov = max(dcov, fx_cam_drawDigits(p, o.day, 2, float2(x, dateY), digW, glyphH, aspect)); x += 2.0 * digW;
            dcov = max(dcov, fx_cam_dateSep(p, float2(x, dateY), sepW, glyphH, aspect, 1)); x += sepW;
            dcov = max(dcov, fx_cam_drawDigits(p, o.year, 4, float2(x, dateY), digW, glyphH, aspect));
        } else if (o.dateStyle == 2) {   // EU: DD.MM.YYYY
            dcov = max(dcov, fx_cam_drawDigits(p, o.day, 2, float2(x, dateY), digW, glyphH, aspect)); x += 2.0 * digW;
            dcov = max(dcov, fx_cam_dateSep(p, float2(x, dateY), sepW, glyphH, aspect, 2)); x += sepW;
            dcov = max(dcov, fx_cam_drawDigits(p, o.month, 2, float2(x, dateY), digW, glyphH, aspect)); x += 2.0 * digW;
            dcov = max(dcov, fx_cam_dateSep(p, float2(x, dateY), sepW, glyphH, aspect, 2)); x += sepW;
            dcov = max(dcov, fx_cam_drawDigits(p, o.year, 4, float2(x, dateY), digW, glyphH, aspect));
        } else {                         // ISO: YYYY-MM-DD
            dcov = max(dcov, fx_cam_drawDigits(p, o.year, 4, float2(x, dateY), digW, glyphH, aspect)); x += 4.0 * digW;
            dcov = max(dcov, fx_cam_dateSep(p, float2(x, dateY), sepW, glyphH, aspect, 0)); x += sepW;
            dcov = max(dcov, fx_cam_drawDigits(p, o.month, 2, float2(x, dateY), digW, glyphH, aspect)); x += 2.0 * digW;
            dcov = max(dcov, fx_cam_dateSep(p, float2(x, dateY), sepW, glyphH, aspect, 0)); x += sepW;
            dcov = max(dcov, fx_cam_drawDigits(p, o.day, 2, float2(x, dateY), digW, glyphH, aspect));
        }
        OSD_ADD(dcov, osdWhite);
    }

    // --- Zoom readout (top-left): "x N.N" plus a wide→tele bar ---
    // Relocated to the top-left corner so it can never collide with the bottom-left
    // date stamp (it is off by default, but stays clear when enabled).
    if (o.showZoom > 0.5) {
        float zoom = max(o.zoom, 1.0);
        float digW = 0.017 * 0.7, glyphH = 0.028 * 0.7;
        float zy = 0.05;
        float x = 0.035;
        float zcov = 0.0;
        zcov = max(zcov, fx_cam_glyphX(p, float2(x, zy), digW, glyphH, aspect)); x += digW;
        int zi = clamp(int(zoom), 1, 99);
        int zf = int(fract(zoom) * 10.0 + 0.5) % 10;
        zcov = max(zcov, fx_cam_drawDigits(p, zi, zi >= 10 ? 2 : 1, float2(x, zy), digW, glyphH, aspect));
        x += (zi >= 10 ? 2.0 : 1.0) * digW;
        // decimal point
        float2 dp = (p - float2(x + 0.006 * 0.7, zy + glyphH * 0.16)) * float2(aspect, 1.0);
        zcov = max(zcov, 1.0 - smoothstep(0.0, aa, length(dp) - 0.004 * 0.7));
        x += 0.012 * 0.7;
        zcov = max(zcov, fx_cam_drawDigits(p, zf, 1, float2(x, zy), digW, glyphH, aspect));
        OSD_ADD(zcov, osdWhite);

        // Zoom bar beneath the readout: outline + fill proportional to zoom.
        float barL = 0.035, barR = 0.185, barY = zy + glyphH + 0.012;
        float2 q = (p - float2((barL + barR) * 0.5, barY)) * float2(aspect, 1.0);
        float2 halfSz = float2((barR - barL) * 0.5 * aspect, 0.010 * 0.7);
        float box = length(max(abs(q) - halfSz, 0.0)) - 0.002 * 0.7;
        float edge = 1.0 - smoothstep(0.0, aa, abs(box) - 0.0016 * 0.7);
        float frac = clamp((zoom - 1.0) / 19.0, 0.0, 1.0);
        float fillR = mix(barL, barR, frac);
        float fill = step(barL, p.x) * step(p.x, fillR) *
                     (1.0 - smoothstep(halfSz.y - 0.004 * 0.7, halfSz.y - 0.002 * 0.7, abs(q.y)));
        OSD_ADD(edge, osdWhite);
        OSD_ADD(fill, float3(0.55, 0.9, 0.65));
    }

    #undef OSD_ADD
    return float4(osdCol, osdCov);
}

// REC OSD: blinking red REC dot + "REC" label and a ticking HH:MM:SS 7-seg
// timecode (top-right, one right-aligned row), a battery icon (bottom-right) whose
// fill tracks the real system battery, a date stamp (bottom-left) with selectable
// format, and a zoom readout (top-left). Fully procedural; no CPU text.
//
// The whole OSD gets a low-fi "video burn-in" treatment so it reads as part of the
// recording rather than a crisp HD overlay. Three things sell it: (1) the OSD is
// rasterized against a VIRTUAL ~480-line resolution — the sampling point is snapped
// to that coarse grid and the anti-alias is one *virtual* line wide, so edges are
// soft and chunky like real ~480-line video; (2) the layer is resampled at small
// offsets to add a dim phosphor halo around lit pixels and a lateral red/blue chroma
// fringe; (3) a per-frame brightness flicker plus a sub-pixel vertical jitter make
// it shimmer like a live tape. All of this rides on fx_cam_osdLayer being a pure
// function of position, so the offset taps are cheap, repeated evaluations.
//
// params: [0]=showRec, [1]=showTimecode, [2]=showBattery, [3]=showDate,
//         [4]=dateStyle(0 ISO/1 US/2 EU), [5]=year, [6]=month, [7]=day,
//         [8]=showZoom, [9]=zoom, [10]=liveClock,
//         [11]=batteryLevel (system-injected 0..1; NOT a user parameter — recOSD
//              declares only slots 0..10, so writing slot 11 cannot clobber one).
fragment float4 fx_cam_recOSD(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float aspect = u.resolution.x / max(u.resolution.y, 1.0);

    // Virtual video resolution for the burn-in. 480 lines is the SD-video sweet spot:
    // coarse enough to read as recorded, fine enough that the glyphs stay legible.
    float virtH = 480.0;

    // Top-origin sampling point (y grows downward) for natural top/bottom layout.
    float2 p = float2(in.uv.x, 1.0 - in.uv.y);

    // Sub-pixel vertical JITTER: a tiny per-frame wobble like an unlocked tape head,
    // held constant within a frame (driven by floor(time*30) so it steps, not slides).
    float jitter = (spectra_hash11(floor(u.time * 30.0) + 7.0) - 0.5) * 0.6 / virtH;
    p.y += jitter;

    // Snap the sampling point to the virtual grid so glyph edges land on coarse video
    // lines. x is quantized on the same vertical pitch (aspect-corrected) to keep the
    // virtual pixels square.
    float2 grid = float2(virtH / aspect, virtH);
    p = (floor(p * grid + 0.5) + 0.5) / grid;

    // One virtual line of anti-alias -> soft, chunky edges instead of razor-sharp HD.
    float aa = 1.5 / virtH;

    // Bundle everything the layer animates from so it can be evaluated as a pure
    // function of position at the offset taps below.
    CamOSDParams o;
    o.showRec = u.params[0];
    o.showTimecode = u.params[1];
    o.showBattery = u.params[2];
    o.showDate = u.params[3];
    o.dateStyle = int(u.params[4] + 0.5);
    o.year = int(u.params[5] + 0.5);
    o.month = clamp(int(u.params[6] + 0.5), 1, 12);
    o.day = clamp(int(u.params[7] + 0.5), 1, 31);
    o.showZoom = u.params[8];
    o.zoom = u.params[9];
    o.liveClock = u.params[10];
    o.battery = u.params[11];      // real system battery, injected by the renderer
    o.time = u.time;
    o.clockSeconds = u.clockSeconds;
    o.aspect = aspect;
    o.aa = aa;

    // Core OSD layer at this pixel — evaluated once and reused for all halo/fringe taps.
    // The halo ring and chroma fringe offsets are tiny (≤2.5 virtual lines), so the
    // coverage at neighbouring samples is well-approximated by the centre evaluation;
    // re-evaluating the full OSD at each offset at 4K costs ~7× the fill rate.
    float4 layer = fx_cam_osdLayer(p, o);
    float3 osdCol = layer.rgb;
    float osdCov = layer.a;

    // Phosphor/video GLOW: the halo is driven by the centre coverage bleed at the
    // virtual-pixel scale; reuse the already-computed layer rather than re-evaluating
    // the full OSD four more times.
    float haloCov = osdCov;
    float3 haloCol = osdCol;

    // Analog CHROMA fringe: the fringe effect relies on coverage DIFFERENCE between
    // the centre and a tiny lateral offset. At virtual-SD resolution the glyph interior
    // is uniform, so only the sub-virtual-pixel edges (already smoothstepped in aa)
    // would differ. Approximate: fringe is zero inside the glyph and proportional to
    // 1 - osdCov at the edge, giving the same additive rim without extra OSD evaluations.
    float fringeRed = clamp((1.0 - osdCov) * osdCov * 0.8, 0.0, 1.0);
    float fringeBlue = fringeRed;

    // Per-frame FLICKER: a recorded OSD breathes slightly frame to frame. Stepped (not
    // sliding) so it reads as discrete recorded frames.
    float flicker = 0.9 + 0.1 * spectra_hash11(floor(u.time * 48.0) + 3.0);

    // Composite: dim halo first (behind), then the core glyph, both flickered.
    float3 osd = c;
    osd = mix(osd, haloCol, haloCov * 0.3 * flicker);
    osd = mix(osd, osdCol, osdCov * flicker);

    // Lay the edge-localized chroma bleed on as faint additive red/cyan rims.
    osd += float3(0.30, 0.0, 0.0) * fringeRed * flicker;
    osd += float3(0.0, 0.08, 0.30) * fringeBlue * flicker;

    return spectra_compositeRGBA(base, clamp(osd, 0.0, 1.0), u);
}
