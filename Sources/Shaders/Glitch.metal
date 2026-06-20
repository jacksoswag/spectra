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

// A 5x7 BITMAP FONT of 16 CRYPTOGRAPHIC glyphs — invented cipher/rune symbols, NO standard
// letters or digits, so the rain reads as alien code. Each glyph is 7 rows; each row is a
// 5-bit mask with the MSB (bit 4) as the leftmost column. A hashed index picks the glyph; the
// cell-local coordinate samples it crisply (hard pixels read as authentic terminal type).
constant uint glitch_glyphFont[112] = {
     4, 4,21,14,21, 4, 4,   // eye / node
    17,10, 4,31, 4,10,17,   // barred X
    28,16,30, 2,15, 1, 3,   // angular rune
    27,17, 0, 4, 0,17,27,   // bracketed dot
    16,24,12, 6, 3, 6,12,   // zigzag
    31, 4, 4,14, 4, 4, 4,   // crowned stem
    24, 4,30, 4,15, 4, 3,   // asymmetric hooks
     4,14,31,14, 4,10,17,   // diamond + legs
    17,31,17,31,17,31,17,   // ladder
    14,17,22,21,13, 1, 6,   // spiral
    10, 0,31, 0,10, 0, 4,   // dotted bars
     4,14,21, 4, 4,21,14,   // twin arrows
     4, 4, 0, 4, 0, 4, 4,   // dashed axis
    28,16,16, 0, 1, 1, 7,   // opposed corners
    10,31,10,31,10, 0, 4,   // grid
    17,10, 4,10,17, 0,31,   // crosshatch + base
};

// Sample the bitmap font for the glyph chosen by `seed`. `p` is 0..1 within the cell; a thin
// gutter keeps adjacent glyphs from merging into a block.
inline float glitch_glyph(float2 p, float seed) {
    if (p.x < 0.04 || p.x > 0.96 || p.y < 0.02 || p.y > 0.98) return 0.0;   // inter-glyph gutter
    int col = int(clamp((p.x - 0.04) / 0.92, 0.0, 0.999) * 5.0);   // 0..4
    int row = int(clamp((p.y - 0.02) / 0.96, 0.0, 0.999) * 7.0);   // 0..6
    int glyph = int(spectra_hash11(seed) * 16.0) & 15;             // pick 0..15
    uint rowBits = glitch_glyphFont[glyph * 7 + row];
    return (rowBits & (1u << uint(4 - col))) != 0u ? 1.0 : 0.0;    // MSB = leftmost column
}

// One depth layer of falling code: a grid of `columns` streams scrolling down, each with a
// per-column phase, a speed jitter, and an active/empty roll (so it isn't a solid wall). The
// head cell is bright near-white-green; the trail fades exponentially to dim phosphor green.
// Returned emissive, pre-scaled by `bright`. All ALU (no texture reads), so layers are cheap.
inline float3 glitch_rainLayer(float2 uv, float time, float columns, float aspect,
                               float layerSpeed, float bright, float seed) {
    float rows = max(columns / aspect, 1.0);       // square cells given the aspect
    float2 cell = float2(uv.x * columns, uv.y * rows);
    float colIndex = floor(cell.x);
    float2 cellLocal = fract(cell);

    // Per-column phase + speed jitter so drops desync; ~80% of columns carry a stream.
    float colRand   = spectra_hash11(colIndex * 1.731 + 3.17 + seed);
    float colSpeed  = mix(0.7, 1.3, spectra_hash11(colIndex * 0.913 + 11.1 + seed));
    float colActive = step(0.2, spectra_hash11(colIndex * 2.7 + 5.0 + seed));

    float headRow = time * layerSpeed * colSpeed + colRand * rows;
    float cellRow = floor(cell.y);

    // Whole-cell distance this cell trails behind the head, wrapped to the column height.
    float trail = headRow - cellRow;
    trail = trail - floor(trail / rows) * rows;

    float head = smoothstep(0.0, 1.0, 1.0 - clamp(trail, 0.0, 1.0));    // 1 at the head
    // Long trails (~5x the previous): a low fade rate stretches the stream far up the column.
    float tailFade = mix(0.2, 0.112, clamp(bright, 0.0, 1.0));
    float tail = exp(-trail * tailFade);

    // Each cell's glyph is FIXED (no time term): characters never flicker in place — the only
    // new character that appears is the next cell the falling head reveals as it scrolls down.
    float glyphSeed = spectra_hash21(float2(colIndex, cellRow) + seed);
    float glyph = glitch_glyph(cellLocal, glyphSeed);

    float3 trailColor = float3(0.1, 0.9, 0.25);
    float3 headColor  = float3(0.75, 1.0, 0.8);
    return mix(trailColor, headColor, head) * tail * glyph * colActive * bright;
}

// Matrix-style vertical falling code, composited OVER the source so it glows on dark areas.
// THREE depth layers stack to fake depth: a far layer of small, slow, dim glyphs; a mid
// layer; and a near layer of large, fast, bright glyphs with longer tails — so the rain
// reads as cryptographic text receding into the screen rather than one flat grid. Purely
// time-based (no history); all ALU, so the three layers stay cheap. params: 0 intensity,
// 1 density, 2 speed.
fragment float4 fx_glitch_digitalRain(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;

    float intensity = u.params[0];                 // overall opacity/brightness (0..1)
    float density = u.params[1];                   // base stream count / glyph fineness (0..1)
    float speed = u.params[2];                     // scroll speed

    // Aspect-correct so cells are roughly square (otherwise glyphs smear on wide displays).
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    // FEW columns on purpose: ~30 mid-layer streams means each 5x7 glyph is tens of pixels
    // wide and reads as a real character. (At the old ~100+ columns each glyph was a few
    // pixels and just looked like blocks.)
    float baseColumns = mix(20.0, 46.0, clamp(density, 0.0, 1.0));

    // Far → near. THIS array (× baseColumns) sets glyph SIZE: bigger value = more columns =
    // SMALLER glyphs. Far still gets the most columns (smallest glyphs) and near the fewest
    // (biggest), but every layer is scaled up here to shrink the glyphs: far −33%, near −67%.
    const float colScale[3] = { 3.6, 2.0, 1.8 };    // far→near; bigger = smaller glyphs (far floor -33%)
    const float speedMul[3] = { 1.1, 3.0, 5.1 };    // far→near fall rate (far floor -33%)
    const float bright[3]   = { 0.45, 0.7, 1.0 };
    const float seeds[3]    = { 0.0, 53.1, 121.7 };

    float3 rain = float3(0.0);
    for (int i = 0; i < 3; i++) {
        rain += glitch_rainLayer(in.uv, u.time, baseColumns * colScale[i], aspect,
                                 speed * speedMul[i], bright[i], seeds[i]);
    }

    // Screen the emissive rain onto the source so it glows on dark areas without clipping.
    float3 emissive = clamp(rain, 0.0, 1.0) * intensity;
    float3 processed = 1.0 - (1.0 - c) * (1.0 - clamp(emissive, 0.0, 1.0));

    return spectra_compositeRGBA(base, processed, u);
}
