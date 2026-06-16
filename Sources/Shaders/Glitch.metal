#include "SpectraCommon.h"

// Glitch effects: digital corruption and signal failure. Each fragment function
// samples the effect input on texture(0), the original (for compositing) on
// texture(1), reads parameters in declaration order from u.params[], and
// composites via spectra_compositeRGBA.
//
// Category-private helpers are marked `inline` and prefixed `glitch_` to avoid
// link collisions in the shared metallib.

// Quantize a continuous time value into discrete steps so animation advances in
// stuttery jumps rather than smoothly.
inline float glitch_stepTime(float t, float rate) {
    float r = max(rate, 0.0001);
    return floor(t * r) / r;
}

// A per-time-step random seed, stable within a step and changing between steps.
inline float glitch_blockSeed(float t, float rate, float seed) {
    return spectra_hash11(glitch_stepTime(t, rate) * 13.71 + seed * 71.3);
}

// MARK: - Datamosh

// True P-frame datamosh: macroblocks carry forward the PREVIOUS frame's pixels
// (history, texture 10) along a per-block motion vector, so motion smears and
// "freezes" exactly like a corrupted inter-frame stream. The block keeps
// referencing last frame's output, accumulating the characteristic bleed.
fragment float4 fx_glitch_datamosh(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   texture2d<float> history [[texture(10)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float t = u.time * speed;
    float2 blockCount = float2(24.0, 14.0);
    float2 block = floor(in.uv * blockCount);

    // Per-block motion vector and a gate that decides which blocks "mosh".
    float2 mv = spectra_hash22(block + floor(t)) * 2.0 - 1.0;
    float gate = step(0.45, spectra_hash21(block * 1.37 + floor(t * 0.5)));
    float2 offset = mv * intensity * 0.06 * gate;

    // Moshed blocks pull last frame's pixels along the motion vector; the rest
    // pass the current frame through. The feedback loop builds the smear.
    float3 current = spectra_tex(src, in.uv).rgb;
    float3 moved = spectra_tex(history, in.uv + offset).rgb;
    float persist = intensity * gate;
    float3 processed = mix(current, moved, clamp(persist, 0.0, 0.92));

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - RGB Split

// Offset the red and blue channels in opposite directions along an angle. Not
// inherently animated.
fragment float4 fx_glitch_rgbSplit(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float amount = u.params[0];
    float angle = u.params[1] * 3.14159265 / 180.0;

    float2 dir = float2(cos(angle), sin(angle)) * amount * 0.03;
    float r = spectra_tex(src, in.uv + dir).r;
    float g = spectra_tex(src, in.uv).g;
    float b = spectra_tex(src, in.uv - dir).b;
    float3 processed = float3(r, g, b);

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Scan Corruption

// Random horizontal scanlines jump left or right, like a damaged tape head.
fragment float4 fx_glitch_scanCorruption(RasterizerData in [[stage_in]],
                                         texture2d<float> src [[texture(0)]],
                                         texture2d<float> orig [[texture(1)]],
                                         constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float t = u.time * speed;
    float line = floor(in.uv.y * u.resolution.y / 3.0);
    float n = spectra_hash21(float2(line, floor(t * 8.0)));
    // Only a fraction of lines glitch at any moment.
    float active = step(1.0 - intensity * 0.6, n);
    float shift = (spectra_hash11(line * 1.7 + floor(t * 8.0)) * 2.0 - 1.0);

    float2 uv = in.uv;
    uv.x += shift * intensity * 0.15 * active;
    float3 processed = spectra_tex(src, uv).rgb;

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Frame Tearing

// A single horizontal tear seam sweeps down the frame; everything below the seam
// is shifted, mimicking a torn / desynced frame buffer.
fragment float4 fx_glitch_frameTearing(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float t = u.time * speed;
    float seam = fract(t * 0.5);                 // moving tear position (0..1, bottom..top)
    float below = step(in.uv.y, seam);           // region beneath the seam
    float jump = (spectra_hash11(floor(t * 0.5)) * 2.0 - 1.0) * intensity * 0.2;

    float2 uv = in.uv;
    uv.x += jump * below;
    float3 processed = spectra_tex(src, uv).rgb;

    // Bright seam line where the tear occurs.
    float seamLine = smoothstep(0.004, 0.0, abs(in.uv.y - seam));
    processed += seamLine * intensity * 0.5;

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Signal Corruption

// Blocks of garbled / inverted / shifted color, like dropped transmission packets.
fragment float4 fx_glitch_signalCorruption(RasterizerData in [[stage_in]],
                                           texture2d<float> src [[texture(0)]],
                                           texture2d<float> orig [[texture(1)]],
                                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float t = floor(u.time * speed * 6.0);
    float2 blockCount = float2(20.0, 12.0);
    float2 block = floor(in.uv * blockCount);
    float n = spectra_hash21(block + t * 3.31);
    float corrupt = step(1.0 - intensity * 0.5, n);

    float3 c = spectra_tex(src, in.uv).rgb;
    // Garble: invert and rotate the channels of corrupted blocks.
    float3 garbled = 1.0 - c.gbr;
    float kind = spectra_hash11(block.x * 3.7 + block.y * 1.9 + t);
    garbled = mix(garbled, c.brg, step(0.5, kind));
    float3 processed = mix(c, garbled, corrupt);

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Digital Failure

// Combined breakdown: pixel dropouts, garbled color blocks, and additive noise.
fragment float4 fx_glitch_digitalFailure(RasterizerData in [[stage_in]],
                                         texture2d<float> src [[texture(0)]],
                                         texture2d<float> orig [[texture(1)]],
                                         constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float t = floor(u.time * speed * 5.0);
    float3 c = spectra_tex(src, in.uv).rgb;

    // 1) Color blocks.
    float2 block = floor(in.uv * float2(16.0, 16.0));
    float bn = spectra_hash21(block + t * 2.13);
    float corrupt = step(1.0 - intensity * 0.5, bn);
    float3 garbled = 1.0 - c.gbr;

    // 2) Dropouts: whole blocks go black or white.
    float dn = spectra_hash21(block * 1.93 + t * 5.7);
    float dropout = step(1.0 - intensity * 0.25, dn);
    float3 dropColor = float3(step(0.5, spectra_hash11(bn + t)));

    // 3) Additive grain.
    float grain = spectra_gaussianNoise(in.uv * u.resolution * 0.5 + t) * intensity * 0.25;

    float3 processed = c;
    processed = mix(processed, garbled, corrupt);
    processed = mix(processed, dropColor, dropout);
    processed += grain;

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Compression Glitch

// Macroblock displacement: DCT-style blocks slide by a per-block motion vector,
// like a heavily damaged inter-frame.
fragment float4 fx_glitch_compression(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float blockiness = u.params[0];
    float intensity = u.params[1];
    float speed = u.params[2];

    float t = floor(u.time * speed * 4.0);
    float blocks = mix(8.0, 48.0, clamp(blockiness, 0.0, 1.0));
    float2 block = floor(in.uv * blocks);
    float2 mv = (spectra_hash22(block + t * 1.7) * 2.0 - 1.0);
    float gate = step(0.6, spectra_hash21(block * 2.1 + t));
    float2 offset = mv * intensity * 0.08 * gate;

    float3 c = spectra_tex(src, in.uv + offset).rgb;
    // Quantize color of displaced blocks for a low-bitrate look.
    float q = mix(32.0, 6.0, clamp(intensity, 0.0, 1.0) * gate);
    float3 processed = floor(c * q) / q;
    processed = mix(c, processed, gate);

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Buffer Corruption

// Rows offset by a hashed amount, like a frame buffer read with a corrupt stride.
fragment float4 fx_glitch_bufferCorruption(RasterizerData in [[stage_in]],
                                           texture2d<float> src [[texture(0)]],
                                           texture2d<float> orig [[texture(1)]],
                                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float t = floor(u.time * speed * 10.0);
    float row = floor(in.uv.y * u.resolution.y);
    // Each row gets a hashed horizontal offset; banded by clustering rows.
    float band = floor(row / 4.0);
    float h = spectra_hash21(float2(band, t));
    float active = step(1.0 - intensity, h * h);   // bias toward fewer active rows
    float shift = (spectra_hash11(band * 2.3 + t * 1.1) * 2.0 - 1.0) * intensity * 0.5;

    float2 uv = in.uv;
    uv.x = fract(uv.x + shift * active);
    float3 processed = spectra_texWrap(src, uv).rgb;

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Bit Crush

// Reduce bit depth per channel. Not animated.
fragment float4 fx_glitch_bitCrush(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float bits = clamp(u.params[0], 1.0, 8.0);
    float levels = exp2(bits) - 1.0;
    float3 processed = floor(c * levels + 0.5) / levels;

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Macroblocking

// Average each block to a flat color (pixelation) and stamp occasional block
// errors (offset / inverted blocks). Not animated by default.
fragment float4 fx_glitch_macroblocking(RasterizerData in [[stage_in]],
                                        texture2d<float> src [[texture(0)]],
                                        texture2d<float> orig [[texture(1)]],
                                        constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float blockSize = max(u.params[0], 2.0);
    float intensity = u.params[1];

    float2 px = in.uv * u.resolution;
    float2 blockOrigin = floor(px / blockSize) * blockSize;
    float2 blockUV = (blockOrigin + blockSize * 0.5) * u.texelSize;

    // Cheap block average via a small fixed grid of taps within the block.
    float3 avg = float3(0.0);
    const int N = 3;
    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            float2 o = (float2(x, y) + 0.5) / float(N) - 0.5;
            avg += spectra_tex(src, blockUV + o * blockSize * u.texelSize).rgb;
        }
    }
    avg /= float(N * N);

    // Block errors: some blocks invert or quantize harshly.
    float2 blockId = floor(blockOrigin / blockSize);
    float err = spectra_hash21(blockId);
    float bad = step(1.0 - intensity * 0.4, err);
    float3 errColor = 1.0 - avg;
    float3 processed = mix(avg, errColor, bad);

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Frame Repeat

// Genuine frame hold: between repeat boundaries the previous frame (history,
// texture 10) is shown instead of the live one, so motion truly stutters and
// repeats. At each boundary the held frame refreshes to the current frame.
fragment float4 fx_glitch_frameRepeat(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      texture2d<float> orig [[texture(1)]],
                                      texture2d<float> history [[texture(10)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float rate = u.params[0];

    // Within each interval, hold last frame; only refresh on the boundary frame.
    float interval = max(rate, 0.0001);
    float phase = fract(u.time * interval);
    float boundary = step(phase, interval * 2.0);   // ~1 only just after a boundary
    float3 current = spectra_tex(src, in.uv).rgb;
    float3 held = spectra_tex(history, in.uv).rgb;
    float3 processed = mix(held, current, boundary);

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Frame Skip

// Dropped frames: on a random subset of intervals the live frame is "lost" and
// the previous frame (history, texture 10) is shown instead, with a brief
// channel-mismatch flash at the drop, like a stream skipping frames.
fragment float4 fx_glitch_frameSkip(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    texture2d<float> orig [[texture(1)]],
                                    texture2d<float> history [[texture(10)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float rate = u.params[0];
    float intensity = u.params[1];

    float stepT = glitch_stepTime(u.time, rate);
    float phase = fract(u.time * max(rate, 0.0001));   // 0..1 within current interval
    float s = spectra_hash11(stepT * 9.1 + u.seed * 3.0);

    float3 current = spectra_tex(src, in.uv).rgb;
    float3 prev = spectra_tex(history, in.uv).rgb;
    // This interval is a "dropped" frame: show the previous frame instead.
    float dropped = step(1.0 - intensity * 0.7, s);
    float3 c = mix(current, prev, dropped);
    // Channel-mismatch flash right at the drop boundary.
    float pulse = (1.0 - smoothstep(0.0, 0.3, phase)) * dropped;
    float3 flash = float3(spectra_tex(history, in.uv + float2(0.01, 0.0)).r, c.g, c.b);
    float3 processed = mix(c, flash, pulse);

    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Digital Rain

// A coarse 4x5 bit pattern selected by a hash, sampled at a local cell
// coordinate. Patterns are abstract blocky shapes that read as falling glyphs
// rather than legible characters; quantizing the seed into one of 16 patterns
// keeps each cell stable until its glyph is re-rolled. `p` is in 0..1 within the
// cell. Bits are packed MSB-first per row (bit 3 = leftmost of 4 columns).
inline float glitch_glyph(float2 p, float seed) {
    // 16 hand-picked masks (each 20 bits, one row per 5-bit nibble group). We
    // derive 20 on/off bits from the seed instead of a literal table so the GPU
    // stays branch-light: hash the (column,row) pair per glyph cell.
    int gx = int(clamp(p.x, 0.0, 0.999) * 4.0);   // 0..3 columns
    int gy = int(clamp(p.y, 0.0, 0.999) * 5.0);   // 0..4 rows
    // One bit per (gx,gy) drawn from a hash of the glyph seed; ~55% fill reads as
    // a dense character without looking like solid blocks.
    float bit = spectra_hash21(float2(float(gx) + 0.5, float(gy) + 0.5) + seed * 37.0);
    return step(0.45, bit);
}

// Matrix-style vertical falling glyphs composited OVER the source so the rain
// glows on dark areas. Purely time-based (no history): each column scrolls a
// drop downward; the leading "head" cell is bright near-white-green and the
// trailing cells fade exponentially to dark phosphor green.
fragment float4 fx_glitch_digitalRain(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];                 // overall opacity/brightness (0..1)
    float density = u.params[1];                   // column count / cell fineness (0..1)
    float speed = u.params[2];                     // scroll speed

    // Aspect-correct so cells are roughly square: scale the vertical axis by the
    // frame aspect ratio before laying out the grid. Without this, columns/cells
    // stretch on wide displays and the glyphs smear.
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    // Map density 0..1 onto a sensible column count. ~24 columns at the low end,
    // ~96 at the high end keeps glyphs legible-as-shapes at any setting.
    float columns = mix(24.0, 96.0, clamp(density, 0.0, 1.0));
    float rows = max(columns / aspect, 1.0);       // square cells given the aspect

    float2 cell = float2(in.uv.x * columns, in.uv.y * rows);
    float colIndex = floor(cell.x);
    float2 cellLocal = fract(cell);                // 0..1 within the current cell

    // Per-column pseudo-random phase and a speed multiplier so drops desync.
    float colRand = spectra_hash11(colIndex * 1.731 + 3.17);
    float colSpeed = mix(0.5, 1.5, spectra_hash11(colIndex * 0.913 + 11.1));
    // The drop's head position scrolls downward over time (uv.y grows downward in
    // this space). Offsetting by the per-column phase staggers the columns.
    float headRow = u.time * speed * colSpeed + colRand * rows;
    float cellRow = floor(cell.y);

    // Distance, in whole cells, that this cell trails BEHIND the head. We wrap to
    // the column height so the drop repeats seamlessly down the screen.
    float trail = headRow - cellRow;
    trail = trail - floor(trail / rows) * rows;    // wrap into 0..rows

    // Head is the freshest cell (trail≈0); brightness falls off exponentially
    // along the trail to a dim phosphor tail.
    float head = smoothstep(0.0, 1.0, 1.0 - clamp(trail, 0.0, 1.0));   // 1 at head
    float tail = exp(-trail * 0.35);                                   // exponential fade

    // Glyph for this cell, re-rolled a few times per second so characters flicker
    // and change. Seed combines the column, the cell row, and a quantized time.
    float changeRate = 6.0;
    float glyphSeed = spectra_hash21(float2(colIndex, cellRow + floor(u.time * changeRate) * 0.137));
    float glyph = glitch_glyph(cellLocal, glyphSeed);

    // Phosphor-green palette: bright near-white-green head, dim green trail.
    float3 trailColor = float3(0.1, 0.9, 0.25);
    float3 headColor = float3(0.75, 1.0, 0.8);
    float3 rain = mix(trailColor, headColor, head) * tail * glyph;

    // Screen the emissive rain onto the source so it glows additively on dark
    // areas without clipping bright regions to white.
    float3 emissive = rain * intensity;
    float3 processed = 1.0 - (1.0 - c) * (1.0 - clamp(emissive, 0.0, 1.0));

    return spectra_compositeRGBA(base, processed, u);
}
