#include "SpectraCommon.h"

// Retro / CRT and analog-television effects. Each fragment function samples the
// effect input on texture(0), the original (for compositing) on texture(1),
// reads parameters in declaration order from u.params[], and composites via
// spectra_compositeRGBA. Pixel-locked patterns derive their cell size from
// u.resolution so masks and scanlines stay crisp regardless of render scale.

// MARK: - Category helpers

// Barrel distortion of a centered [-1,1] coordinate. `amount` controls how much
// the edges bow; 0 is flat. Returns the warped centered coordinate.
//
// The raw `cc * (1 + amount*r2)` magnifies with radius, so points map past [-1,1]
// and sample beyond the source. We renormalize so the picture fits the screen at
// the EDGE MIDPOINTS rather than the corners. The edge midpoints sit at r2 = 1
// (e.g. (1,0),(0,1)); dividing by their expansion `1 + amount*1` pins them exactly
// to the source edge (factor = 1 there), so the bowed top/bottom/left/right edges
// touch the physical screen border with no black gap. The corners (r2 = 2) then
// overscan past [-1,1] — they sample beyond the source and are cropped by the
// rounded tube mask, which is the correct CRT look (curved tube with rounded
// corners) rather than black notches pulled in from the edges.
//
// Why edge-fit, not corner-fit: a barrel-bowed rectangle's edges are curves, so
// they cannot meet the border at both the midpoints AND the corners at once.
// Corner-fit (norm = 1 + amount*2) leaves the bowed edge midpoints pulled inward
// (black gaps along edge centers); edge-fit pushes the corners out instead.
//
// At amount = 0 this is the identity (norm = 1), so a flat screen is unchanged.
inline float2 fx_crt_barrel(float2 cc, float amount) {
    float r2 = dot(cc, cc);
    float norm = 1.0 + amount;          // edge-midpoint expansion (r2 = 1)
    return cc * (1.0 + amount * r2) / norm;
}

// Soft rounded-rectangle tube vignette/mask from centered coords in [-1,1].
// Returns 1 inside the tube, falling to 0 just past the edge.
inline float fx_crt_tubeMask(float2 cc, float softness) {
    float2 d = abs(cc) - float2(1.0);
    float outside = length(max(d, 0.0));
    return 1.0 - smoothstep(0.0, max(softness, 1.0e-3), outside);
}

// Sample the warped screen, returning black outside the [0,1] rect. Without this
// the clamp-to-edge sampler repeats the desktop's edge pixels into the curved
// border, making the un-warped screen appear to "bleed" around the tube. A
// half-texel feather keeps the screen edge from aliasing.
inline float3 fx_crt_sampleTube(texture2d<float> src, float2 wuv, float2 texel) {
    float2 fade = max(texel, 1.0e-4);
    // Bias by half a texel so the feather is centered on the screen edge: an
    // un-warped outermost pixel (center 0.5 texel inside the boundary) reads as
    // fully inside, and only genuinely out-of-range samples fade to black. Without
    // this, curvature = 0 would leave a dark 1px seam around the frame.
    float2 lo = smoothstep(float2(0.0), fade, wuv + 0.5 * fade);
    float2 hi = smoothstep(float2(0.0), fade, (1.0 - wuv) + 0.5 * fade);
    float inside = lo.x * lo.y * hi.x * hi.y;
    return spectra_tex(src, wuv).rgb * inside;
}

// RGB shadow-mask triad weight for a pixel. `scale` is the triad size in pixels.
inline float3 fx_crt_shadowMask(float2 pixel, float scale) {
    float2 cell = pixel / max(scale, 1.0);
    int col = int(floor(fract(cell.x) * 3.0));
    // Stagger rows for the classic dot-triad brick pattern.
    float rowPhase = floor(cell.y) * 0.5;
    float roff = fract(cell.x + rowPhase);
    int scol = int(floor(roff * 3.0));
    int idx = (int(floor(cell.y)) & 1) ? scol : col;
    float3 m = float3(0.6);
    if (idx == 0) m.r = 1.0;
    else if (idx == 1) m.g = 1.0;
    else m.b = 1.0;
    return m;
}

// Vertical aperture-grille stripe weight. `scale` is the stripe period in pixels.
inline float3 fx_crt_apertureGrille(float x, float scale) {
    float phase = fract(x / max(scale, 1.0));
    int idx = int(floor(phase * 3.0));
    float3 m = float3(0.55);
    if (idx == 0) m.r = 1.0;
    else if (idx == 1) m.g = 1.0;
    else m.b = 1.0;
    return m;
}

// Scanline darkening for a given vertical pixel position and line count.
inline float fx_crt_scanline(float uvY, float lineCount, float strength) {
    float s = sin(uvY * lineCount * 3.14159265);
    float line = 0.5 + 0.5 * s;
    return 1.0 - strength * (1.0 - line);
}

// MARK: - CRT (combined tube)

fragment float4 fx_crt_crt(RasterizerData in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           texture2d<float> orig [[texture(1)]],
                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    // Strength dials the whole tube down to nothing (identity at 0), rather than
    // cross-fading the curved image over the flat one (which shows the original).
    float st = clamp(u.strength, 0.0, 1.0);
    float scanStrength = u.params[0] * st;
    float maskStrength = u.params[1] * st;
    float curvature = u.params[2] * st;
    float brightness = mix(1.0, u.params[3], st);

    // Barrel-warp the screen. `fx_crt_barrel` renormalizes so the bowed edge
    // midpoints land exactly on the display border (no black gap along the top/
    // bottom/left/right edge centers); the corners overscan and are cropped by the
    // rounded tube mask. Keep `curvature` low for a gentle tube.
    float2 cc = in.uv * 2.0 - 1.0;
    float2 warped = fx_crt_barrel(cc, curvature);
    float2 wuv = warped * 0.5 + 0.5;
    float tube = fx_crt_tubeMask(warped, 0.04);

    float3 c = fx_crt_sampleTube(src, wuv, u.texelSize);
    c *= fx_crt_scanline(in.uv.y, u.resolution.y * 0.5, scanStrength);
    float3 mask = fx_crt_shadowMask(in.uv * u.resolution, 3.0);
    c *= mix(float3(1.0), mask, maskStrength);
    c *= brightness * tube;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - CRT Advanced (richer combined)

fragment float4 fx_crt_crtAdvanced(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float st = clamp(u.strength, 0.0, 1.0);
    float scanStrength = u.params[0] * st;
    float maskStrength = u.params[1] * st;
    float curvature = u.params[2] * st;
    float bloom = u.params[3] * st;
    float vignette = u.params[4] * st;

    // Barrel-warp, renormalized so the bowed edge midpoints meet the display
    // border (no black gap along the edge centers); corners overscan and crop.
    float2 cc = in.uv * 2.0 - 1.0;
    float2 warped = fx_crt_barrel(cc, curvature);
    float2 wuv = warped * 0.5 + 0.5;
    float tube = fx_crt_tubeMask(warped, 0.04);

    float3 c = fx_crt_sampleTube(src, wuv, u.texelSize);

    // Bloom: sample a small neighborhood, keep bright energy.
    float3 glow = float3(0.0);
    float2 px = u.texelSize * 2.0;
    glow += fx_crt_sampleTube(src, wuv + float2(px.x, 0.0), u.texelSize);
    glow += fx_crt_sampleTube(src, wuv - float2(px.x, 0.0), u.texelSize);
    glow += fx_crt_sampleTube(src, wuv + float2(0.0, px.y), u.texelSize);
    glow += fx_crt_sampleTube(src, wuv - float2(0.0, px.y), u.texelSize);
    glow *= 0.25;
    float3 bright = max(glow - 0.5, 0.0) * 2.0;
    c += bright * bloom;

    c *= fx_crt_scanline(wuv.y, u.resolution.y * 0.5, scanStrength);

    float3 mask = fx_crt_shadowMask(in.uv * u.resolution, 3.0);
    c *= mix(float3(1.0), mask, maskStrength);

    float r2 = dot(cc, cc);
    float vig = 1.0 - vignette * smoothstep(0.4, 1.6, r2);
    c *= vig * tube;
    return spectra_compositeFullRGBA(base, c, u);
}

// MARK: - Scanlines

fragment float4 fx_crt_scanlines(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float count = max(u.params[0], 1.0);
    float strength = u.params[1];
    float3 processed = c * fx_crt_scanline(in.uv.y, count, strength);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Shadow Mask

fragment float4 fx_crt_shadowMaskFx(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float strength = u.params[0];
    float scale = max(u.params[1], 1.0);
    float3 mask = fx_crt_shadowMask(in.uv * u.resolution, scale);
    float3 processed = c * mix(float3(1.0), mask, strength);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Aperture Grille

fragment float4 fx_crt_apertureGrilleFx(RasterizerData in [[stage_in]],
                                        texture2d<float> src [[texture(0)]],
                                        texture2d<float> orig [[texture(1)]],
                                        constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float strength = u.params[0];
    float scale = max(u.params[1], 1.0);
    float3 mask = fx_crt_apertureGrille(in.uv.x * u.resolution.x, scale);
    float3 processed = c * mix(float3(1.0), mask, strength);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Curvature

fragment float4 fx_crt_curvature(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float st = clamp(u.strength, 0.0, 1.0);
    float amount = u.params[0] * st;

    float2 cc = in.uv * 2.0 - 1.0;
    float2 warped = fx_crt_barrel(cc, amount);
    float2 wuv = warped * 0.5 + 0.5;

    float3 c = fx_crt_sampleTube(src, wuv, u.texelSize);
    float tube = fx_crt_tubeMask(warped, 0.04);
    float r2 = dot(cc, cc);
    float vig = 1.0 - 0.35 * st * smoothstep(0.3, 1.7, r2);
    float3 processed = c * tube * vig;
    return spectra_compositeFullRGBA(base, processed, u);
}

// MARK: - CRT Bloom

fragment float4 fx_crt_bloom(RasterizerData in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             texture2d<float> orig [[texture(1)]],
                             constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float threshold = u.params[0];
    float intensity = u.params[1];

    float3 glow = float3(0.0);
    float total = 0.0;
    for (int i = -3; i <= 3; i++) {
        for (int j = -3; j <= 3; j++) {
            float2 off = float2(float(i), float(j)) * u.texelSize * 1.5;
            float w = exp(-float(i * i + j * j) * 0.18);
            float3 s = spectra_tex(src, in.uv + off).rgb;
            glow += max(s - threshold, 0.0) * w;
            total += w;
        }
    }
    glow /= max(total, 1.0e-4);
    float3 processed = c + glow * intensity;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Phosphor Glow (separable two-pass smear)

fragment float4 fx_crt_phosphor_h(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float intensity = u.params[0];
    float persistence = u.params[1];
    float radius = mix(1.0, 5.0, persistence);

    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = -5; i <= 5; i++) {
        float fi = float(i);
        float w = exp(-fi * fi / 8.0);
        float2 off = u.direction * u.texelSize * fi * radius;
        sum += spectra_tex(src, in.uv + off).rgb * w;
        total += w;
    }
    float3 blurred = sum / max(total, 1.0e-4);
    float3 c = spectra_tex(src, in.uv).rgb;
    // Carry intensity through to the vertical pass via additive smear seed.
    float3 out = mix(c, max(c, blurred), 0.5 + 0.5 * intensity);
    return float4(out, 1.0);
}

fragment float4 fx_crt_phosphor_v(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  texture2d<float> history [[texture(10)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float persistence = u.params[1];
    float radius = mix(1.0, 5.0, persistence);

    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = -5; i <= 5; i++) {
        float fi = float(i);
        float w = exp(-fi * fi / 8.0);
        float2 off = u.direction * u.texelSize * fi * radius;
        sum += spectra_tex(src, in.uv + off).rgb * w;
        total += w;
    }
    float3 blurred = sum / max(total, 1.0e-4);
    float3 glow = max(blurred - 0.25, 0.0);
    float3 processed = base + glow * intensity;

    // Temporal persistence: phosphor decays over frames, so the previous frame's
    // output bleeds forward and fades. Bright areas leave true trails.
    float decay = mix(0.0, 0.82, persistence);
    float3 prev = spectra_tex(history, in.uv).rgb;
    processed = max(processed, prev * decay);

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Composite Video (luma/chroma crosstalk via YIQ)

fragment float4 fx_crt_composite(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float artifacts = u.params[0];
    float bleed = u.params[1];

    float3 yiq = spectra_rgb2yiq(spectra_tex(src, in.uv).rgb);

    // Chroma bleeds horizontally; luma stays sharp.
    float2 step1 = float2(u.texelSize.x * (1.0 + bleed * 6.0), 0.0);
    float3 l = spectra_rgb2yiq(spectra_tex(src, in.uv - step1).rgb);
    float3 r = spectra_rgb2yiq(spectra_tex(src, in.uv + step1).rgb);
    float2 chroma = (yiq.yz + l.yz + r.yz) / 3.0;
    chroma = mix(yiq.yz, chroma, bleed);

    // Artifacting: high-frequency luma leaks into chroma (dot-crawl flavor).
    float hf = spectra_luma(spectra_tex(src, in.uv + step1).rgb)
             - spectra_luma(spectra_tex(src, in.uv - step1).rgb);
    chroma += hf * artifacts * float2(0.4, -0.3);

    float3 processed = spectra_yiq2rgb(float3(yiq.x, chroma));
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - RF Signal Loss (animated static + sync loss)

fragment float4 fx_crt_rfLoss(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float noiseAmt = u.params[0];
    float dropout = u.params[1];
    float speed = u.params[2];

    float t = u.time * speed;

    // Horizontal sync tearing: rows shift by a time-varying amount.
    float lineSeed = floor(in.uv.y * u.resolution.y * 0.5);
    float jitter = (spectra_hash21(float2(lineSeed, floor(t * 8.0))) - 0.5);
    float tear = jitter * dropout * 0.15;
    float2 uv = float2(fract(in.uv.x + tear), in.uv.y);

    float3 c = spectra_tex(src, uv).rgb;

    // Animated static.
    float st = spectra_hash21(in.uv * u.resolution + float2(t * 53.0, t * 97.0) + u.seed * 100.0);
    float3 stat = float3(st);

    // Dropout bands: occasional rows wash to static.
    float band = spectra_hash21(float2(lineSeed, floor(t * 5.0) + u.seed * 31.0));
    float washed = step(1.0 - dropout * 0.5, band);

    float3 processed = mix(c, stat, noiseAmt * 0.6);
    processed = mix(processed, stat, washed * dropout);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Color Bleed (horizontal chroma smear)

fragment float4 fx_crt_colorBleed(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float amount = u.params[0];

    float2 off = float2(u.texelSize.x * amount * 8.0, 0.0);
    float3 yiq = spectra_rgb2yiq(spectra_tex(src, in.uv).rgb);
    float2 c1 = spectra_rgb2yiq(spectra_tex(src, in.uv - off).rgb).yz;
    float2 c2 = spectra_rgb2yiq(spectra_tex(src, in.uv - off * 2.0).rgb).yz;
    float2 chroma = mix(yiq.yz, yiq.yz * 0.5 + c1 * 0.35 + c2 * 0.15, amount);
    float3 processed = spectra_yiq2rgb(float3(yiq.x, chroma));
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - NTSC (YIQ bandlimited)

fragment float4 fx_crt_ntsc(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float artifacts = u.params[0];
    float fringing = u.params[1];

    // Bandlimit chroma with a horizontal low-pass; keep luma sharp.
    float y = spectra_rgb2yiq(spectra_tex(src, in.uv).rgb).x;
    float2 chroma = float2(0.0);
    float total = 0.0;
    for (int i = -4; i <= 4; i++) {
        float fi = float(i);
        float w = exp(-fi * fi / 6.0);
        float2 off = float2(u.texelSize.x * fi * (1.0 + fringing * 4.0), 0.0);
        chroma += spectra_rgb2yiq(spectra_tex(src, in.uv + off).rgb).yz * w;
        total += w;
    }
    chroma /= max(total, 1.0e-4);

    // Color-subcarrier artifacting from luma high frequencies.
    float hf = y - spectra_rgb2yiq(spectra_tex(src, in.uv + float2(u.texelSize.x * 2.0, 0.0)).rgb).x;
    chroma += hf * artifacts * float2(0.5, -0.5);

    float3 processed = spectra_yiq2rgb(float3(y, chroma));
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - PAL (softer variant)

fragment float4 fx_crt_pal(RasterizerData in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           texture2d<float> orig [[texture(1)]],
                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float artifacts = u.params[0];
    float softness = u.params[1];

    // PAL averages phase between adjacent lines, suppressing hue errors and
    // softening vertical detail.
    float3 yiq = spectra_rgb2yiq(spectra_tex(src, in.uv).rgb);
    float2 up = spectra_rgb2yiq(spectra_tex(src, in.uv + float2(0.0, u.texelSize.y)).rgb).yz;
    float2 dn = spectra_rgb2yiq(spectra_tex(src, in.uv - float2(0.0, u.texelSize.y)).rgb).yz;
    float2 lineAvg = (yiq.yz + up + dn) / 3.0;

    // Horizontal chroma bandlimit.
    float2 chroma = float2(0.0);
    float total = 0.0;
    for (int i = -3; i <= 3; i++) {
        float fi = float(i);
        float w = exp(-fi * fi / 5.0);
        float2 off = float2(u.texelSize.x * fi * (1.0 + softness * 5.0), 0.0);
        chroma += spectra_rgb2yiq(spectra_tex(src, in.uv + off).rgb).yz * w;
        total += w;
    }
    chroma /= max(total, 1.0e-4);
    chroma = mix(chroma, lineAvg, softness);

    float hf = yiq.x - spectra_rgb2yiq(spectra_tex(src, in.uv + float2(u.texelSize.x * 2.0, 0.0)).rgb).x;
    chroma += hf * artifacts * float2(0.3, -0.3);

    float ly = mix(yiq.x, (yiq.x + spectra_rgb2yiq(spectra_tex(src, in.uv + float2(0.0, u.texelSize.y)).rgb).x) * 0.5, softness * 0.5);
    float3 processed = spectra_yiq2rgb(float3(ly, chroma));
    return spectra_compositeRGBA(base, clamp(processed, 0.0, 1.0), u);
}

// MARK: - Analog Television (combined, animated)

fragment float4 fx_crt_analogTV(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float scanStrength = u.params[0];
    float maskStrength = u.params[1];
    float bleed = u.params[2];
    float vignette = u.params[3];
    float noiseAmt = u.params[4];

    // Subtle vertical roll/jitter for the "almost-tuned" feel.
    float roll = (spectra_hash11(floor(u.time * 3.0) + u.seed) - 0.5) * 0.002;
    float2 uv = float2(in.uv.x, fract(in.uv.y + roll));

    // Chroma bleed via YIQ.
    float3 yiq = spectra_rgb2yiq(spectra_tex(src, uv).rgb);
    float2 off = float2(u.texelSize.x * bleed * 8.0, 0.0);
    float2 c1 = spectra_rgb2yiq(spectra_tex(src, uv - off).rgb).yz;
    float2 chroma = mix(yiq.yz, yiq.yz * 0.6 + c1 * 0.4, bleed);
    float3 c = spectra_yiq2rgb(float3(yiq.x, chroma));

    // Scanlines + shadow mask.
    c *= fx_crt_scanline(uv.y, u.resolution.y * 0.5, scanStrength);
    float3 mask = fx_crt_shadowMask(in.uv * u.resolution, 3.0);
    c *= mix(float3(1.0), mask, maskStrength);

    // Animated film-grain static.
    float st = spectra_hash21(in.uv * u.resolution + float2(u.time * 60.0, u.time * 90.0) + u.seed * 50.0) - 0.5;
    c += st * noiseAmt * 0.3;

    // Edge vignette.
    float2 cc = in.uv * 2.0 - 1.0;
    float vig = 1.0 - vignette * smoothstep(0.4, 1.7, dot(cc, cc));
    c *= vig;

    return spectra_compositeRGBA(base, clamp(c, 0.0, 1.0), u);
}
