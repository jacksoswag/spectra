#include "SpectraCommon.h"

// Pixel effects: pixelation, dithering, quantization, and retro-console looks.
// Each fragment function samples the effect input on texture(0), the original
// (for compositing) on texture(1), reads parameters in declaration order from
// u.params[], and composites via spectra_compositeRGBA.

// MARK: - Category helpers (prefixed to avoid link collisions)

// Quantize each channel to `levels` discrete steps (levels >= 2).
inline float3 fx_pixel_quantize(float3 c, float levels) {
    float n = max(levels, 2.0);
    return floor(clamp(c, 0.0, 1.0) * (n - 1.0) + 0.5) / (n - 1.0);
}

// 4x4 Bayer ordered-dither threshold in [0,1) for integer cell coords.
inline float fx_pixel_bayer4(int2 p) {
    const int m[16] = {
         0,  8,  2, 10,
        12,  4, 14,  6,
         3, 11,  1,  9,
        15,  7, 13,  5
    };
    int ix = ((p.x % 4) + 4) % 4;
    int iy = ((p.y % 4) + 4) % 4;
    return (float(m[iy * 4 + ix]) + 0.5) / 16.0;
}

// MARK: - Pixelation

fragment float4 fx_pixel_pixelate(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float block = max(u.params[0], 1.0);
    float2 grid = max(u.resolution / block, float2(1.0));
    float2 snapped = (floor(in.uv * grid) + 0.5) / grid;
    float3 processed = spectra_tex(src, snapped).rgb;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Pixel Sort

// Detects the contiguous above-threshold span containing this pixel (scanning
// both directions along the sort axis), measures the pixel's brightness rank
// within that span, then outputs the span's darkest→brightest gradient at that
// rank. The result is monotonically sorted by brightness within each span — the
// signature pixel-sort streak. (A bounded fragment-shader approximation of a true
// per-row sort, which would require a multi-pass compute sort.)
fragment float4 fx_pixel_sort(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float threshold = u.params[0];
    float spanLen = u.params[1];
    bool vertical = u.params[2] > 0.5;

    float2 stepUV = (vertical ? float2(0.0, 1.0) : float2(1.0, 0.0)) * u.texelSize;
    float3 c = spectra_tex(src, in.uv).rgb;
    float cl = spectra_luma(c);

    if (cl < threshold) {
        return spectra_compositeRGBA(base, c, u);
    }

    float3 darkest = c, brightest = c;
    float minL = cl, maxL = cl;
    float rank = 0.0, count = 1.0;
    const int kMaxTaps = 64;

    // Backward span.
    for (int i = 1; i <= kMaxTaps; i++) {
        if (float(i) > spanLen) break;
        float3 s = spectra_tex(src, in.uv - stepUV * float(i)).rgb;
        float sl = spectra_luma(s);
        if (sl < threshold) break;
        if (sl < minL) { minL = sl; darkest = s; }
        if (sl > maxL) { maxL = sl; brightest = s; }
        if (sl < cl) { rank += 1.0; }
        count += 1.0;
    }
    // Forward span.
    for (int i = 1; i <= kMaxTaps; i++) {
        if (float(i) > spanLen) break;
        float3 s = spectra_tex(src, in.uv + stepUV * float(i)).rgb;
        float sl = spectra_luma(s);
        if (sl < threshold) break;
        if (sl < minL) { minL = sl; darkest = s; }
        if (sl > maxL) { maxL = sl; brightest = s; }
        if (sl < cl) { rank += 1.0; }
        count += 1.0;
    }

    float t = count > 1.0 ? rank / (count - 1.0) : 0.0;
    float3 processed = mix(darkest, brightest, t);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Dithering (hashed dither before quantization)

fragment float4 fx_pixel_dither(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float levels = u.params[0];
    float strength = u.params[1];

    float2 px = in.uv * u.resolution;
    float n = spectra_hash21(floor(px)) - 0.5;
    float amplitude = strength / max(levels - 1.0, 1.0);
    float3 dithered = c + n * amplitude;
    float3 processed = fx_pixel_quantize(dithered, levels);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Ordered Dither (generic ordered dither over a scalable grid)

fragment float4 fx_pixel_ordered(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float levels = u.params[0];
    float scale = max(u.params[1], 1.0);

    float2 cell = floor(in.uv * u.resolution / scale);
    float t = fx_pixel_bayer4(int2(cell)) - 0.5;
    float amplitude = 1.0 / max(levels - 1.0, 1.0);
    float3 processed = fx_pixel_quantize(c + t * amplitude, levels);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Bayer Dither (explicit 4x4 matrix at native pixel scale)

fragment float4 fx_pixel_bayer(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float levels = u.params[0];

    int2 px = int2(floor(in.uv * u.resolution));
    float t = fx_pixel_bayer4(px) - 0.5;
    float amplitude = 1.0 / max(levels - 1.0, 1.0);
    float3 processed = fx_pixel_quantize(c + t * amplitude, levels);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Floyd-Steinberg (approximate error diffusion via a local neighborhood)

fragment float4 fx_pixel_floyd(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float levels = u.params[0];
    float2 t = u.texelSize;

    // Gather quantization error from the causal neighbors that a serial
    // Floyd-Steinberg pass would have diffused into this pixel.
    float3 c = spectra_tex(src, in.uv).rgb;
    float3 left  = spectra_tex(src, in.uv - float2(t.x, 0.0)).rgb;
    float3 up    = spectra_tex(src, in.uv - float2(0.0, t.y)).rgb;
    float3 upLeft  = spectra_tex(src, in.uv - float2(t.x, t.y)).rgb;
    float3 upRight = spectra_tex(src, in.uv + float2(t.x, -t.y)).rgb;

    float3 errL  = left  - fx_pixel_quantize(left, levels);
    float3 errU  = up    - fx_pixel_quantize(up, levels);
    float3 errUL = upLeft  - fx_pixel_quantize(upLeft, levels);
    float3 errUR = upRight - fx_pixel_quantize(upRight, levels);

    // Standard Floyd-Steinberg weights (7,1,5,3)/16.
    float3 diffused = c
        + errL  * (7.0 / 16.0)
        + errUR * (1.0 / 16.0)
        + errU  * (5.0 / 16.0)
        + errUL * (3.0 / 16.0);

    float3 processed = fx_pixel_quantize(diffused, levels);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Color Quantization (palette reduction via rounding)

fragment float4 fx_pixel_quantizeFx(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float3 processed = fx_pixel_quantize(c, u.params[0]);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Retro Resolution (downsample then nearest upscale)

fragment float4 fx_pixel_retroRes(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float targetWidth = max(u.params[0], 8.0);
    float aspect = u.resolution.y / max(u.resolution.x, 1.0);
    float2 lowRes = float2(targetWidth, max(floor(targetWidth * aspect), 1.0));
    float2 snapped = (floor(in.uv * lowRes) + 0.5) / lowRes;
    float3 processed = spectra_texPoint(src, snapped).rgb;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Game Boy (4-shade DMG green palette + low res)

fragment float4 fx_pixel_gameboy(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float strength = u.params[0];

    // DMG screen is 160 px wide; snap to that grid.
    float2 lowRes = float2(160.0, max(floor(160.0 * u.resolution.y / max(u.resolution.x, 1.0)), 1.0));
    float2 snapped = (floor(in.uv * lowRes) + 0.5) / lowRes;
    float3 c = spectra_texPoint(src, snapped).rgb;

    // Bayer-dithered 4-level luma, mapped to the classic DMG green ramp.
    int2 px = int2(floor(in.uv * lowRes));
    float l = spectra_luma(c);
    float d = (fx_pixel_bayer4(px) - 0.5) * (1.0 / 3.0);
    float shade = floor(clamp(l + d, 0.0, 1.0) * 3.0 + 0.5) / 3.0;

    const float3 darkest  = float3(0.059, 0.220, 0.059);
    const float3 dark     = float3(0.188, 0.384, 0.188);
    const float3 light    = float3(0.545, 0.675, 0.059);
    const float3 lightest = float3(0.612, 0.725, 0.086);
    float3 green;
    if (shade < 0.25)      green = darkest;
    else if (shade < 0.5)  green = dark;
    else if (shade < 0.85) green = light;
    else                   green = lightest;

    float3 processed = mix(c, green, clamp(strength, 0.0, 1.0));
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - PS1 (vertex-snap jitter + dither + 16-bit color)

fragment float4 fx_pixel_ps1(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float jitter = u.params[0];
    float dither = u.params[1];
    float depth = max(u.params[2], 2.0);

    // Vertex-snap look: quantize UV to a coarse jittered lattice.
    float2 snapGrid = u.resolution / mix(1.0, 6.0, clamp(jitter, 0.0, 1.0));
    float2 jit = (spectra_hash22(floor(in.uv * snapGrid)) - 0.5) * jitter * u.texelSize * 3.0;
    float2 snapped = (floor((in.uv + jit) * snapGrid) + 0.5) / snapGrid;
    float3 c = spectra_texPoint(src, snapped).rgb;

    // 16-bit (5 bits/channel by default) color with ordered dither.
    int2 px = int2(floor(in.uv * u.resolution));
    float t = (fx_pixel_bayer4(px) - 0.5) * dither / max(depth - 1.0, 1.0);
    float3 processed = fx_pixel_quantize(c + t, depth);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Nintendo 64 (soft bilinear smear + dither)

fragment float4 fx_pixel_n64(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float blur = u.params[0];
    float dither = u.params[1];

    // Characteristic N64 softness: a small box smear (3-bit mipped feel).
    float2 r = u.texelSize * mix(0.5, 3.0, clamp(blur, 0.0, 1.0));
    float3 sum = spectra_tex(src, in.uv).rgb * 4.0;
    sum += spectra_tex(src, in.uv + float2( r.x, 0.0)).rgb;
    sum += spectra_tex(src, in.uv + float2(-r.x, 0.0)).rgb;
    sum += spectra_tex(src, in.uv + float2(0.0,  r.y)).rgb;
    sum += spectra_tex(src, in.uv + float2(0.0, -r.y)).rgb;
    sum += spectra_tex(src, in.uv + float2( r.x,  r.y)).rgb;
    sum += spectra_tex(src, in.uv + float2(-r.x, -r.y)).rgb;
    sum += spectra_tex(src, in.uv + float2( r.x, -r.y)).rgb;
    sum += spectra_tex(src, in.uv + float2(-r.x,  r.y)).rgb;
    float3 soft = sum / 12.0;

    // 32-bit-ish framebuffer dither toward a modest palette.
    float levels = 32.0;
    int2 px = int2(floor(in.uv * u.resolution));
    float t = (fx_pixel_bayer4(px) - 0.5) * dither / (levels - 1.0);
    float3 processed = fx_pixel_quantize(soft + t, levels);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Arcade (low-res CRT-arcade palette look)

fragment float4 fx_pixel_arcade(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float scanline = u.params[0];
    float palette = u.params[1];

    // 320-wide arcade canvas, nearest upscaled.
    float2 lowRes = float2(320.0, max(floor(320.0 * u.resolution.y / max(u.resolution.x, 1.0)), 1.0));
    float2 snapped = (floor(in.uv * lowRes) + 0.5) / lowRes;
    float3 c = spectra_texPoint(src, snapped).rgb;

    // Punchy quantized palette with a touch of saturation boost.
    float levels = mix(32.0, 6.0, clamp(palette, 0.0, 1.0));
    int2 px = int2(floor(in.uv * lowRes));
    float t = (fx_pixel_bayer4(px) - 0.5) / max(levels - 1.0, 1.0);
    float3 quant = fx_pixel_quantize(c + t * 0.5, levels);
    float l = spectra_luma(quant);
    quant = mix(float3(l), quant, mix(1.0, 1.35, clamp(palette, 0.0, 1.0)));

    // CRT-arcade scanlines aligned to the low-res vertical grid.
    float line = 0.5 + 0.5 * cos(in.uv.y * lowRes.y * 6.28318530718);
    float darken = 1.0 - clamp(scanline, 0.0, 1.0) * line * 0.6;
    float3 processed = clamp(quant * darken, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}
