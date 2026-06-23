// Style.metal
//
// Artistic stylization passes for the "world" presets (see docs/WORLDS.md):
// edge-preserving smooth, cel quantize, ink contours, Ben-Day halftone,
// cross-hatch, paper grain, impasto relief, and the oil-cell painter. Parameter
// slots match each descriptor's declaration order in
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

    // Form-following: steer the hatch along local iso-contours (perpendicular to the luma
    // gradient) so strokes wrap shapes instead of running at one fixed screen angle. A 3x3
    // Sobel gives the gradient; the rotation is gated by gradient strength so flat areas keep
    // the fixed angle (no orientation noise), and is blended as direction vectors so the
    // pi-periodic hatch lines never flip 180 degrees.
    float2 gt = u.texelSize * max(1.0, u.resolution.y * 0.0012);
    float a00 = spectra_luma(spectra_tex(src, in.uv + float2(-gt.x, -gt.y)).rgb);
    float a10 = spectra_luma(spectra_tex(src, in.uv + float2( 0.0, -gt.y)).rgb);
    float a20 = spectra_luma(spectra_tex(src, in.uv + float2( gt.x, -gt.y)).rgb);
    float a01 = spectra_luma(spectra_tex(src, in.uv + float2(-gt.x,  0.0)).rgb);
    float a21 = spectra_luma(spectra_tex(src, in.uv + float2( gt.x,  0.0)).rgb);
    float a02 = spectra_luma(spectra_tex(src, in.uv + float2(-gt.x,  gt.y)).rgb);
    float a12 = spectra_luma(spectra_tex(src, in.uv + float2( 0.0,  gt.y)).rgb);
    float a22 = spectra_luma(spectra_tex(src, in.uv + float2( gt.x,  gt.y)).rgb);
    float sgx = (a20 + 2.0 * a21 + a22) - (a00 + 2.0 * a01 + a02);
    float sgy = (a02 + 2.0 * a12 + a22) - (a00 + 2.0 * a10 + a20);
    float gmag = sqrt(sgx * sgx + sgy * sgy);
    float follow = smoothstep(0.06, 0.30, gmag);
    float2 fixedDir = float2(cos(angle), sin(angle));
    float2 formDir = (gmag > 1e-5) ? normalize(float2(-sgy, sgx)) : fixedDir;
    if (dot(formDir, fixedDir) < 0.0) formDir = -formDir;
    float2 dir = normalize(mix(fixedDir, formDir, follow));
    angle = atan2(dir.y, dir.x);

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
// [1]=grain scale, [2..4]=paper tint RGB (slot 5 = alpha, unused), [6]=drift speed.
fragment float4 fx_style_paper(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               texture2d<float> history [[texture(10)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float intensity = clamp(u.params[0], 0.0, 1.0);
    float scale = max(0.5, u.params[1]);
    float3 tint = float3(u.params[2], u.params[3], u.params[4]);
    float drift = clamp(u.params[6], 0.0, 1.0);
    float2 p = in.uv * u.resolution / 256.0 * scale * 8.0;

    float fiber, speck;
    if (drift > 0.0) {
        // Slowly crawl the grain, faster where the frame is moving. Local motion is the distance
        // from the previous frame's output (history): the paper settles where the screen is still
        // and shimmers where content moves. Two coherent drift fields (slow + fast) are mixed by
        // the spatially smooth motion field, so the speed varies without per-pixel shear. Motion-led
        // by design, so a static screen barely moves and needs no forced idle redraw.
        float motion = smoothstep(0.015, 0.30, distance(c, spectra_tex(history, in.uv).rgb));
        float2 d = float2(0.6, 0.8) * (u.time * drift * 0.25);
        fiber = mix(spectra_fbm(p + d, 4), spectra_fbm(p + d * 5.0, 4), motion);
        speck = spectra_valueNoise((p + d) * 6.0);
    } else {
        fiber = spectra_fbm(p, 4);
        speck = spectra_valueNoise(p * 6.0);
    }
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

// Pass 0 (scale 0.7): strong edge-preserving abstraction. A 7x7 bilateral over the
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

    // Sobel on the abstracted luma (drives the ink).
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

    // Flat cel bands, a FIXED count (a per-pixel-varying band count read off the noisy gradient was
    // the source of the speckle/noise). Quantize luminance, snap brightness, keep hue, with a soft
    // transition; then a partial blend back toward the continuous abstracted colour takes the hard
    // step-contours off the bands so smooth gradients (sky, ocean) don't read as harsh BANDING.
    float l = max(spectra_luma(absc), 1e-3);
    float scaled = l * bands;
    float lo = floor(scaled);
    // `smoothness` is the soft<->hard lever: at low values the bands are crisp/flat (woodblock
    // print), at high values the transition widens AND the tone blends partway back toward the
    // continuous abstracted colour, giving a soft painterly look (anime background). A small floor
    // keeps even the hard end from boiling.
    float w = clamp(0.05 + smoothness * 0.30, 0.04, 0.40);
    float ql = (lo + smoothstep(0.5 - w, 0.5 + w, scaled - lo)) / bands;
    float3 cel = absc * (ql / l);
    cel = mix(cel, absc, clamp(0.08 + smoothness * 0.5, 0.0, 0.6));   // soften toward continuous
    float cl = spectra_luma(cel);
    cel = clamp(mix(float3(cl), cel, 1.0 + saturation), 0.0, 1.0);

    // Ink from the abstracted edges (off when inkStrength = 0; style.lineart draws the lines).
    float ink = smoothstep(0.15, 0.42, mag) * inkStrength;
    float3 processed = mix(cel, float3(0.0, 0.0, 0.0), ink);

    return spectra_compositeRGBA(base, processed, u);
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
    // Early-out for homogeneous cells: two cheap neighbour taps estimate local colour variance.
    // In flat areas (UI panels, solid fills) the mean-shift ring shifts ~0 for every seed, so
    // all 36 ring taps are wasted. Skip them when the neighbourhood is already uniform.
    // Uses 2 taps; saves 36 taps per call in flat regions (the common case on a desktop).
    bool doAdapt = false;
    if (adapt > 0.0) {
        float3 nb0 = orig.sample(s, (qpx + float2( cellPx * 0.5,  cellPx * 0.5)) * texel).rgb;
        float3 nb1 = orig.sample(s, (qpx + float2(-cellPx * 0.5, -cellPx * 0.5)) * texel).rgb;
        doAdapt = max(distance(nb0, pcol), distance(nb1, pcol)) > 0.025;
    }
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
            if (doAdapt) {
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
inline float3 oil_finish(OilCell c, float painterly, float smoothAmt,
                         float pooling, float pigmentDesat, float vanGogh) {
    float3 col = c.col;
    // Local colour variety: how different this stroke is from its runner-up neighbour. It is ~0 in
    // a flat region — INCLUDING one that merely sits next to a hard edge, where the blurred-tensor
    // edginess is high but every neighbouring cell is the same colour — and rises with genuine
    // texture and at real region edges. It gates the painterly treatments below (divisionism,
    // pastel pull, seam) so they fire on photos/foliage but NOT in the flat margin a high-contrast
    // feature casts around itself. Uses data already in OilCell (col, second): no extra taps.
    float contrast = distance(c.col, c.second);
    float texGate = smoothstep(0.03, 0.12, contrast);
    // Van Gogh divisionism. Split each stroke into a saturated warm/cool variant whose per-cell
    // offset is ZERO-MEAN across neighbours, so a patch of strokes optically mixes back to the
    // TRUE colour (the eye, and the reduced-res cell averaging, low-pass them) while each
    // individual mark is vivid and hue-shifted — the broken-colour shimmer. The push is applied
    // to the zero-luma CHROMA component only, with luma re-added, so value composes exactly and
    // only colour vibrates. Gated by `painterly` so flat UI gets none, by texGate so it is
    // strongest where there is genuine colour variety, and tapered near pure black/white so text
    // and white fills are never tinted (protects legibility and bounds the clamp bias).
    if (vanGogh > 0.0 && painterly > 0.0) {
        float L = spectra_luma(col);
        // Perceived saturation ~ chroma / brightness, so a fixed absolute chroma offset reads as a
        // rainbow on dark pixels (e.g. a transparent window's wallpaper tint) yet is invisible on
        // bright ones. Scale the push with luma so the broken-colour SATURATION is even across the
        // tonal range: dark areas get a proportionally smaller offset, mids and lights stay full
        // (lights are then bounded by the gamut fit below). lumaScale is a function of the base
        // colour, so it is uniform across a same-colour patch and the offset stays zero-mean — the
        // patch still composes the true colour.
        float lumaScale = smoothstep(0.0, 0.45, L);
        float rho = vanGogh * painterly * (0.5 + 0.5 * texGate) * lumaScale;
        if (rho > 0.0) {
            float3 chroma = col - L;
            // Two zero-mean per-cell selectors from the cell id hash: one warm<->cool, one a
            // magenta<->green scatter for hue variety. The axes are projected onto the
            // luma-NEUTRAL plane (dot with the Rec.709 luma weights is 0), so the push moves
            // chroma only, not brightness, and value composes exactly. E[selector] = 0, so
            // E[offset] = 0: the neighbourhood average returns the TRUE colour while each stroke
            // is a saturated, hue-shifted variant (|chroma + offset| averaged > |chroma|).
            float t1 = spectra_hash21(c.id + 12.7) - 0.5;
            float t2 = spectra_hash21(c.id + 27.3) - 0.5;
            const float3 warmCool = float3( 0.575, -0.033, -0.658);   // orange <-> blue, luma-neutral
            const float3 scatter  = float3( 0.592, -0.309,  0.114);   // magenta <-> green, luma-neutral
            float3 off = (t1 * warmCool + t2 * scatter) * (1.3 * rho);
            // Keep the offset inside the RGB gamut so it NEVER clips. Clipping is the only thing
            // that would bias the average off the true colour (a near-white/near-saturated stroke
            // would clamp on one side but not the other). Scale the offset by the tightest
            // per-channel margin, bounded by the worst-case offset `amp` (a function of the base
            // colour + rho, so the scale is uniform across a same-colour patch and stays
            // zero-mean -> still composes the true colour). This also fades the effect smoothly on
            // already-saturated, black, and white pixels, so text and flat UI keep true colour
            // with no separate luma taper.
            float3 amp = float3(0.759, 0.222, 0.502) * rho;   // max |off| per channel at this rho
            float3 margin = min(col, 1.0 - col);
            float fit = min(1.0, min(margin.x / (amp.x + 1e-4),
                            min(margin.y / (amp.y + 1e-4), margin.z / (amp.z + 1e-4))));
            col = clamp(L + chroma + off * fit, 0.0, 1.0);
        }
    }
    // Pastel pull: desaturate toward luma, gated by the same colour-variety term (texGate)
    // as the jitter so flat/low-contrast UI keeps true colour. 0 = identity.
    if (pigmentDesat > 0.0) {
        col = mix(col, float3(spectra_luma(col)), pigmentDesat * texGate);
    }
    // Seam is a BAND-PASS on contrast: it defines strokes at moderate boundaries (texture,
    // foliage) but fades back out past ~0.25 so hard UI edges get NO dark outline. Scaled by
    // `painterly`, so flat/low-contrast areas still get none.
    float seam = (1.0 - smoothstep(0.0, 0.28, c.gap)) * painterly
               * smoothstep(0.02, 0.12, contrast) * (1.0 - smoothstep(0.25, 0.48, contrast));
    // Pigment Pooling amplifies the boundary darkening (watercolor pigment settling at
    // wash edges); pooling = 0 keeps the original 0.09 coefficient (identity). Van Gogh deepens
    // the same seam so adjacent strokes read as discrete raised marks (impasto separation).
    col *= (1.0 - 0.09 * mix(1.0, 3.2, pooling) * (1.0 + vanGogh) * seam);
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
// Local "van Gogh ripple" (Painting §7.1): while the button is HELD, boost the oil's vanGogh
// parameter in a soft, rippling disc around the CURRENT cursor — the brushwork there gets visibly
// more agitated (longer directional strokes + more broken colour), exactly as if you turned the
// Van Gogh dial up just where you paint. Reads the injected pointer block (slots 16–45); returns 0
// when no button is held, so a still painting is unaffected.
inline float oil_pressLive(constant SpectraUniforms &u) {
    float pressActive = u.params[19], releaseAge = u.params[20];
    return pressActive > 0.5 ? 1.0 : clamp(1.0 - releaseAge / 0.15, 0.0, 1.0);
}
inline float2 oil_pressPoint(constant SpectraUniforms &u) {
    return (u.params[21] >= 1.0) ? float2(u.params[22], u.params[23])   // newest trail point (current cursor)
                                 : float2(u.params[16], u.params[17]);  // else the press point
}
inline float oil_vanGoghBoost(constant SpectraUniforms &u, float2 uv) {
    float live = oil_pressLive(u);
    if (live <= 0.0) return 0.0;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 d = uv - oil_pressPoint(u); d.x *= aspect;
    float dist = length(d);
    float disc = smoothstep(0.16, 0.0, dist);                  // tighter falloff (~0.16 UV) — a smaller, concentrated area
    float ripple = 0.75 + 0.25 * sin(dist * 16.0 - u.time * 4.0); // concentric rings
    return disc * ripple * live * 1.8;                         // stronger boost added to vanGogh (cap raised below)
}

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

    // Slots: 0 strokeRange.lo, 1 strokeRange.hi, 2 temporal, 3 canvas, 4 renderScale,
    // 5 detail, 6 amount, 7 flow, 8 warp, 9 edgeSmooth, 10 pooling,
    // 11 wetBleed (combine only), 12 pigmentDesat, 13 vanGogh.
    float rangeLo   = clamp(u.params[0], 0.0, 1.0);
    float rangeHi   = clamp(u.params[1], 0.0, 1.0);
    float detail    = clamp(u.params[5], 0.0, 1.0);
    float flowAmt   = clamp(u.params[7], 0.0, 1.0);
    float warpAmt   = clamp(u.params[8], 0.0, 1.0);
    float smoothAmt = clamp(u.params[9], 0.0, 1.0);
    float pooling      = clamp(u.params[10], 0.0, 1.0);
    float pigmentDesat = clamp(u.params[12], 0.0, 1.0);
    float vanGogh      = min(2.0, max(u.params[13], 0.0) + oil_vanGoghBoost(u, in.uv));   // + local held-cursor ripple (stronger cap)

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

    // Stretch the spatial metric ALONG the flow so cells become oriented brush marks. Van Gogh
    // elongates them further (longer directional strokes that follow the forms). Flat areas have
    // ~0 anisotropy, so they stay round and rely on the divisionist colour, not fake direction.
    float stretch = 1.0 + flowAmt * aniso * (2.6 + vanGogh * 3.5);
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

    // SHAPE noise for flat regions: where there is little structural flow, cells default to
    // square Voronoi blocks. Add a lower-frequency organic warp whose strength RAMPS UP as the
    // stroke gets "square" (low anisotropy), so flat areas flow into wavy painterly shapes
    // instead of blocks. Directional/textured areas (high aniso) are untouched — they already
    // flow via the stretch. Uniform UI is unaffected (warping a flat colour region is a no-op).
    float squareness = 1.0 - smoothstep(0.04, 0.30, aniso);
    float2 flowy = float2(spectra_valueNoise(npx * 0.011 + 4.7) - 0.5,
                          spectra_valueNoise(npx * 0.011 + 27.1) - 0.5);
    wn += flowy * (1.8 * squareness);

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
    float3 colC = oil_finish(cC, painterly, smoothAmt, pooling, pigmentDesat, vanGogh);
    float3 colF = oil_finish(cF, painterly, smoothAmt, pooling, pigmentDesat, vanGogh);

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
    float amount = clamp(u.params[6], 0.0, 1.0);
    float temporal = clamp(u.params[2], 0.0, 0.95);
    float canvas = clamp(u.params[3], 0.0, 1.0);

    float3 painted = spectra_tex(src, in.uv).rgb;
    float2 px = in.uv * u.resolution;

    // LOCAL FULL-RES STROKES ("render scale scaled by complexity"). The cell pass runs at a
    // reduced scale, so its fine strokes are upsampled and blur in complex areas. Here, at FULL
    // resolution, where complexity is high, RE-PAINT the SAME fine-level strokes at full res and
    // blend them over the upsampled base. Identical stroke logic (oil_cell_at + oil_finish, same
    // colour weight, size, flow, warp, seam, edge-smoother), just sharper, so complex areas obey
    // every param exactly like the rest of the image — NOT a separate path.
    float detail    = clamp(u.params[5], 0.0, 1.0);
    float smoothAmt = clamp(u.params[9], 0.0, 1.0);
    float pooling      = clamp(u.params[10], 0.0, 1.0);
    float pigmentDesat = clamp(u.params[12], 0.0, 1.0);
    float vanGogh      = min(2.0, max(u.params[13], 0.0) + oil_vanGoghBoost(u, in.uv));   // + local held-cursor ripple (stronger cap)
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
            float flowAmt = clamp(u.params[7], 0.0, 1.0);
            float warpAmt = clamp(u.params[8], 0.0, 1.0);
            float stretch = 1.0 + flowAmt * aniso * (2.6 + vanGogh * 3.5);
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
            float3 fineCol = oil_finish(cd, painterly, smoothAmt, pooling, pigmentDesat, vanGogh);
            painted = mix(painted, fineCol, wFull);
        }
    }

    // Wet bleed: a small feather of the painted layer for watercolor diffusion. Guarded so
    // 0 is identity (no extra taps); a tiny ±0.75-texel box, NOT a second full blur pass.
    float wetBleed = clamp(u.params[11], 0.0, 1.0);
    if (wetBleed > 0.001) {
        float2 fb = u.texelSize * 0.75;
        float3 bleed = spectra_tex(src, in.uv + float2( fb.x, 0.0)).rgb
                     + spectra_tex(src, in.uv + float2(-fb.x, 0.0)).rgb
                     + spectra_tex(src, in.uv + float2(0.0,  fb.y)).rgb
                     + spectra_tex(src, in.uv + float2(0.0, -fb.y)).rgb;
        painted = mix(painted, bleed * 0.25, wetBleed * 0.6);
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

    // --- Temporal smoothing (neighbourhood-clamped accumulation, TAA-style) ---
    // A flat exponential blend toward the previous frame (the old path) trades smoothing against
    // ghosting: enough to settle the painterly "boil" (capture noise + cells flickering at their
    // boundaries) also smears anything that moves. Instead, RECTIFY the history against the local
    // colour range of the current frame, then accumulate hard where it is valid and snap to the
    // current frame where it is not — so static content stops boiling without trailing motion. No
    // motion vectors required; the clamp distance is the motion signal.
    if (temporal > 0.0) {
        float3 hist = spectra_tex(history, in.uv).rgb;
        // Colour AABB of the CURRENT painted frame from a 5-tap neighbourhood of the cells layer
        // (cells-space, so it excludes the canvas tooth; the slack below absorbs that). The
        // previous frame belongs here only if it sits inside this range.
        // `src` (the cells layer) is rendered at the Render Scale (slot 4), so step the
        // neighbourhood by one CELLS texel, not one full-res texel — otherwise at low Render Scale
        // every tap lands in the same texel, the colour box collapses to a sliver, and the history
        // is over-clamped (which would reintroduce the boil this is meant to remove). The scale is
        // resolved exactly as EffectChainRenderer does for this pass.
        float cellsScale = (u.params[4] > 0.01) ? clamp(u.params[4], 0.1, 1.0) : 0.6;
        float2 ts = u.texelSize / cellsScale;
        float3 nC = spectra_tex(src, in.uv).rgb;
        float3 nL = spectra_tex(src, in.uv + float2(-ts.x, 0.0)).rgb;
        float3 nR = spectra_tex(src, in.uv + float2( ts.x, 0.0)).rgb;
        float3 nU = spectra_tex(src, in.uv + float2(0.0, -ts.y)).rgb;
        float3 nD = spectra_tex(src, in.uv + float2(0.0,  ts.y)).rgb;
        float3 mn = min(nC, min(min(nL, nR), min(nU, nD)));
        float3 mx = max(nC, max(max(nL, nR), max(nU, nD)));
        // The box is in cells-space (pure painted colour), but the history lives in the final
        // mix(og, painted, amount) space, so map the box through the same blend before clamping. At
        // amount = 1 (every built-in oil world) this is a no-op; at lower amounts it stops the clamp
        // dragging the history toward the unblended cell colours.
        mn = mix(og, mn, amount);
        mx = mix(og, mx, amount);
        // Widen the box so genuine broken-colour variation is damped over time, not frozen solid,
        // and so the canvas tooth / full-res strokes baked into the history are not over-clipped.
        float3 slack = (mx - mn) * 0.25 + 0.02;
        float3 histClamped = clamp(hist, mn - slack, mx + slack);
        // How far the history had to be pulled back into range is the motion / disocclusion
        // signal: ~0 for in-range jitter (boil) -> accumulate; large where content moved -> snap.
        float motion = smoothstep(0.05, 0.22, length(hist - histClamped));
        // `temporal` sets the static-content smoothing target. The clamp makes a strong value
        // ghost-free, so drive it harder than the raw slider (still 0 at slider 0), then back it
        // off on motion so moving content stays crisp.
        float wStatic = min(0.9, temporal * 1.7);
        outc = mix(outc, histClamped, wStatic * (1.0 - motion));
    }

    return spectra_compositeRGBA(og, outc, u);
}

// MARK: - Line art (full-res relative XDoG, the shared ink/contour front-end)

// A CRISP, STABLE line extractor shared by the contour looks (Pencil, Ghibli). A FULL-RES isotropic
// Difference-of-Gaussians of luma, normalised by the local mean luma (Weber-relative contrast) and
// soft-thresholded, so dark low-contrast detail (a shadowed hillside) inks like lit detail instead
// of washing out, while smooth gradients stay clean. Temporal damping holds the lines still. Three
// passes: blur H, blur V + relative DoG, then composite + temporal.

// Horizontal half of the separable blur, carrying TWO scales of centre+surround Gaussian at once,
// packed (fineC, fineS, coarseC, coarseS), so the dog pass can union a fine and a coarse DoG. A
// single scale only "sees" edges at one size; two scales catch fine texture AND broad contours, so
// far more of a complex image draws. tex0 = the effect input.
fragment float4 fx_lineart_blurH(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float lineScale = clamp(u.params[0], 0.5, 4.0);
    float base = lineScale * max(1.0, u.resolution.y * 0.0006);
    float sC1 = base,       sS1 = sC1 * 1.6;         // fine scale (centre, surround)
    float sC2 = base * 2.0, sS2 = sC2 * 1.6;         // coarse scale (2x)
    float t1c = 2.0*sC1*sC1, t1s = 2.0*sS1*sS1, t2c = 2.0*sC2*sC2, t2s = 2.0*sS2*sS2;
    const int N = 8;
    float stride = (2.5 * sS2) / float(N);           // sized to the widest sigma, samples all four
    float2 step = u.direction * u.texelSize;
    float c1=0, s1=0, c2=0, s2=0, w1c=0, w1s=0, w2c=0, w2s=0;
    for (int i = -N; i <= N; i++) {
        float d = float(i) * stride;
        float lum = spectra_luma(src.sample(s, in.uv + step * d).rgb);
        float g1c=exp(-d*d/t1c), g1s=exp(-d*d/t1s), g2c=exp(-d*d/t2c), g2s=exp(-d*d/t2s);
        c1 += lum*g1c; w1c += g1c; s1 += lum*g1s; w1s += g1s;
        c2 += lum*g2c; w2c += g2c; s2 += lum*g2s; w2s += g2s;
    }
    return float4(c1/w1c, s1/w1s, c2/w2c, s2/w2s);
}

// Vertical half of the blur, completing both 2D Gaussians at both scales, then a relative DoG per
// scale, unioned. tex0 = the H-blurred (fineC, fineS, coarseC, coarseS) quad. Output = ink in .r.
fragment float4 fx_lineart_dog(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float lineScale = clamp(u.params[0], 0.5, 4.0);
    float base = lineScale * max(1.0, u.resolution.y * 0.0006);
    float sC1 = base,       sS1 = sC1 * 1.6;
    float sC2 = base * 2.0, sS2 = sC2 * 1.6;
    float t1c = 2.0*sC1*sC1, t1s = 2.0*sS1*sS1, t2c = 2.0*sC2*sC2, t2s = 2.0*sS2*sS2;
    const int N = 8;
    float stride = (2.5 * sS2) / float(N);
    float2 step = u.direction * u.texelSize;
    float a1=0, b1=0, a2=0, b2=0, w1c=0, w1s=0, w2c=0, w2s=0;
    for (int i = -N; i <= N; i++) {
        float d = float(i) * stride;
        float4 hb = src.sample(s, in.uv + step * d);   // (fineC, fineS, coarseC, coarseS), H-blurred
        float g1c=exp(-d*d/t1c), g1s=exp(-d*d/t1s), g2c=exp(-d*d/t2c), g2s=exp(-d*d/t2s);
        a1 += hb.r*g1c; w1c += g1c; b1 += hb.g*g1s; w1s += g1s;
        a2 += hb.b*g2c; w2c += g2c; b2 += hb.a*g2s; w2s += g2s;
    }
    a1/=w1c; b1/=w1s; a2/=w2c; b2/=w2s;
    float tau = 0.99;

    // Weber-relative contrast per scale: normalise each DoG by its local mean luma, so dark
    // low-contrast detail (a shadowed hillside) inks like lit detail while smooth gradients (sky)
    // stay clean. The floor stops near-black areas amplifying into noise.
    float rel1 = (a1 - tau*b1) / max(b1, 0.04);     // fine: foliage, small structure
    float rel2 = (a2 - tau*b2) / max(b2, 0.04);     // coarse: ridges, broad contours

    // eps is NEGATIVE (flats sit near 0, edges go negative); ink where rel < eps. Higher Threshold =
    // more-negative eps = only stronger contours; phi is the ink hardness.
    float threshold = clamp(u.params[2], 0.0, 1.0);
    float sharpness = clamp(u.params[3], 0.0, 1.0);
    float phi = mix(4.0, 40.0, sharpness);
    float eps = mix(-0.04, -0.30, threshold);
    float ink1 = clamp(1.0 - ((rel1 >= eps) ? 1.0 : 1.0 + tanh(phi * (rel1 - eps))), 0.0, 1.0);
    float ink2 = clamp(1.0 - ((rel2 >= eps) ? 1.0 : 1.0 + tanh(phi * (rel2 - eps))), 0.0, 1.0);
    float ink = max(ink1, ink2);                    // union of scales: a line wherever EITHER fires
    return float4(ink, 0.0, 0.0, 1.0);
}

// Composite + temporal. tex0 = ink mask, tex1 = the input, tex10 = the previous output.
fragment float4 fx_lineart_compose(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   texture2d<float> history [[texture(10)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float ink = src.sample(s, in.uv).r;

    float3 input = spectra_tex(orig, in.uv).rgb;
    float strength = clamp(u.params[1], 0.0, 1.0);
    float paper = clamp(u.params[5], 0.0, 1.0);
    float3 inkColor = float3(u.params[6], u.params[7], u.params[8]);
    float inkAlpha = clamp(u.params[9], 0.0, 1.0);   // honour the ink colour's alpha (was dropped)
    float3 paperTint = float3(u.params[10], u.params[11], u.params[12]);
    float3 bg = mix(input, paperTint, paper);
    float3 outc = mix(bg, inkColor, ink * strength * inkAlpha);

    // Temporal damping: on a live desktop, capture noise + sub-threshold flips make lines crawl.
    // Blend toward the previous frame where the result is unchanged, release on motion. The gate
    // threshold is set HIGH so small frame-to-frame flicker (the cel's band boundaries boiling on
    // capture noise) reads as static and is damped, while a genuine large change (real motion) still
    // releases the damp so moving content does not ghost. This is the main "stabilise" lever for the
    // cel-based looks, since the lineart is the last effect and its history is the chain's own output.
    float temporal = clamp(u.params[4], 0.0, 0.95);
    if (temporal > 0.0) {
        float3 hist = spectra_tex(history, in.uv).rgb;
        float motion = smoothstep(0.12, 0.38, distance(outc, hist));
        outc = mix(outc, hist, temporal * (1.0 - motion));
    }
    return spectra_compositeRGBA(input, outc, u);
}

// MARK: - Pencil sketch (paper + cross-hatch tone + contour ink)

// A real graphite drawing rather than a desaturated overlay: the base is paper white, TONE
// is built only from form-following cross-hatching (more/denser strokes where the image is
// darker), and CONTOUR lines come from a Sobel on luma. The source never shows through as
// grey. params[0]=hatch spacing, [1]=shading, [2]=contour, [3]=paper grain, [4..6]=paper RGB.
fragment float4 fx_style_pencil(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float spacingP = clamp(u.params[0], 2.0, 10.0);
    float tone = clamp(u.params[1], 0.0, 1.0);
    float contourAmt = clamp(u.params[2], 0.0, 1.0);
    float grainAmt = clamp(u.params[3], 0.0, 1.0);
    float3 paperTint = float3(u.params[4], u.params[5], u.params[6]);

    float2 px = in.uv * u.resolution;
    float L = spectra_luma(c);
    float dark = clamp(1.0 - L, 0.0, 1.0);

    // Resolution-relative hatch spacing.
    float sp = max(2.5, spacingP * u.resolution.y / 900.0);

    // Sobel on luma: drives both the contour lines and the hatch orientation.
    float2 gt = u.texelSize * max(1.0, u.resolution.y * 0.0014);
    float b00 = spectra_luma(spectra_tex(src, in.uv + float2(-gt.x, -gt.y)).rgb);
    float b10 = spectra_luma(spectra_tex(src, in.uv + float2( 0.0, -gt.y)).rgb);
    float b20 = spectra_luma(spectra_tex(src, in.uv + float2( gt.x, -gt.y)).rgb);
    float b01 = spectra_luma(spectra_tex(src, in.uv + float2(-gt.x,  0.0)).rgb);
    float b21 = spectra_luma(spectra_tex(src, in.uv + float2( gt.x,  0.0)).rgb);
    float b02 = spectra_luma(spectra_tex(src, in.uv + float2(-gt.x,  gt.y)).rgb);
    float b12 = spectra_luma(spectra_tex(src, in.uv + float2( 0.0,  gt.y)).rgb);
    float b22 = spectra_luma(spectra_tex(src, in.uv + float2( gt.x,  gt.y)).rgb);
    float gx = (b20 + 2.0 * b21 + b22) - (b00 + 2.0 * b01 + b02);
    float gy = (b02 + 2.0 * b12 + b22) - (b00 + 2.0 * b10 + b20);
    float gmag = sqrt(gx * gx + gy * gy);

    // Form-following hatch orientation: run strokes along the iso-contour, blended toward a
    // fixed diagonal in flat areas (vector blend so the pi-periodic lines never flip).
    float baseAng = 0.6108;   // ~35 degrees
    float follow = smoothstep(0.05, 0.25, gmag);
    float2 fd = float2(cos(baseAng), sin(baseAng));
    float2 cd = (gmag > 1e-5) ? normalize(float2(-gy, gx)) : fd;
    if (dot(cd, fd) < 0.0) cd = -cd;
    float2 hd = normalize(mix(fd, cd, follow));
    float ang = atan2(hd.y, hd.x);

    // Cross-hatch build-up: each layer engages as the area darkens, so light areas get a few
    // strokes and shadows get dense crossing strokes. Line width also grows with darkness.
    float h = 0.0;
    h = max(h, style_hatchLine(px, ang,          sp,        dark) * smoothstep(0.12, 0.30, dark));
    h = max(h, style_hatchLine(px, ang + 1.5708, sp,        dark) * smoothstep(0.34, 0.52, dark));
    h = max(h, style_hatchLine(px, ang + 0.7854, sp * 0.82, dark) * smoothstep(0.56, 0.72, dark));
    h = max(h, style_hatchLine(px, ang - 0.7854, sp * 0.70, dark) * smoothstep(0.74, 0.92, dark));
    h *= tone;

    // Contour graphite line where edges are.
    float contour = smoothstep(0.10, 0.34, gmag) * contourAmt;

    // Warm paper with a subtle tooth.
    float grain = spectra_valueNoise(px / max(2.0, 0.0026 * u.resolution.y)) - 0.5;
    float3 paper = paperTint * (1.0 + grain * 0.06 * (0.4 + grainAmt));

    // Compose: paper, darkened by hatch (mid-grey graphite) and contour (darker graphite).
    float graphiteAmt = clamp(max(h, contour), 0.0, 1.0);
    float3 graphite = mix(float3(0.32, 0.31, 0.33), float3(0.11, 0.11, 0.13), contour);
    float3 processed = clamp(mix(paper, graphite, graphiteAmt), 0.0, 1.0);

    return spectra_compositeRGBA(base, processed, u);
}

