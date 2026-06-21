#include "SpectraCommon.h"

// Sharpen / detail effects. Each fragment function samples the effect input on
// texture(0), the original (for compositing) on texture(1), reads parameters in
// declaration order from u.params[], gathers neighbours via u.texelSize, and
// composites via spectra_compositeRGBA. All neighbour offsets are scaled by
// u.texelSize so the response is resolution-independent.

// Gather a box-blurred colour over a square kernel of the given pixel radius.
// Tap count is bounded by the caller; the radius spaces the taps so larger
// radii cover more of the frame without increasing the loop bound.
inline float3 spectra_sharpen_boxBlur(texture2d<float> t, float2 uv,
                                      float2 texel, float radius, int taps) {
    float3 sum = float3(0.0);
    float weight = 0.0;
    float step = max(radius, 1.0) / float(taps);
    for (int y = -taps; y <= taps; y++) {
        for (int x = -taps; x <= taps; x++) {
            float2 o = float2(float(x), float(y)) * step * texel;
            sum += spectra_tex(t, uv + o).rgb;
            weight += 1.0;
        }
    }
    return sum / max(weight, 1.0);
}

// Gaussian-weighted gather over a square kernel of the given pixel radius. Taps
// are weighted by exp(-d²/2σ²) with σ set to a third of the radius, giving the
// smooth falloff an unsharp mask needs (a flat box blur leaves haloing).
inline float3 spectra_sharpen_gaussianBlur(texture2d<float> t, float2 uv,
                                           float2 texel, float radius, int taps) {
    float3 sum = float3(0.0);
    float weight = 0.0;
    float step = max(radius, 1.0) / float(taps);
    float sigma = max(radius, 1.0) / 3.0;
    float twoSigma2 = 2.0 * sigma * sigma;
    for (int y = -taps; y <= taps; y++) {
        for (int x = -taps; x <= taps; x++) {
            float2 d = float2(float(x), float(y)) * step;
            float w = exp(-dot(d, d) / twoSigma2);
            sum += spectra_tex(t, uv + d * texel).rgb * w;
            weight += w;
        }
    }
    return sum / max(weight, 1.0e-4);
}

// Separable-feel blur of the luma channel only, over a pixel radius.
inline float spectra_sharpen_lumaBlur(texture2d<float> t, float2 uv,
                                      float2 texel, float radius, int taps) {
    float sum = 0.0;
    float weight = 0.0;
    float step = max(radius, 1.0) / float(taps);
    // A fixed grid of widely-spaced taps (~radius/taps texels apart) aliases into a
    // quilted/grid pattern at large radius. Rotate the lattice by a per-pixel angle so
    // that structure becomes fine sub-visible noise instead, and weight the taps with a
    // Gaussian for a smooth, circular footprint rather than a hard box.
    float ang = spectra_hash21(floor(uv / max(texel, float2(1.0e-6)))) * 6.2831853;
    float ca = cos(ang);
    float sa = sin(ang);
    float sigma = max(float(taps) * 0.6, 1.0);
    float inv2s2 = 1.0 / (2.0 * sigma * sigma);
    for (int y = -taps; y <= taps; y++) {
        for (int x = -taps; x <= taps; x++) {
            float2 g = float2(float(x), float(y));
            float w = exp(-dot(g, g) * inv2s2);
            float2 r = float2(g.x * ca - g.y * sa, g.x * sa + g.y * ca);
            sum += spectra_luma(spectra_tex(t, uv + r * step * texel).rgb) * w;
            weight += w;
        }
    }
    return sum / max(weight, 1.0e-4);
}

// MARK: - Sharpen

// Classic unsharp using a fixed 3x3 high-pass kernel (centre 5, edges -1).
fragment float4 fx_sharpen_sharpen(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = u.params[0];
    float2 t = u.texelSize;

    float3 n = spectra_tex(src, in.uv + float2(0.0, -t.y)).rgb;
    float3 s = spectra_tex(src, in.uv + float2(0.0,  t.y)).rgb;
    float3 e = spectra_tex(src, in.uv + float2( t.x, 0.0)).rgb;
    float3 w = spectra_tex(src, in.uv + float2(-t.x, 0.0)).rgb;

    // Laplacian high-pass: 5*centre - 4 neighbours.
    float3 highPass = c * 5.0 - (n + s + e + w);
    float3 processed = c + (highPass - c) * amount;
    return spectra_compositeRGBA(base, max(processed, 0.0), u);
}

// MARK: - Unsharp Mask

// Subtract a blurred sample set, add the difference back scaled by amount. The
// radius controls how broad the blurred reference is.
fragment float4 fx_sharpen_unsharpMask(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = u.params[0];
    float radius = u.params[1];

    // Derive the tap count from the radius so the tap spacing (radius/taps) never drops below
    // ~1 texel — at the old fixed taps=3 a radius-2 mask spaced taps 0.67px apart, aliasing
    // adjacent samples onto the same texel. Also trims 49→25 taps at the common radius 2.
    int taps = clamp(int(round(radius)), 2, 4);
    float3 blurred = spectra_sharpen_gaussianBlur(src, in.uv, u.texelSize, radius, taps);
    float3 highFreq = c - blurred;
    float3 processed = c + highFreq * amount;
    return spectra_compositeRGBA(base, max(processed, 0.0), u);
}

// MARK: - Clarity

// Midtone local-contrast boost. The high-frequency component is added back but
// gated by a midtone luma mask so shadows and highlights stay clean.
fragment float4 fx_sharpen_clarity(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = u.params[0];

    // taps 2 (5x5=25 samples) instead of 3 (7x7=49): at radius 6 the tap spacing is 3px, and the
    // midtone-gated detail signal holds up at this density. Halves the clarity gather cost.
    float3 blurred = spectra_sharpen_boxBlur(src, in.uv, u.texelSize, 6.0, 2);
    float3 detail = c - blurred;

    // Triangular midtone mask: peaks at 0.5 luma, falls to 0 at black/white.
    float l = spectra_luma(c);
    float midMask = 1.0 - abs(l - 0.5) * 2.0;
    midMask = smoothstep(0.0, 1.0, max(midMask, 0.0));

    float3 processed = c + detail * amount * 1.5 * midMask;
    return spectra_compositeRGBA(base, max(processed, 0.0), u);
}

// MARK: - Local Contrast

// Large-radius unsharp applied to luma only, preserving chroma. Gives an HDR
// "pop" without colour fringing.
fragment float4 fx_sharpen_localContrast(RasterizerData in [[stage_in]],
                                         texture2d<float> src [[texture(0)]],
                                         texture2d<float> orig [[texture(1)]],
                                         constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = u.params[0];
    float radius = u.params[1];

    float l = spectra_luma(c);
    float blurredL = spectra_sharpen_lumaBlur(src, in.uv, u.texelSize, radius, 5);
    float boostedL = l + (l - blurredL) * amount;

    // Scale chroma around the new luma so colours track the contrast change.
    float ratio = boostedL / max(l, 1.0e-4);
    float3 processed = c * ratio;
    return spectra_compositeRGBA(base, max(processed, 0.0), u);
}

// MARK: - Detail Enhancement

// Multi-radius high-frequency boost. Three concentric difference-of-box bands
// recover fine, medium, and coarse detail, weighted toward the finest.
fragment float4 fx_sharpen_detail(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = u.params[0];

    float3 b1 = spectra_sharpen_boxBlur(src, in.uv, u.texelSize, 2.0, 1);
    float3 b2 = spectra_sharpen_boxBlur(src, in.uv, u.texelSize, 5.0, 2);
    float3 b3 = spectra_sharpen_boxBlur(src, in.uv, u.texelSize, 11.0, 2);

    float3 fine = c - b1;
    float3 medium = b1 - b2;
    float3 coarse = b2 - b3;

    float3 detail = fine * 1.0 + medium * 0.6 + coarse * 0.35;
    float3 processed = c + detail * amount;
    return spectra_compositeRGBA(base, max(processed, 0.0), u);
}

// MARK: - Edge Enhancement

// Sobel edge detection on luma, added back to the image to crisp up contours.
fragment float4 fx_sharpen_edge(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    float amount = u.params[0];
    float2 t = u.texelSize;

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
    float edge = sqrt(gx * gx + gy * gy);

    float3 processed = c + edge * amount;
    return spectra_compositeRGBA(base, max(processed, 0.0), u);
}
