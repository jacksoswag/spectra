// Style.metal
//
// Artistic stylization passes for the "world" presets (see docs/WORLDS.md):
// edge-preserving smooth, cel quantize, ink contours, Ben-Day halftone, pixel
// mosaic, cross-hatch, paper grain, impasto relief, and the half-res painterly
// Kuwahara. Parameter slots match each descriptor's declaration order in
// StyleEffects.swift (the binding contract). texture(0) is the pass source,
// texture(1) the effect's original input, both bound by EffectChainRenderer.

#include "SpectraCommon.h"

// MARK: - Flatten (edge-preserving smooth)

// Small bilateral smooth: spatial Gaussian × range Gaussian over a 5×5 window.
// Removes micro-noise and text fringe so quantize/ink do not false-trigger while
// keeping real edges. params[0]=radius, params[1]=edge preserve.
fragment float4 fx_style_flatten(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 center = spectra_tex(src, in.uv).rgb;
    float radius = clamp(u.params[0], 0.5, 3.0);
    float edge = clamp(u.params[1], 0.0, 1.0);
    float2 t = u.texelSize * radius;
    float rangeSigma = mix(0.6, 0.08, edge);
    float invR2 = 1.0 / (2.0 * rangeSigma * rangeSigma);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 off = float2(float(i), float(j));
            float3 s = spectra_tex(src, in.uv + off * t).rgb;
            float spatial = exp(-dot(off, off) * 0.25);
            float3 d = s - center;
            float range = exp(-dot(d, d) * invR2);
            float w = spatial * range;
            sum += s * w;
            wsum += w;
        }
    }
    float3 processed = sum / max(wsum, 1e-4);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Cel Quantize

// Posterize value into N bands with a smoothstep ramp at each edge (so near-band
// pixels do not toggle between frames), with a saturation lift and an optional
// black-point crush. params[0]=bands, [1]=smoothness, [2]=saturation, [3]=blackPoint.
fragment float4 fx_style_quantize(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float bands = max(2.0, floor(u.params[0] + 0.5));
    float smoothness = clamp(u.params[1], 0.0, 1.0);
    float satAdj = u.params[2];
    float blackPoint = clamp(u.params[3], 0.0, 0.5);

    float3 hsv = spectra_rgb2hsv(c);
    float scaled = hsv.z * bands;
    float lo = floor(scaled);
    float f = scaled - lo;
    float w = clamp(smoothness * 0.5, 0.001, 0.5);
    float ramp = smoothstep(0.5 - w, 0.5 + w, f);
    float qv = clamp((lo + ramp) / bands, 0.0, 1.0);
    float s = clamp(hsv.y * (1.0 + satAdj), 0.0, 1.0);
    float3 q = spectra_hsv2rgb(float3(hsv.x, s, qv));
    if (blackPoint > 0.0) {
        q *= smoothstep(0.0, blackPoint, spectra_luma(q));
    }
    return spectra_compositeRGBA(base, q, u);
}

// MARK: - Ink Lines

// Sobel contour lines over the image. The edge magnitude is soft-thresholded into
// an ink mask and the ink color is mixed in. params[0]=thickness, [1]=threshold,
// [2]=opacity, [3]=softness, [4..6]=ink RGB (slot 7 = alpha, unused).
fragment float4 fx_style_ink(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float thickness = clamp(u.params[0], 0.5, 3.0);
    float threshold = clamp(u.params[1], 0.0, 1.0);
    float opacity = clamp(u.params[2], 0.0, 1.0);
    float softness = clamp(u.params[3], 0.0, 1.0);
    float3 inkColor = float3(u.params[4], u.params[5], u.params[6]);
    float2 t = u.texelSize * thickness;

    float tl = spectra_luma(spectra_tex(src, in.uv + float2(-t.x, -t.y)).rgb);
    float tc = spectra_luma(spectra_tex(src, in.uv + float2( 0.0, -t.y)).rgb);
    float tr = spectra_luma(spectra_tex(src, in.uv + float2( t.x, -t.y)).rgb);
    float ml = spectra_luma(spectra_tex(src, in.uv + float2(-t.x,  0.0)).rgb);
    float mr = spectra_luma(spectra_tex(src, in.uv + float2( t.x,  0.0)).rgb);
    float bl = spectra_luma(spectra_tex(src, in.uv + float2(-t.x,  t.y)).rgb);
    float bc = spectra_luma(spectra_tex(src, in.uv + float2( 0.0,  t.y)).rgb);
    float br = spectra_luma(spectra_tex(src, in.uv + float2( t.x,  t.y)).rgb);
    float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    float mag = sqrt(gx * gx + gy * gy);

    float thr = mix(0.04, 1.2, threshold);
    float band = mix(0.02, 0.7, softness);
    float ink = smoothstep(thr, thr + band, mag) * opacity;
    float3 processed = mix(c, inkColor, ink);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Halftone (Ben-Day)

// Rotated dot screen whose dots grow as the area darkens, gated to shadows/mids.
// params[0]=dot density, [1]=angle(deg), [2]=strength, [3]=coverage.
fragment float4 fx_style_halftone(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float density = max(2.0, u.params[0]);
    float angle = u.params[1] * 3.14159265 / 180.0;
    float strength = clamp(u.params[2], 0.0, 1.0);
    float coverage = clamp(u.params[3], 0.0, 1.0);

    float l = spectra_luma(c);
    float gate = 1.0 - smoothstep(coverage, coverage + 0.35, l);
    float pitch = max(2.0, 120.0 / density);
    float2 px = in.uv * u.resolution;
    float2 rot = spectra_rotate(px, angle);
    float2 cellUV = fract(rot / pitch) - 0.5;
    float dist = length(cellUV) * 2.0;
    float radius = sqrt(clamp(1.0 - l, 0.0, 1.0)) * gate;
    float dot = smoothstep(radius + 0.08, radius - 0.08, dist);
    float amt = dot * strength * gate;
    float3 processed = mix(c, c * 0.25, amt);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Cross-Hatch

// One darkening hatch layer at a given angle; opacity grows with how dark the
// region is. `coverage` widens the line as the area darkens.
inline float style_hatchLine(float2 px, float angleRad, float spacing, float coverage) {
    float2 r = spectra_rotate(px, angleRad);
    float v = fract(r.y / spacing);
    float lw = mix(0.06, 0.4, coverage);
    return 1.0 - smoothstep(lw, lw + 0.05, min(v, 1.0 - v) * 2.0);
}

// Directional pencil hatching keyed to brightness: layers cross at progressively
// darker tones. params[0]=spacing(px), [1]=strength, [2]=angle(deg).
fragment float4 fx_style_hatch(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float spacing = max(2.0, u.params[0]);
    float strength = clamp(u.params[1], 0.0, 1.0);
    float angle = u.params[2] * 3.14159265 / 180.0;
    float l = spectra_luma(c);
    float dark = 1.0 - l;
    float2 px = in.uv * u.resolution;
    float hatch = 0.0;
    hatch = max(hatch, style_hatchLine(px, angle, spacing, dark) * step(0.25, dark));
    hatch = max(hatch, style_hatchLine(px, angle + 1.5708, spacing, dark) * step(0.5, dark));
    hatch = max(hatch, style_hatchLine(px, angle + 0.7854, spacing * 0.8, dark) * step(0.72, dark));
    float amt = hatch * strength;
    float3 processed = mix(c, c * 0.15, amt);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Paper

// Procedural paper/canvas grain multiplied through the image. params[0]=intensity,
// [1]=grain scale, [2..4]=paper tint RGB (slot 5 = alpha, unused).
fragment float4 fx_style_paper(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float intensity = clamp(u.params[0], 0.0, 1.0);
    float scale = max(0.5, u.params[1]);
    float3 tint = float3(u.params[2], u.params[3], u.params[4]);
    float2 p = in.uv * u.resolution / 256.0 * scale * 8.0;
    float fiber = spectra_fbm(p, 4);
    float speck = spectra_valueNoise(p * 6.0);
    float grain = mix(fiber, speck, 0.35);
    float3 paper = tint * (0.85 + 0.3 * grain);
    float3 processed = mix(c, c * paper, intensity);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Impasto Relief

// Height-from-luminance directional lighting for raised thick-paint. params[0]=amount,
// [1]=height, [2]=light angle(deg).
fragment float4 fx_style_relief(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = clamp(u.params[0], 0.0, 1.0);
    float height = clamp(u.params[1], 0.0, 1.0) * 4.0 + 0.5;
    float angle = u.params[2] * 3.14159265 / 180.0;
    float2 t = u.texelSize;
    float hl = spectra_luma(spectra_tex(src, in.uv - float2(t.x, 0.0)).rgb);
    float hr = spectra_luma(spectra_tex(src, in.uv + float2(t.x, 0.0)).rgb);
    float hu = spectra_luma(spectra_tex(src, in.uv - float2(0.0, t.y)).rgb);
    float hd = spectra_luma(spectra_tex(src, in.uv + float2(0.0, t.y)).rgb);
    float3 n = normalize(float3((hl - hr) * height, (hu - hd) * height, 1.0));
    float3 lightDir = normalize(float3(cos(angle), sin(angle), 0.7));
    float diff = dot(n, lightDir);
    float shade = (diff - 0.55) * 1.4;
    float3 processed = clamp(c + shade * amount, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Cel Shade (abstraction -> bold flat tones -> ink from abstracted edges)

// Pass 0 (scale 0.5): strong edge-preserving abstraction. A 7x7 bilateral over the
// downsampled source flattens interiors into coherent regions while keeping real
// shape boundaries. Small text dissolves here, which is what keeps the ink pass
// (below) from tracing every glyph. params[5] = abstraction. Raw intermediate.
fragment float4 fx_style_cel_abstract(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float3 center = spectra_tex(src, in.uv).rgb;
    float abstraction = clamp(u.params[5], 0.0, 1.0);
    float2 t = u.texelSize * mix(1.0, 2.4, abstraction);
    float rangeSigma = mix(0.24, 0.09, abstraction);
    float invR2 = 1.0 / (2.0 * rangeSigma * rangeSigma);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int j = -3; j <= 3; j++) {
        for (int i = -3; i <= 3; i++) {
            float2 off = float2(float(i), float(j));
            float3 s = spectra_tex(src, in.uv + off * t).rgb;
            float spatial = exp(-dot(off, off) * 0.16);
            float3 d = s - center;
            float range = exp(-dot(d, d) * invR2);
            float w = spatial * range;
            sum += s * w;
            wsum += w;
        }
    }
    return float4(sum / max(wsum, 1e-4), 1.0);
}

// Pass 1 (scale 1.0): cel banding + ink. Bands the abstracted luminance into flat
// tones (snapping brightness while keeping hue), boosts saturation, then draws bold
// dark outlines from the abstracted image's edges. params[0]=tones, [1]=saturation,
// [2]=ink strength, [3]=ink width(px), [4]=edge softness, [5]=abstraction (unused here).
fragment float4 fx_style_cel_combine(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 absc = spectra_tex(src, in.uv).rgb;
    float bands = max(2.0, floor(u.params[0] + 0.5));
    float saturation = u.params[1];
    float inkStrength = clamp(u.params[2], 0.0, 1.0);
    float inkWidth = clamp(u.params[3], 0.5, 4.0);
    float smoothness = clamp(u.params[4], 0.0, 1.0);

    // Flat cel bands: quantize luminance, snap brightness, keep hue.
    float l = max(spectra_luma(absc), 1e-3);
    float scaled = l * bands;
    float lo = floor(scaled);
    float w = clamp(smoothness * 0.16, 0.012, 0.3);   // thin AA band: crisp flat cels, not a gradient
    float ql = (lo + smoothstep(0.5 - w, 0.5 + w, scaled - lo)) / bands;
    float3 cel = absc * (ql / l);
    float cl = spectra_luma(cel);
    cel = clamp(mix(float3(cl), cel, 1.0 + saturation), 0.0, 1.0);

    // Ink from the ABSTRACTED image's edges (text is already dissolved, so this
    // traces only major shape boundaries). Sobel on the half-res abstracted luma.
    float2 t = u.texelSize * inkWidth;
    float tl = spectra_luma(spectra_tex(src, in.uv + float2(-t.x, -t.y)).rgb);
    float tc = spectra_luma(spectra_tex(src, in.uv + float2( 0.0, -t.y)).rgb);
    float tr = spectra_luma(spectra_tex(src, in.uv + float2( t.x, -t.y)).rgb);
    float ml = spectra_luma(spectra_tex(src, in.uv + float2(-t.x,  0.0)).rgb);
    float mr = spectra_luma(spectra_tex(src, in.uv + float2( t.x,  0.0)).rgb);
    float bl = spectra_luma(spectra_tex(src, in.uv + float2(-t.x,  t.y)).rgb);
    float bc = spectra_luma(spectra_tex(src, in.uv + float2( 0.0,  t.y)).rgb);
    float br = spectra_luma(spectra_tex(src, in.uv + float2( t.x,  t.y)).rgb);
    float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    float mag = sqrt(gx * gx + gy * gy);
    float ink = smoothstep(0.15, 0.42, mag) * inkStrength;     // higher gate: only major contours, not every ripple
    float3 processed = mix(cel, float3(0.0, 0.0, 0.0), ink);   // pure black line art

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Comic / newsprint (texture-imposing: works on any content, even flat UI)

// Reuses fx_style_cel_abstract for the two abstraction passes (params[5]=abstraction),
// then prints the abstracted image as a halftone dot screen on paper with bold ink
// outlines. Unlike the cel look, this IMPOSES a material, so a flat desktop still
// reads as a comic page. All pixel-space sizes scale with resolution (params slots:
// 0 bands, 1 saturation, 2 inkStrength, 3 inkWidth, 4 dotDensity, 5 abstraction, 6 paper).
fragment float4 fx_style_comic_combine(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 absc = spectra_tex(src, in.uv).rgb;
    float bands = max(2.0, floor(u.params[0] + 0.5));
    float saturation = u.params[1];
    float inkStrength = clamp(u.params[2], 0.0, 1.0);
    float inkWidth = clamp(u.params[3], 0.5, 4.0);
    float dotDensity = clamp(u.params[4], 0.0, 1.0);
    float paper = clamp(u.params[6], 0.0, 1.0);
    float unit = max(u.resolution.y / 1000.0, 0.5);   // resolution-relative feature scale

    // Posterized flat ink color and a hard-quantized tone.
    float3 hsv = spectra_rgb2hsv(absc);
    float qv = floor(hsv.z * bands + 0.5) / bands;
    float s = clamp(hsv.y * (1.0 + saturation), 0.0, 1.0);
    float3 inkCol = spectra_hsv2rgb(float3(hsv.x, s, 1.0));

    // Halftone: ink coverage grows where the image is dark.
    float coverage = clamp(1.0 - qv, 0.0, 1.0);
    float pitch = mix(13.0, 5.0, dotDensity) * unit;
    float2 rot = spectra_rotate(in.uv * u.resolution, 0.4);
    float2 cell = fract(rot / pitch) - 0.5;
    float dist = length(cell) * 2.0;
    float dotR = sqrt(coverage);
    float dot = smoothstep(dotR + 0.14, dotR - 0.14, dist);

    // Print the dots: ink color on paper (paper=1) or on the flat color (paper=0).
    float3 paperTone = float3(0.95, 0.92, 0.85);
    float grain = spectra_valueNoise(in.uv * u.resolution / (2.5 * unit));
    paperTone *= (0.92 + 0.12 * grain);
    float3 inkShade = inkCol * 0.5;
    float3 printed = mix(paperTone, inkShade, dot);
    float3 flat = mix(inkCol, inkShade, dot);
    float3 comicColor = mix(flat, printed, paper);

    // Bold black outlines from the abstracted edges (resolution-relative width).
    float2 t = (mix(1.2, 3.5, (inkWidth - 0.5) / 3.5) * unit) * u.texelSize;
    float tl = spectra_luma(spectra_tex(src, in.uv + float2(-t.x, -t.y)).rgb);
    float tc = spectra_luma(spectra_tex(src, in.uv + float2( 0.0, -t.y)).rgb);
    float tr = spectra_luma(spectra_tex(src, in.uv + float2( t.x, -t.y)).rgb);
    float ml = spectra_luma(spectra_tex(src, in.uv + float2(-t.x,  0.0)).rgb);
    float mr = spectra_luma(spectra_tex(src, in.uv + float2( t.x,  0.0)).rgb);
    float bl = spectra_luma(spectra_tex(src, in.uv + float2(-t.x,  t.y)).rgb);
    float bc = spectra_luma(spectra_tex(src, in.uv + float2( 0.0,  t.y)).rgb);
    float br = spectra_luma(spectra_tex(src, in.uv + float2( t.x,  t.y)).rgb);
    float gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    float mag = sqrt(gx * gx + gy * gy);
    float ink = smoothstep(0.12, 0.36, mag) * inkStrength;
    comicColor = mix(comicColor, float3(0.05, 0.04, 0.04), ink);

    return spectra_compositeRGBA(base, comicColor, u);
}

// MARK: - SLIC superpixel painterly (faithful color, adaptive imposingness)

// Screen-space SLIC: each fragment finds the nearest superpixel among the 3x3 grid
// of cell centers (distance = color + spatial), then soft-blends the best and
// second-best so boundaries are painterly, not gridded. It samples REAL scene colors
// (so hues stay faithful), an evolving procedural warp gives organic stroke edges,
// and the cell size is in pixels so strokes scale with resolution. Imposingness is
// dialed DOWN where local contrast is high (text, dense UI) so they stay readable.
// Adapted from a depth-based Unity painterly shader to a pure fragment pass.
inline float2 slic_warp(float2 p, float t) {
    float a = spectra_simplex(p + float2(0.0, t * 0.30));
    float b = spectra_simplex(p + float2(t * 0.27, 11.7));
    return float2(a, b);
}
inline float3 slic_posterize(float3 c, float steps) {
    float n = max(1.0, steps);
    return floor(c * n) / n;
}

fragment float4 fx_style_slic(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 og = spectra_tex(orig, in.uv).rgb;
    float2 res = u.resolution;
    float2 texel = u.texelSize;
    float2 px = in.uv * res;

    float cellPx     = max(4.0, u.params[0]);
    float colorWeight= max(0.0, u.params[1]);
    float posterize  = u.params[2];
    float sceneBlend = clamp(u.params[3], 0.0, 1.0);
    float warpPx     = u.params[4];
    float noiseScale = max(0.01, u.params[5]);
    float noiseSpeed = u.params[6];
    float hueJitter  = clamp(u.params[7], 0.0, 1.0);
    float adapt      = clamp(u.params[8], 0.0, 1.0);

    // Evolving warp (organic stroke edges), expressed in pixels then converted to uv.
    float2 warp = slic_warp(in.uv * noiseScale * 6.0, u.time * noiseSpeed) * (warpPx * texel);

    float3 baseCol = slic_posterize(spectra_tex(src, in.uv + warp).rgb, posterize);

    float2 baseCell = floor(px / cellPx);
    float bestD = 1e20, secondD = 1e20;
    float3 bestCol = baseCol, secondCol = baseCol;
    float2 bestCell = baseCell;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 cellID = baseCell + float2(float(x), float(y));
            float2 centerPx = (cellID + 0.5) * cellPx;
            float3 c = slic_posterize(spectra_tex(src, centerPx * texel + warp).rgb, posterize);
            float dc = length(c - baseCol);
            float ds = length(centerPx - px) / cellPx;
            float d = dc * colorWeight + ds;
            if (d < bestD) { secondD = bestD; secondCol = bestCol; bestD = d; bestCol = c; bestCell = cellID; }
            else if (d < secondD) { secondD = d; secondCol = c; }
        }
    }
    // Soft ownership: blend 50/50 at a tie and ramp to the winner as the gap grows.
    // Centering on 0.5 (rather than picking second at a tie) keeps boundary pixels
    // from popping between two colors frame-to-frame (the "shattering").
    float gap = secondD - bestD;
    float wsoft = 0.5 + 0.5 * clamp(gap / 0.30, 0.0, 1.0);
    float3 slicCol = mix(secondCol, bestCol, wsoft);

    // Per-cell static hue jitter (painterly variation).
    if (hueJitter > 0.0) {
        float h = (spectra_hash21(bestCell) - 0.5) * hueJitter;
        float3 hsv = spectra_rgb2hsv(slicCol);
        hsv.x = fract(hsv.x + h);
        slicCol = spectra_hsv2rgb(hsv);
    }

    // Band-pass imposition by local detail (luma stddev over ~cell scale):
    //  - DEAD-FLAT areas get no SLIC, so they show the smooth original instead of the
    //    square cell grid (the "square pixels" artifact).
    //  - MID-detail (photos, gradients, texture) gets the full painterly strokes.
    //  - TEXT/dense UI backs off (controlled by `adapt`) so it stays readable.
    float2 d2 = texel * (cellPx * 0.35);
    float lc = spectra_luma(og);
    float l0 = spectra_luma(spectra_tex(orig, in.uv + float2( d2.x, 0.0)).rgb);
    float l1 = spectra_luma(spectra_tex(orig, in.uv + float2(-d2.x, 0.0)).rgb);
    float l2 = spectra_luma(spectra_tex(orig, in.uv + float2(0.0,  d2.y)).rgb);
    float l3 = spectra_luma(spectra_tex(orig, in.uv + float2(0.0, -d2.y)).rgb);
    float mean = (lc + l0 + l1 + l2 + l3) * 0.2;
    float varr = ((lc - mean) * (lc - mean) + (l0 - mean) * (l0 - mean)
                + (l1 - mean) * (l1 - mean) + (l2 - mean) * (l2 - mean)
                + (l3 - mean) * (l3 - mean)) * 0.2;
    float complexity = sqrt(varr);
    float flatGate = smoothstep(0.012, 0.05, complexity);                        // off in flat -> no grid
    float textGate = mix(1.0, 1.0 - smoothstep(0.20, 0.38, complexity), adapt);  // off in text -> readable
    float impose = flatGate * textGate;

    float3 outc = mix(og, slicCol, sceneBlend * impose);
    return spectra_compositeRGBA(og, outc, u);
}

// MARK: - Oil paint (colour-region cells on a smoothed structure tensor)

// The painterly look is built from colour-coherent cells (SLIC-style superpixels), not
// edge-preserving smoothing. A smoothed structure tensor gives the flow field; the cell
// pass assigns every pixel to a local cell and fills it flat, so flat areas merge into big
// strokes and busy areas keep small ones, boundaries snap to colour edges, and cells
// elongate along the flow. Sizes are fractions of screen height, so the look is the same at
// any resolution. Five passes (tensor + 2 blur to build the flow, cells at reduced res,
// combine at full res).

// Structure tensor (E=gx^2, G=gy^2, F=gx*gy) from a Sobel on luma.
fragment float4 fx_style_oil_tensor(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    // Sample the Sobel at a fixed FRACTION of the image (not 1 texel), so the gradient
    // is measured at the same physical scale at any resolution. Calibrated so the tap is
    // 1 texel at the 4K reference (tensor pass height 1080); larger at higher res. This
    // keeps the complexity/flow — and therefore the stroke sizing — resolution-invariant.
    float2 t = u.texelSize * max(1.0, u.resolution.y * 0.000926);
    // COLOUR structure tensor (Di Zenzo): the Sobel runs on RGB, not luma, so the flow
    // follows colour-region boundaries and the complexity catches iso-luminant colour
    // edges (text on a same-brightness UI, orange noodles on a blue plate). Per-channel
    // gradients are combined into the tensor; /3 keeps the magnitude near the old luma
    // scale so detailK stays calibrated.
    float3 tl = spectra_tex(src, in.uv + float2(-t.x, -t.y)).rgb;
    float3 tc = spectra_tex(src, in.uv + float2( 0.0, -t.y)).rgb;
    float3 tr = spectra_tex(src, in.uv + float2( t.x, -t.y)).rgb;
    float3 ml = spectra_tex(src, in.uv + float2(-t.x,  0.0)).rgb;
    float3 mr = spectra_tex(src, in.uv + float2( t.x,  0.0)).rgb;
    float3 bl = spectra_tex(src, in.uv + float2(-t.x,  t.y)).rgb;
    float3 bc = spectra_tex(src, in.uv + float2( 0.0,  t.y)).rgb;
    float3 br = spectra_tex(src, in.uv + float2( t.x,  t.y)).rgb;
    float3 gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
    float3 gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
    float E = dot(gx, gx), G = dot(gy, gy), F = dot(gx, gy);
    return float4(E, G, F, 3.0) / 3.0;
}

// Separable Gaussian blur of the tensor -> coherent flow.
fragment float4 fx_style_oil_blur(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    // Blur span scales with resolution (fixed image fraction) so flow coherence covers
    // the same region at any res. 1.5 texels at the 4K reference (tensor height 1080).
    float2 step = u.direction * u.texelSize * max(1.0, u.resolution.y * 0.001389);
    const float w0 = 0.227027, w1 = 0.194594, w2 = 0.121622, w3 = 0.054054, w4 = 0.016216;
    float3 sum = spectra_tex(src, in.uv).rgb * w0;
    sum += (spectra_tex(src, in.uv + step).rgb + spectra_tex(src, in.uv - step).rgb) * w1;
    sum += (spectra_tex(src, in.uv + 2.0 * step).rgb + spectra_tex(src, in.uv - 2.0 * step).rgb) * w2;
    sum += (spectra_tex(src, in.uv + 3.0 * step).rgb + spectra_tex(src, in.uv - 3.0 * step).rgb) * w3;
    sum += (spectra_tex(src, in.uv + 4.0 * step).rgb + spectra_tex(src, in.uv - 4.0 * step).rgb) * w4;
    return float4(sum, 1.0);
}

// One colour-region cell lookup at a given pitch: among a 3x3 neighbourhood of jittered seeds
// it picks the one nearest in a combined colour+space metric (the spatial term stretched along
// the flow so cells elongate into oriented brush marks), returning the winner's flat colour,
// the runner-up colour, the best/second distances (for the seam), and the winning cell id.
struct OilCell {
    float3 col;        // flat fill = winning seed colour
    float3 second;     // runner-up seed colour
    float  gap;        // secondD - bestD (small near a boundary)
    float2 id;         // winning cell id (for per-cell jitter)
};
inline OilCell oil_cell_at(texture2d<float> orig, sampler s, float2 qpx, float2 texel,
                           float cellPx, float3 pcol, float2 flow, float2 grad,
                           float stretch, float colorWeight, float adapt,
                           float correctAmt) {
    float2 baseCell = floor(qpx / cellPx);
    float bestD = 1e20, secondD = 1e20;
    float3 bestCol = pcol, secondCol = pcol;
    float2 bestCell = baseCell;
    const float2 ring[4] = { float2(1.0, 0.0), float2(-1.0, 0.0), float2(0.0, 1.0), float2(0.0, -1.0) };
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 cid = baseCell + float2(float(i), float(j));
            float2 h = float2(spectra_hash21(cid), spectra_hash21(cid + 7.7));
            // Static jitter kept modest (was 0.7) so it plus the mean-shift can't push a seed
            // out of its own cell (which made pixels misassign -> misplaced strokes).
            float2 seedPx = (cid + 0.5 + (h - 0.5) * 0.5) * cellPx;
            float3 scol = orig.sample(s, seedPx * texel).rgb;
            // CONTENT-ADAPTIVE seed: one mean-shift step toward the centroid of nearby
            // same-colour pixels. On a flat area the ring is symmetric so the seed stays put;
            // near an edge the similar-coloured side outweighs the other, so the seed slides
            // INTO its colour region and off the boundary. This dissolves the rigid screen
            // lattice and makes cells latch onto image features instead of grid positions.
            if (adapt > 0.0) {
                float2 acc = float2(0.0);
                float wPos = 1e-3;
                float3 colAcc = scol;   // edge-preserving colour average (centre weight 1)
                float wCol = 1.0;
                for (int k = 0; k < 4; k++) {
                    float2 d = ring[k] * (cellPx * 0.5);
                    float3 c = orig.sample(s, (seedPx + d) * texel).rgb;
                    // Gentle colour gate (was a steep *26 that latched onto a single noise
                    // outlier and shoved the seed toward noise): a wider gate averages a real
                    // neighbourhood, so the shift tracks the region centroid, not noise.
                    float wk = exp(-dot(c - scol, c - scol) * 14.0);
                    acc += d * wk;     wPos += wk;
                    colAcc += c * wk;  wCol += wk;
                }
                // Bound the shift to a fraction of a cell so seed + jitter can't leave the cell's
                // territory (must stay within the 3x3 search). This is the main misplaced-stroke fix.
                float2 shift = (acc / wPos) * adapt;
                float sl2 = dot(shift, shift);
                float maxShift = cellPx * 0.20;
                if (sl2 > maxShift * maxShift) shift *= maxShift * rsqrt(sl2);
                seedPx += shift;
                // De-noised cell colour: similar-colour neighbours averaged in, dissimilar ones
                // (across an edge) down-weighted. Stops each big flat-area cell from taking a
                // slightly different single-tap value — the blotchy low-contrast artifact.
                scol = colAcc / wCol;
            }
            float2 dp = qpx - seedPx;
            float al = dot(dp, flow);
            float ac = dot(dp, grad);
            float ds = length(float2(al / stretch, ac)) / cellPx;
            float dc = distance(scol, pcol);
            float dd = ds + colorWeight * dc;
            if (dd < bestD) {
                secondD = bestD; secondCol = bestCol;
                bestD = dd; bestCol = scol; bestCell = cid;
            } else if (dd < secondD) {
                secondD = dd; secondCol = scol;
            }
        }
    }
    // REGION-COHERENCE CORRECTION (coarse level only: correctAmt is 1 on the coarse call,
    // 0 on the fine and full-res calls). When the winning seed's colour diverges strongly
    // from the pixel's OWN colour, no seed landed inside this pixel's colour region — the
    // classic case of a UI block or text narrower than the coarse stroke pitch, whose
    // interior would otherwise inherit the SURROUNDING colour (every 3x3 candidate sits
    // outside the block). Pull the fill toward the pixel's own colour so the whole region
    // fills as ONE flat coarse stroke of the correct colour, with the fine level still
    // layering small strokes on top only at the true edges (where sizeT -> 1).
    //
    // Soft smoothstep gate, NOT a hard threshold: on smooth gradients and photo texture the
    // winning seed already matches the pixel (the colour metric picks the nearest-colour
    // seed), so distance(bestCol, pcol) is tiny and the gate reads ~0 — those areas are
    // untouched. It ramps to full only at a real colour step a coarse seed could not reach.
    // The runner-up colour is pulled by the same weight so oil_finish's seam term does not
    // fire spuriously inside the now-uniform interior. No new texture taps: pcol is already
    // in a register (the caller sampled orig at in.uv before calling).
    if (correctAmt > 0.0) {
        float orphan = correctAmt * smoothstep(0.10, 0.30, distance(bestCol, pcol));
        bestCol   = mix(bestCol, pcol, orphan);
        secondCol = mix(secondCol, pcol, orphan);
    }

    OilCell r;
    r.col = bestCol; r.second = secondCol; r.gap = secondD - bestD; r.id = bestCell;
    return r;
}

// Per-stroke finish shared by the reduced-res cell pass AND the full-res detail layer, so
// complex areas obey exactly the same stroke params as everywhere else (no separate path):
//  - broken-colour jitter, scaled by `painterly` so flat/low-contrast areas keep true colour;
//  - a seam that ramps up at real colour boundaries (faint baseline scaled by `painterly`);
//  - the edge smoother, anti-aliasing the boundary via the best/second `gap`.
inline float3 oil_finish(OilCell c, float painterly, float colorVar, float smoothAmt) {
    float3 col = c.col;
    // Local colour variety: how different this stroke is from its runner-up neighbour. It is ~0
    // in a flat region — INCLUDING one that merely sits next to a hard edge, where the blurred-
    // tensor edginess is high but every neighbouring cell is the same colour — and rises with
    // genuine texture and at real region edges. It gates all three painterly treatments below so
    // they fire on photos/foliage but NOT in the flat margin a high-contrast feature casts around
    // itself. Uses data already in OilCell (col, second): no extra texture taps.
    float contrast = distance(c.col, c.second);
    // Broken-colour jitter, gated by colour variety (texGate) ON TOP OF edginess (painterly).
    // edginess alone is high in the whole band a blurred hard edge throws into the surrounding
    // flat area, which is exactly where the jitter read as a speckled margin; texGate is ~0 there.
    float texGate = smoothstep(0.03, 0.12, contrast);
    float effVar = colorVar * painterly * texGate;
    if (effVar > 0.0) {
        float jh = spectra_hash21(c.id + 3.1) - 0.5;
        float js = spectra_hash21(c.id + 5.9) - 0.5;
        float3 hsv = spectra_rgb2hsv(col);
        hsv.x = fract(hsv.x + jh * 0.05 * effVar);
        hsv.y = clamp(hsv.y * (1.0 + js * 0.30 * effVar), 0.0, 1.0);
        hsv.z = clamp(hsv.z * (1.0 + jh * 0.26 * effVar), 0.0, 1.0);
        col = spectra_hsv2rgb(hsv);
    }
    // Seam is a BAND-PASS on contrast: it defines strokes at moderate boundaries (texture,
    // foliage) but fades back out past ~0.25 so hard UI edges get NO dark outline. Scaled by
    // `painterly`, so flat/low-contrast areas still get none.
    float seam = (1.0 - smoothstep(0.0, 0.28, c.gap)) * painterly
               * smoothstep(0.02, 0.12, contrast) * (1.0 - smoothstep(0.25, 0.48, contrast));
    col *= (1.0 - 0.09 * seam);
    if (smoothAmt > 0.0) {
        float wEdge = 0.04 + 0.18 * smoothAmt;
        // Anti-alias only boundaries between SIMILAR colours. Blending toward the runner-up
        // across a hard edge averages two distinct region colours into an intermediate tint
        // (green+blue -> teal), which is the desaturated halo around high-contrast features.
        // Where the two colours diverge, keep the edge crisp (weight -> 1.0 = this stroke's
        // own colour, no blend).
        float similar = 1.0 - smoothstep(0.10, 0.25, contrast);
        float wBlend = mix(1.0, 0.5 + 0.5 * smoothstep(0.0, wEdge, c.gap), similar);
        col = mix(c.second, col, wBlend);
    }
    return col;
}

// Structure tensor (E=gx^2, G=gy^2, F=gx*gy) -> flow tangent (along edges), gradient, and
// anisotropy. Shared by the cell pass (smoothed tensor) and the combine's full-res layer
// (locally-derived tensor) so the two never drift out of sync.
inline void oil_flow_from_tensor(float E, float G, float F,
                                 thread float2 &flow, thread float2 &grad, thread float &aniso) {
    float trace = E + G;
    float disc = sqrt(max((E - G) * (E - G) + 4.0 * F * F, 0.0));
    float lambda1 = 0.5 * (trace + disc);
    float2 g1 = float2(F, lambda1 - E);
    float2 g2 = float2(lambda1 - G, F);
    float2 graw = (dot(g1, g1) >= dot(g2, g2)) ? g1 : g2;
    grad = (dot(graw, graw) > 1e-12) ? normalize(graw) : float2(1.0, 0.0);
    flow = float2(-grad.y, grad.x);
    aniso = (trace > 1e-5) ? disc / trace : 0.0;
}

// Colour-region cells (the painting). Every pixel joins a local colour-coherent cell
// ("stroke") and takes that cell's flat colour. The cell SIZE is emergent from edge
// detection: the local structure-tensor edge magnitude drives a continuous level between a
// COARSE grid (big strokes in flat areas) and a FINE grid (small strokes at edges and over
// text), so detail naturally gets small marks with no separate text/readability gate. Two
// grid levels are evaluated and blended by the edge level, which keeps the size variation
// crack-free (each level is a globally consistent grid). Boundaries snap to colour edges, a
// procedural warp keeps edges organic, per-cell jitter adds broken colour, and a seam darkens
// stroke boundaries. tex0 = smoothed structure tensor (flow), tex1 = original colour.
fragment float4 fx_style_oil_cells(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 res = u.resolution;
    float2 texel = u.texelSize;
    float2 px = in.uv * res;

    // Slots: 0 strokeRange.lo, 1 strokeRange.hi, 2 colorVar, 3 temporal, 4 canvas,
    // 5 renderScale, 6 detail, 7 amount, 8 flow, 9 warp, 10 edgeSmooth.
    float rangeLo   = clamp(u.params[0], 0.0, 1.0);
    float rangeHi   = clamp(u.params[1], 0.0, 1.0);
    float colorVar  = clamp(u.params[2], 0.0, 1.0);
    float detail    = clamp(u.params[6], 0.0, 1.0);
    float flowAmt   = clamp(u.params[8], 0.0, 1.0);
    float warpAmt   = clamp(u.params[9], 0.0, 1.0);
    float smoothAmt = clamp(u.params[10], 0.0, 1.0);

    // Flow + anisotropy + edge magnitude from the smoothed structure tensor.
    float3 T = src.sample(s, in.uv).rgb;
    float trace = T.r + T.g;
    float2 flow, grad; float aniso;
    oil_flow_from_tensor(T.r, T.g, T.b, flow, grad, aniso);

    // Emergent size: edge magnitude -> a 0..1 "edginess". Edge Fidelity sets how little edge
    // it takes to drop to fine strokes (higher = detail kicks in sooner, more of the image
    // gets small marks). detailK is a fixed, resolution-invariant gradient sensitivity.
    float detailK = 9.0;
    float edginess = 1.0 - exp(-trace * detailK);
    float sizeT = smoothstep(0.0, mix(0.55, 0.12, detail), edginess);   // 0 flat -> 1 edge
    sizeT = smoothstep(0.3, 0.7, sizeT);   // narrow the mid band so the two tilings don't overlay-shimmer
    // Painterly perturbation (broken colour + seams) is scaled DOWN in flat / low-contrast
    // areas: there it reads as dirt on UI rather than brushwork, because the variation is large
    // relative to the local contrast. Textured areas (photos) keep the full effect.
    float painterly = smoothstep(0.03, 0.20, edginess);

    // Stroke pitch comes straight from the Brushstroke Size range (fraction of height, so the
    // visual size is resolution-independent): the upper handle drives the COARSE grid (flat
    // areas, big strokes) and the lower handle the FINE grid (complex areas, small strokes).
    float coarsePx = max(4.0, res.y * mix(0.0025, 0.055, max(rangeLo, rangeHi)));
    // The reduced-res cell pass can't resolve very tiny strokes (they alias/blur on upscale), so
    // its fine level is floored; the full-res combine layer renders the truly small min strokes
    // sharply in complex areas/text.
    float finePx   = max(3.0, res.y * max(0.006, mix(0.0025, 0.055, min(rangeLo, rangeHi))));

    // Stretch the spatial metric ALONG the flow so cells become oriented brush marks.
    float stretch = 1.0 + flowAmt * aniso * 2.6;
    float3 pcol = orig.sample(s, in.uv).rgb;

    // Colour weight per level: low on the coarse level so flat areas form big merged strokes;
    // higher on the fine level so small cells hug colour edges and text faithfully (this is
    // what keeps text legible — emergently, via tiny edge-hugging strokes, not a paste-back).
    float coarseCW = mix(1.6, 3.2, detail);
    float fineCW   = mix(5.0, 12.0, detail);

    // Organic, non-gridded edges: warp the lookup position by smooth low-freq noise. The noise
    // is sampled in FULL-RES pixels (px / passScale) so the organic shapes match between this
    // reduced-res pass and the full-res combine layer (otherwise their seams don't line up and
    // the blend looks ragged), and so the look doesn't change with Render Scale.
    float2 npx = px / max(u.passScale, 0.01);
    float2 wn = float2(spectra_valueNoise(npx * 0.06) - 0.5, spectra_valueNoise(npx * 0.06 + 19.3) - 0.5);

    // Coarse level gets the region-coherence correction (correctAmt=1): it is the level
    // that paints big flat fills, so it is where a sub-pitch block's interior bleeds the
    // surrounding colour. The fine level gets 0 — its small strokes already hug colour
    // edges via the high fineCW, and correcting it would vary colour per-pixel across text.
    OilCell cC = oil_cell_at(orig, s, px + wn * (warpAmt * coarsePx * 0.7), texel,
                             coarsePx, pcol, flow, grad, stretch, coarseCW, 0.45, 1.0);
    OilCell cF = oil_cell_at(orig, s, px + wn * (warpAmt * finePx * 0.7), texel,
                             finePx, pcol, flow, grad, stretch, fineCW, 0.45, 0.0);

    // Per-stroke finish (broken colour + seam + edge smoother), applied per level via the
    // shared helper so the cell pass and the full-res detail layer behave identically.
    float3 colC = oil_finish(cC, painterly, colorVar, smoothAmt);
    float3 colF = oil_finish(cF, painterly, colorVar, smoothAmt);

    // Blend coarse -> fine by the emergent edge level. Crack-free: both levels are consistent
    // global grids, so only the blend weight varies across the image.
    float3 cell = mix(colC, colF, sizeT);
    return float4(cell, 1.0);
}

// Combine: upsample the reduced-res cell painting, multiply a faint canvas tooth, blend to
// the original by Amount, and damp over time for live content. There is NO readability gate:
// text legibility is emergent (the cell pass gives text small edge-hugging strokes), not a
// paste-back of the original. tex0 = cells (reduced res), tex1 = original, tex10 = previous.
fragment float4 fx_style_oil_combine(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     texture2d<float> tensorTex [[texture(9)]],
                                     texture2d<float> history [[texture(10)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 og = spectra_tex(orig, in.uv).rgb;
    float amount = clamp(u.params[7], 0.0, 1.0);
    float temporal = clamp(u.params[3], 0.0, 0.95);
    float canvas = clamp(u.params[4], 0.0, 1.0);

    float3 painted = spectra_tex(src, in.uv).rgb;
    float2 px = in.uv * u.resolution;

    // LOCAL FULL-RES STROKES ("render scale scaled by complexity"). The cell pass runs at a
    // reduced scale, so its fine strokes are upsampled and blur in complex areas. Here, at FULL
    // resolution, where complexity is high, RE-PAINT the SAME fine-level strokes at full res and
    // blend them over the upsampled base. Identical stroke logic (oil_cell_at + oil_finish, same
    // colour weight, size, flow, warp, jitter, seam, edge-smoother), just sharper, so complex
    // areas obey every param exactly like the rest of the image — NOT a separate path.
    float detail    = clamp(u.params[6], 0.0, 1.0);
    float colorVar  = clamp(u.params[2], 0.0, 1.0);
    float smoothAmt = clamp(u.params[10], 0.0, 1.0);
    {
        constexpr sampler s2(address::clamp_to_edge, filter::linear);
        // Reuse the SMOOTHED structure tensor (pass 2, tapped at texture(9)) for flow + edginess
        // instead of recomputing a raw Sobel here. Same stable input and the same detailK as the
        // cell pass, so the full-res layer's orientation and stroke-size thresholds match the cell
        // pass exactly (a raw full-res Sobel was noisier and inconsistent — the janky-stroke source).
        float3 T = tensorTex.sample(s2, in.uv).rgb;
        float E = T.r, G = T.g, F = T.b;
        float trace = E + G;
        float edginess = 1.0 - exp(-trace * 9.0);
        // Blend the full-res strokes in over the upsampled base wherever complexity is high
        // enough that the reduced-res version blurs (the cell pass already paints these areas;
        // this just re-renders them sharply with the same params).
        float wFull = smoothstep(0.30, 0.65, edginess);
        if (wFull > 0.01) {
            float2 flow, grad; float aniso;
            oil_flow_from_tensor(E, G, F, flow, grad, aniso);
            float rangeLo = clamp(u.params[0], 0.0, 1.0);
            float flowAmt = clamp(u.params[8], 0.0, 1.0);
            float warpAmt = clamp(u.params[9], 0.0, 1.0);
            float stretch = 1.0 + flowAmt * aniso * 2.6;
            // Full-res strokes at the MIN size (the range's lower handle), so complex areas/text
            // are rendered from the user's smallest strokes, sharply. Same stroke logic as the
            // cell pass; the user's min size controls text tightness directly (no separate tighten).
            float finePx = max(2.5, u.resolution.y * mix(0.0025, 0.055, rangeLo));
            // A touch more colour weight than the cell pass so the smallest strokes hug glyph
            // colour and text stays legible.
            float fineCW = mix(6.0, 13.0, detail);
            float painterly = smoothstep(0.03, 0.20, edginess);    // ~1 in complex areas
            float2 wn = float2(spectra_valueNoise(px * 0.06) - 0.5, spectra_valueNoise(px * 0.06 + 19.3) - 0.5);
            OilCell cd = oil_cell_at(orig, s2, px + wn * (warpAmt * finePx * 0.7), u.texelSize,
                                     finePx, og, flow, grad, stretch, fineCW, 0.45, 0.0);
            float3 fineCol = oil_finish(cd, painterly, colorVar, smoothAmt);
            painted = mix(painted, fineCol, wFull);
        }
    }

    // Canvas tooth: real linen, not a perfect computer grid. The over/under weave is
    // there, but the thread grid WAVERS (low-freq warp), each thread gets its own slight
    // brightness (irregular dye/thickness), and multi-octave fibre grain rides on top.
    // The irregularity is what stops it reading as a synthetic mesh.
    if (canvas > 0.0) {
        float cs = max(3.0, 0.0042 * u.resolution.y);          // thread pitch (~9 px at 4K)
        // Waver the weave coordinates so threads aren't a dead-straight periodic grid.
        float2 wob = float2(spectra_valueNoise(px * 0.012),
                            spectra_valueNoise(px * 0.012 + 31.7)) - 0.5;
        float2 cp = px / cs + wob * 1.4;
        float warp = 0.5 + 0.5 * cos(cp.x * 6.2831853);        // over/under linen weave
        float weft = 0.5 + 0.5 * cos(cp.y * 6.2831853);
        float chk = step(0.5, fract(floor(cp.x) * 0.5 + floor(cp.y) * 0.5));
        float weave = mix(warp, weft, chk) - 0.5;
        float threadVar = spectra_valueNoise(floor(cp) * 1.7 + 0.5) - 0.5;  // per-thread irregularity
        float fibre = (spectra_valueNoise(px / (cs * 0.40)) * 0.6           // coarse + fine fibres
                     + spectra_valueNoise(px / (cs * 0.16) + 9.0) * 0.4) - 0.5;
        float c = weave * 0.55 + threadVar * 0.28 + fibre * 0.55;
        painted *= (1.0 + c * 0.32 * canvas);
    }

    float3 outc = mix(og, painted, amount);

    // Temporal damping for live/animated content (stops boiling).
    float3 hist = spectra_tex(history, in.uv).rgb;
    outc = mix(outc, hist, temporal);

    return spectra_compositeRGBA(og, outc, u);
}

// MARK: - Painterly (half-res Kuwahara; used by the Studio Ghibli and Watercolor worlds)

// Pass 0 (scale 0.5): edge-preserving smooth + downsample. Raw intermediate.
fragment float4 fx_style_painterly_pre(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]]) {
    float3 center = spectra_tex(src, in.uv).rgb;
    float2 t = u.texelSize;
    float rangeSigma = 0.18;
    float invR2 = 1.0 / (2.0 * rangeSigma * rangeSigma);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 off = float2(float(i), float(j));
            float3 s = spectra_tex(src, in.uv + off * t).rgb;
            float spatial = exp(-dot(off, off) * 0.3);
            float3 d = s - center;
            float range = exp(-dot(d, d) * invR2);
            float w = spatial * range;
            sum += s * w;
            wsum += w;
        }
    }
    return float4(sum / max(wsum, 1e-4), 1.0);
}

// Pass 1 (scale 0.5): generalized anisotropic Kuwahara. A 3×3 Sobel builds the
// local structure tensor; the sampling disk is elongated along the edge and split
// into 8 angular sectors; the low-variance sectors dominate the result.
// params[0]=radius, [1]=anisotropy, [2]=sharpness. Raw intermediate.
fragment float4 fx_style_painterly_kuwahara(RasterizerData in [[stage_in]],
                                            texture2d<float> src [[texture(0)]],
                                            texture2d<float> orig [[texture(1)]],
                                            constant SpectraUniforms &u [[buffer(0)]]) {
    float radius = clamp(u.params[0], 1.0, 8.0);
    float anisoAmt = clamp(u.params[1], 0.0, 1.0);
    float sharpness = clamp(u.params[2], 0.0, 1.0);
    float2 t = u.texelSize;

    // Structure tensor from a 3×3 Sobel on luma.
    float lum[9];
    int k = 0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            lum[k++] = spectra_luma(spectra_tex(src, in.uv + float2(float(i), float(j)) * t).rgb);
        }
    }
    float gx = (lum[2] + 2.0 * lum[5] + lum[8]) - (lum[0] + 2.0 * lum[3] + lum[6]);
    float gy = (lum[6] + 2.0 * lum[7] + lum[8]) - (lum[0] + 2.0 * lum[1] + lum[2]);
    float gx2 = gx * gx, gy2 = gy * gy, gxy = gx * gy;
    float trace = gx2 + gy2;
    float disc = sqrt(max(trace * trace * 0.25 - (gx2 * gy2 - gxy * gxy), 0.0));
    float lambda1 = trace * 0.5 + disc;
    float lambda2 = trace * 0.5 - disc;
    // Major eigenvector (gradient direction). Both closed forms degenerate to the
    // zero vector on one axis (e1 on horizontal edges, e2 on vertical edges), so
    // pick the better-conditioned one; a zero vector would normalise to NaN and
    // corrupt every sample for the pixel. Horizontal/vertical edges are everywhere.
    float2 e1 = float2(lambda1 - gy2, gxy);
    float2 e2 = float2(gxy, lambda1 - gx2);
    float2 raw = (dot(e1, e1) >= dot(e2, e2)) ? e1 : e2;
    float2 grad = (dot(raw, raw) > 1e-12) ? normalize(raw) : float2(1.0, 0.0);
    float2 edgeDir = float2(-grad.y, grad.x);   // perpendicular to gradient = along the edge
    float anisotropy = (lambda1 + lambda2 > 1e-5) ? (lambda1 - lambda2) / (lambda1 + lambda2) : 0.0;
    float2 major = edgeDir;   // elongate strokes along the edge
    float2 minor = grad;      // and compress across it
    float majorR = radius * mix(1.0, 1.0 + 3.0 * anisotropy, anisoAmt);
    float minorR = radius / mix(1.0, 1.0 + anisotropy, anisoAmt);

    float3 mean[8];
    float3 mom[8];
    float wsum8[8];
    for (int s = 0; s < 8; s++) { mean[s] = float3(0.0); mom[s] = float3(0.0); wsum8[s] = 0.0; }

    int R = int(ceil(radius));
    float invR = 1.0 / max(radius, 1.0);
    for (int j = -R; j <= R; j++) {
        for (int i = -R; i <= R; i++) {
            float2 o = float2(float(i), float(j));
            float r2 = dot(o, o);
            if (r2 > radius * radius) continue;
            float ang = atan2(o.y, o.x) + 3.14159265;
            int sec = int(ang / 6.2831853 * 8.0) & 7;
            // Warp the screen-space offset into the oriented ellipse: project onto the
            // major/minor axes, scale each, then rebuild in screen space. (Scaling
            // o.x/o.y directly would only elongate along the screen axes, breaking the
            // "stroke follows the edge" property for non-axis-aligned edges.)
            float oa = dot(o, major);
            float ob = dot(o, minor);
            float2 pos = major * (oa * (majorR * invR)) + minor * (ob * (minorR * invR));
            float3 col = spectra_tex(src, in.uv + pos * t).rgb;
            float wg = exp(-r2 * invR * invR * 1.5);
            mean[sec] += col * wg;
            mom[sec] += col * col * wg;
            wsum8[sec] += wg;
        }
    }

    float q = mix(2.0, 8.0, sharpness);
    float3 result = float3(0.0);
    float totalW = 0.0;
    for (int s = 0; s < 8; s++) {
        if (wsum8[s] < 1e-4) continue;
        float3 m = mean[s] / wsum8[s];
        float3 var = abs(mom[s] / wsum8[s] - m * m);
        float sigma = var.x + var.y + var.z;
        float w = 1.0 / (1.0 + pow(sigma * 64.0, q * 0.5));
        result += m * w;
        totalW += w;
    }
    float3 painted = (totalW > 1e-4) ? result / totalW : spectra_tex(src, in.uv).rgb;
    return float4(painted, 1.0);
}

// Pass 2 (scale 1.0): bicubic upsample of the half-res paint, with a little
// original high-frequency luma folded back for legibility. params[3]=detail.
fragment float4 fx_style_painterly_resolve(RasterizerData in [[stage_in]],
                                           texture2d<float> src [[texture(0)]],
                                           texture2d<float> orig [[texture(1)]],
                                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    // Use the real source dimensions for the bicubic taps rather than assuming the
    // upstream passes ran at exactly half resolution.
    float2 srcSize = float2(float(src.get_width()), float(src.get_height()));
    float3 painted = spectra_bicubic(src, in.uv, srcSize).rgb;
    float detail = clamp(u.params[3], 0.0, 1.0);
    float hf = spectra_luma(base) - spectra_luma(painted);
    painted += hf * detail;
    float3 processed = clamp(painted, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}
