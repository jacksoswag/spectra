#include "SpectraCommon.h"

// Procedural noise framework. Every effect samples the effect input on
// texture(0), the original (for compositing) on texture(1), reads parameters in
// declaration order from u.params[], and composites via spectra_compositeRGBA.
//
// Shared parameter layout for the family:
//   params[0] = intensity (0..1)
//   params[1] = scale     (0.1..64)
//   params[2] = speed     (0..5)
//   params[3] = colorize  (0..1) blend between monochrome and per-channel noise
//
// `colorize` mixes a single monochrome noise value applied to all channels with
// three independent per-channel noise values; u.seed gives per-instance variety.

// MARK: - Category helpers

// A scaled, time-advanced sampling coordinate in "noise space". UV is squared to
// device pixels via resolution so `scale` reads as cells-across-the-frame.
inline float2 fx_noise_coord(float2 uv, float scale, float seed) {
    return uv * scale * float2(1.0, 1.0) + float2(seed * 64.0, seed * 37.0);
}

// Per-channel offset so colorized noise decorrelates the three channels.
inline float3 fx_noise_channelOffset(float seed) {
    return float3(0.0, 19.19 + seed * 7.0, 47.83 + seed * 13.0);
}

// Blend a monochrome value with a colored triplet by `colorize`.
inline float3 fx_noise_colorBlend(float mono, float3 colored, float colorize) {
    return mix(float3(mono), colored, clamp(colorize, 0.0, 1.0));
}

// MARK: - White noise (uniform hash, additive)

fragment float4 fx_noise_white(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    float mono = spectra_hash21(p + t) - 0.5;
    float3 colored = float3(
        spectra_hash21(p + off.x + t) - 0.5,
        spectra_hash21(p + off.y + t) - 0.5,
        spectra_hash21(p + off.z + t) - 0.5);

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Gaussian noise (normal distribution, additive)

fragment float4 fx_noise_gaussian(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    // Gaussian noise has unbounded range; scale down so intensity stays tasteful.
    float mono = spectra_gaussianNoise(p + t) * 0.3;
    float3 colored = float3(
        spectra_gaussianNoise(p + off.x + t),
        spectra_gaussianNoise(p + off.y + t),
        spectra_gaussianNoise(p + off.z + t)) * 0.3;

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Blue noise (high-frequency hash minus a low-frequency component)

inline float fx_noise_blueSample(float2 p, float t) {
    float high = spectra_hash21(p + t);
    float low = spectra_valueNoise(p * 0.25 + t * 0.5);
    return (high - low);
}

fragment float4 fx_noise_blue(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    float mono = fx_noise_blueSample(p, t);
    float3 colored = float3(
        fx_noise_blueSample(p + off.x, t),
        fx_noise_blueSample(p + off.y, t),
        fx_noise_blueSample(p + off.z, t));

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Pink noise (1/f via summed octaves with decreasing amplitude)

inline float fx_noise_pinkSample(float2 p, float t) {
    float value = 0.0;
    float amplitude = 0.5;
    float norm = 0.0;
    for (int i = 0; i < 6; i++) {
        value += amplitude * (spectra_valueNoise(p + t) - 0.5);
        norm += amplitude;
        p *= 2.0;
        // 1/f: amplitude falls roughly as 1/octave step.
        amplitude *= 0.6;
    }
    return value / max(norm, 1.0e-4);
}

fragment float4 fx_noise_pink(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    float mono = fx_noise_pinkSample(p, t);
    float3 colored = float3(
        fx_noise_pinkSample(p + off.x, t),
        fx_noise_pinkSample(p + off.y, t),
        fx_noise_pinkSample(p + off.z, t));

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity * 1.6;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Brown noise (heavier low-frequency fbm)

inline float fx_noise_brownSample(float2 p, float t) {
    float value = 0.0;
    float amplitude = 0.5;
    float norm = 0.0;
    for (int i = 0; i < 5; i++) {
        value += amplitude * (spectra_valueNoise(p + t) - 0.5);
        norm += amplitude;
        p *= 2.0;
        // Strong amplitude decay emphasises low frequencies (1/f^2-ish).
        amplitude *= 0.35;
    }
    return value / max(norm, 1.0e-4);
}

fragment float4 fx_noise_brown(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    // Brown noise lives at low frequency, so sample at a coarser scale.
    float2 p = fx_noise_coord(in.uv, scale * 0.5, u.seed);
    float t = u.time * speed * 0.5;
    float3 off = fx_noise_channelOffset(u.seed);

    float mono = fx_noise_brownSample(p, t);
    float3 colored = float3(
        fx_noise_brownSample(p + off.x, t),
        fx_noise_brownSample(p + off.y, t),
        fx_noise_brownSample(p + off.z, t));

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity * 2.0;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Perlin noise (gradient noise, additive)

fragment float4 fx_noise_perlin(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    float mono = spectra_gradientNoise(p + t) - 0.5;
    float3 colored = float3(
        spectra_gradientNoise(p + off.x + t) - 0.5,
        spectra_gradientNoise(p + off.y + t) - 0.5,
        spectra_gradientNoise(p + off.z + t) - 0.5);

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity * 1.5;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Simplex noise (additive)

fragment float4 fx_noise_simplex(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    // spectra_simplex returns roughly [-1, 1].
    float mono = spectra_simplex(p + t) * 0.5;
    float3 colored = float3(
        spectra_simplex(p + off.x + t),
        spectra_simplex(p + off.y + t),
        spectra_simplex(p + off.z + t)) * 0.5;

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity * 1.5;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Cellular noise (Worley F1, additive)

fragment float4 fx_noise_cellular(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed * 0.3;
    float3 off = fx_noise_channelOffset(u.seed);

    // Animate cell centers by sliding the field; F1 distance centered to [-0.5, 0.5].
    float mono = spectra_cellular(p + t).x - 0.5;
    float3 colored = float3(
        spectra_cellular(p + off.x + t).x - 0.5,
        spectra_cellular(p + off.y + t).x - 0.5,
        spectra_cellular(p + off.z + t).x - 0.5);

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity * 1.5;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Film grain (luma-only, animated)

fragment float4 fx_noise_filmGrain(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = floor(u.time * speed * 24.0); // per-frame grain refresh
    float3 off = fx_noise_channelOffset(u.seed);

    // Grain is strongest in midtones, suppressed in deep shadows/highlights.
    float l = spectra_luma(c);
    float lumaResponse = 1.0 - abs(l - 0.5) * 1.2;
    lumaResponse = clamp(lumaResponse, 0.15, 1.0);

    float mono = spectra_gaussianNoise(p + t) * 0.3;
    float3 colored = float3(
        spectra_gaussianNoise(p + off.x + t),
        spectra_gaussianNoise(p + off.y + t),
        spectra_gaussianNoise(p + off.z + t)) * 0.3;

    float3 g = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + g * intensity * lumaResponse;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Sensor noise (per-channel read noise + sparse hot pixels)

fragment float4 fx_noise_sensor(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    // Read noise: independent gaussian per channel, stronger in shadows.
    float shadowGain = 1.0 - smoothstep(0.0, 0.5, spectra_luma(c));
    float read = 0.4 + 0.6 * shadowGain;

    float mono = spectra_gaussianNoise(p + t) * 0.25;
    float3 colored = float3(
        spectra_gaussianNoise(p + off.x + t),
        spectra_gaussianNoise(p + off.y + t),
        spectra_gaussianNoise(p + off.z + t)) * 0.25;
    float3 readNoise = fx_noise_colorBlend(mono, colored, colorize) * read;

    // Hot pixels: a sparse set of fixed bright specks fixed to the sensor grid.
    float2 cell = floor(in.uv / max(u.texelSize, float2(1.0e-5)) / 2.0);
    float hotKey = spectra_hash21(cell + u.seed * 91.7);
    float hot = step(0.9985, hotKey) * (0.6 + 0.4 * spectra_hash21(cell + 5.0));
    float3 hotColor = mix(float3(hot),
                          float3(spectra_hash21(cell + 1.0),
                                 spectra_hash21(cell + 2.0),
                                 spectra_hash21(cell + 3.0)) * hot,
                          clamp(colorize, 0.0, 1.0));

    float3 processed = c + readNoise * intensity + hotColor * intensity;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Compression noise (8x8 blocky noise, DCT-block flavored)

fragment float4 fx_noise_compression(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    // 8x8 macroblocks measured in device pixels, sized by scale.
    float blockPx = max(8.0 * (8.0 / max(scale, 0.1)), 2.0);
    float2 pixel = in.uv * u.resolution;
    float2 block = floor(pixel / blockPx);
    float t = floor(u.time * speed * 8.0);
    float3 off = fx_noise_channelOffset(u.seed);

    // One ringing value per block, plus a mild intra-block gradient.
    float2 inBlock = fract(pixel / blockPx) - 0.5;
    float ring = cos(inBlock.x * 6.2831853) * cos(inBlock.y * 6.2831853);

    float monoBase = spectra_hash21(block + u.seed * 53.0 + t) - 0.5;
    float mono = monoBase * (0.6 + 0.4 * ring);
    float3 colored = float3(
        (spectra_hash21(block + off.x + t) - 0.5),
        (spectra_hash21(block + off.y + t) - 0.5),
        (spectra_hash21(block + off.z + t) - 0.5)) * (0.6 + 0.4 * ring);

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Dust noise (sparse bright specks)

fragment float4 fx_noise_dust(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = floor(u.time * speed * 12.0); // dust flickers frame-to-frame
    float3 off = fx_noise_channelOffset(u.seed);

    // Threshold a hash hard so only a sparse fraction lights up.
    float key = spectra_hash21(floor(p) + t);
    float speck = smoothstep(0.985, 1.0, key);
    float bright = speck * (0.7 + 0.3 * spectra_hash21(floor(p) + 11.0));

    float3 coloredKey = float3(
        spectra_hash21(floor(p) + off.x + t),
        spectra_hash21(floor(p) + off.y + t),
        spectra_hash21(floor(p) + off.z + t));
    float3 coloredSpeck = smoothstep(0.985, 1.0, coloredKey) * bright;

    float3 d = fx_noise_colorBlend(bright, coloredSpeck, colorize);
    float3 processed = c + d * intensity * 2.0;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Speckle (multiplicative noise)

fragment float4 fx_noise_speckle(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = u.time * speed;
    float3 off = fx_noise_channelOffset(u.seed);

    // Multiplicative gain centered on 1.0; intensity controls deviation.
    float mono = spectra_hash21(p + t) - 0.5;
    float3 colored = float3(
        spectra_hash21(p + off.x + t) - 0.5,
        spectra_hash21(p + off.y + t) - 0.5,
        spectra_hash21(p + off.z + t) - 0.5);

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 gain = 1.0 + n * intensity * 2.0;
    float3 processed = c * gain;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Digital noise (quantized bit-ish noise)

fragment float4 fx_noise_digital(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];
    float scale = max(u.params[1], 0.1);
    float speed = u.params[2];
    float colorize = u.params[3];

    float2 p = fx_noise_coord(in.uv, scale, u.seed);
    float t = floor(u.time * speed * 16.0); // discrete temporal steps
    float3 off = fx_noise_channelOffset(u.seed);

    // Quantize the hash into a few discrete levels for a bit-crushed look.
    float levels = 4.0;
    float monoRaw = spectra_hash21(floor(p) + t);
    float mono = (floor(monoRaw * levels) / (levels - 1.0)) - 0.5;
    float3 coloredRaw = float3(
        spectra_hash21(floor(p) + off.x + t),
        spectra_hash21(floor(p) + off.y + t),
        spectra_hash21(floor(p) + off.z + t));
    float3 colored = (floor(coloredRaw * levels) / (levels - 1.0)) - 0.5;

    float3 n = fx_noise_colorBlend(mono, colored, colorize);
    float3 processed = c + n * intensity;
    return spectra_compositeRGBA(base, processed, u);
}
