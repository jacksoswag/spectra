// Interaction.metal — event-driven overlay effects (MAOE §7.1)
//
// Each effect reads the system-injected pointer block (slots 16–45) and/or the event block
// (slots 46–62) — see EffectChainRenderer's `injectPointer` / `injectEvent` — plus its OWN
// params at slots 0–15 in declaration order (a `.color` occupies 4 slots, so scalars follow
// at slot 4 when a colour leads; effects with no colour start their scalars at slot 0). They
// self-decay off the relevant age and ride the §5.2 decay render gate, so idle cost is zero.

#include "SpectraCommon.h"

// MARK: - Injected-block accessors (keep in sync with EffectChainRenderer slot layout)

inline float2 int_clickPoint(constant SpectraUniforms &u) { return float2(u.params[16], u.params[17]); }
inline float  int_clickAge(constant SpectraUniforms &u)   { return u.params[18]; }
inline float  int_pressActive(constant SpectraUniforms &u){ return u.params[19]; }
inline float  int_releaseAge(constant SpectraUniforms &u) { return u.params[20]; }
inline float  int_trailCount(constant SpectraUniforms &u) { return u.params[21]; }
inline float2 int_trail(constant SpectraUniforms &u, int i){ return float2(u.params[22 + i * 2], u.params[23 + i * 2]); }

// Liveness of a press-driven effect: full while held, fading ~120 ms after release.
inline float int_trailLive(constant SpectraUniforms &u) {
    return int_pressActive(u) > 0.5 ? 1.0 : clamp(1.0 - int_releaseAge(u) / 0.12, 0.0, 1.0);
}

inline float  int_scrollAge(constant SpectraUniforms &u)  { return u.params[46]; }
inline float2 int_scrollDelta(constant SpectraUniforms &u){ return float2(u.params[47], u.params[48]); }
inline float  int_spaceAge(constant SpectraUniforms &u)   { return u.params[49]; }
inline float  int_pressAge(constant SpectraUniforms &u)   { return u.params[50]; }
inline float  int_lifeAge(constant SpectraUniforms &u)    { return u.params[51]; }
inline float  int_lifeKind(constant SpectraUniforms &u)   { return u.params[52]; }   // 1 open 2 close 3 min
inline float4 int_lifeRect(constant SpectraUniforms &u)   { return float4(u.params[53], u.params[54], u.params[55], u.params[56]); }
inline float2 int_dockDir(constant SpectraUniforms &u)    { return float2(u.params[57], u.params[58]); }
inline float2 int_curPointer(constant SpectraUniforms &u) { return float2(u.params[59], u.params[60]); }
inline float  int_pointerSpeed(constant SpectraUniforms &u){ return u.params[61]; }
inline float  int_moveAge(constant SpectraUniforms &u)    { return u.params[62]; }

inline float int_aspect(constant SpectraUniforms &u) { return u.resolution.x / max(u.resolution.y, 1.0); }
// Aspect-corrected vector from `uv` to `c` (x scaled so a circle reads round in UV).
inline float2 int_av(float2 uv, float2 c, float aspect) { float2 d = uv - c; d.x *= aspect; return d; }
inline float3 int_color(constant SpectraUniforms &u) { return float3(u.params[0], u.params[1], u.params[2]); }

// Ambient globals (MAOE §15.1) — slots 64+.
inline float int_audioLevel(constant SpectraUniforms &u) { return u.params[64]; }
inline float int_audioBass(constant SpectraUniforms &u)  { return u.params[65]; }
inline float int_audioTreble(constant SpectraUniforms &u){ return u.params[67]; }
inline float int_keyAge(constant SpectraUniforms &u)     { return u.params[68]; }
inline float int_keyChar(constant SpectraUniforms &u)    { return u.params[69]; }

// MARK: - Ambient-reactive effects (§15.1)

// Audio-reactive bloom pulse: brightens highlights on the beat, bass-weighted.
// params: 0..3 color, 4 strength
fragment float4 fx_int_audioPulse(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float pulse = clamp(int_audioLevel(u) * max(u.params[4], 0.0), 0.0, 2.0);
    if (pulse <= 1e-4) return float4(base, 1.0);
    float lum = spectra_luma(base);
    float3 glow = base * smoothstep(0.45, 1.0, lum) * pulse;
    float3 outc = base + glow * 0.6 + int_color(u) * glow * int_audioBass(u);
    return spectra_compositeRGBA(base, outc, u);
}

// Keyboard-reactive glyph spawn (Matrix): a cipher glyph blooms on each keystroke, placed
// pseudo-randomly by the key seed. Reads the ambient key block (gated on Input Monitoring).
// params: 0..3 color, 4 glyphSize
fragment float4 fx_int_keyGlyph(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float env = spectra_eventEnvelope(int_keyAge(u), 0.6);
    if (env <= 0.0) return float4(base, 1.0);
    float seed = int_keyChar(u);
    float2 pos = float2(spectra_hash11(seed * 13.0 + 0.3), spectra_hash11(seed * 7.0 + 1.1));
    float2 luv = int_av(in.uv, pos, int_aspect(u)) / max(u.params[4], 0.01) + 0.5;
    float g = (all(luv >= 0.0) && all(luv <= 1.0)) ? glitch_glyph(luv, seed * 16.0) : 0.0;
    return spectra_compositeRGBA(base, base + int_color(u) * g * env, u);
}

// MARK: - Click effects (pointer block)

// Golden Hour: a warm gold ring expanding from the click.
// params: 0..3 color, 4 maxRadius, 5 thickness, 6 life
fragment float4 fx_int_clickPulse(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_clickAge(u), life = max(u.params[6], 0.05);
    float env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float d = length(int_av(in.uv, int_clickPoint(u), int_aspect(u)));
    float r = u.params[4] * (age / life);
    float ring = smoothstep(max(u.params[5], 1e-4), 0.0, abs(d - r));
    return spectra_compositeRGBA(base, base + int_color(u) * u.params[3] * ring * env, u);
}

// Cyberpunk: a dual cyan→magenta ripple with a chromatic split.
// params: 0 maxRadius, 1 thickness, 2 life, 3 split
fragment float4 fx_int_clickRipple(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_clickAge(u), life = max(u.params[2], 0.05);
    float env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float d = length(int_av(in.uv, int_clickPoint(u), int_aspect(u)));
    float r = u.params[0] * (age / life), th = max(u.params[1], 1e-4), split = u.params[3];
    float ringC = smoothstep(th, 0.0, abs(d - (r + split)));
    float ringM = smoothstep(th, 0.0, abs(d - max(r - split, 0.0)));
    float3 outc = base + float3(0.1, 1.0, 1.0) * ringC * env + float3(1.0, 0.1, 0.8) * ringM * env;
    return spectra_compositeRGBA(base, outc, u);
}

// Matrix: a small burst of cipher glyphs scattering from the click.
// params: 0..3 color, 4 count, 5 spread, 6 life, 7 glyphSize
fragment float4 fx_int_glyphBurst(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_clickAge(u), life = max(u.params[6], 0.05);
    float env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float2 c = int_clickPoint(u);
    float aspect = int_aspect(u), t = age / life, gs = max(u.params[7], 0.005);
    int n = clamp(int(u.params[4]), 1, 16);
    float acc = 0.0;
    for (int i = 0; i < n; i++) {
        float a = float(i) / float(n) * 6.2831 + spectra_hash11(float(i)) * 1.2;
        float2 pos = c + float2(cos(a), sin(a)) * u.params[5] * t;
        float2 luv = int_av(in.uv, pos, aspect) / gs + 0.5;
        if (all(luv >= 0.0) && all(luv <= 1.0))
            acc = max(acc, glitch_glyph(luv, float(i) + floor(age * 12.0)));
    }
    return spectra_compositeRGBA(base, base + int_color(u) * acc * env, u);
}

// Noir / artistic: a pressure ink blob darkening the paper from the click.
// params: 0 maxRadius, 1 darkness, 2 life
fragment float4 fx_int_inkRipple(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_clickAge(u), life = max(u.params[2], 0.05);
    float env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float d = length(int_av(in.uv, int_clickPoint(u), int_aspect(u)));
    float r = u.params[0] * (age / life);
    float blob = smoothstep(r, r * 0.4, d);
    float paper = spectra_valueNoise(in.uv * u.resolution.xy * 0.04);
    float ink = blob * env * (0.7 + 0.3 * paper) * max(u.params[1], 0.0);
    return spectra_compositeRGBA(base, base * (1.0 - clamp(ink, 0.0, 0.9)), u);
}

// Comic: a halftone "POW" starburst from the click.
// params: 0..3 color, 4 maxRadius, 5 spikes, 6 life
fragment float4 fx_int_powBurst(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_clickAge(u), life = max(u.params[6], 0.05);
    float env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float2 dv = int_av(in.uv, int_clickPoint(u), int_aspect(u));
    float d = length(dv), ang = atan2(dv.y, dv.x);
    float spikes = 0.55 + 0.45 * cos(ang * max(u.params[5], 1.0));
    float r = u.params[4] * (0.4 + 0.6 * age / life);
    float star = smoothstep(r * spikes, r * spikes * 0.7, d);
    float2 hp = in.uv * u.resolution.xy / 7.0;
    float dots = smoothstep(0.55, 0.45, length(fract(hp) - 0.5));
    return spectra_compositeRGBA(base, mix(base, int_color(u), star * dots * env), u);
}

// Comic: a real comic burst sprite popped at the click with a scale-overshoot + fade — an actual
// sprite animation, not a procedural starburst. One of three words (POW / BANG / POP, textures 8 /
// 12 / 13) is chosen per click, hashed off the click position so each click pops a different one.
// params: 0 size (UV half-extent), 1 life
fragment float4 fx_int_powSprite(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]],
                                 texture2d<float> powSprite [[texture(8)]],
                                 texture2d<float> bangSprite [[texture(12)]],
                                 texture2d<float> popSprite [[texture(13)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_clickAge(u), life = max(u.params[1], 0.1);
    if (age < 0.0 || age > life) return float4(base, 1.0);
    float t = age / life;
    // No fade-IN: the sprite is at full opacity and full size from the first frame; it only fades
    // OUT near the end. A tiny settle on the size keeps it from feeling static, but never grows in.
    float fade = 1.0 - smoothstep(0.62, 1.0, t);
    float settle = 1.0 + 0.06 * (1.0 - smoothstep(0.0, 0.12, t));
    float halfSz = max(u.params[0], 0.01) * settle;
    float aspect = int_aspect(u);
    float2 c = int_clickPoint(u);                               // centred on the cursor (was offset above it)
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // Stable per-click pick (clickPoint is constant for the click's lifetime, so the word doesn't
    // flicker mid-animation; it changes from click to click).
    int pick = min(2, int(spectra_hash21(int_clickPoint(u) * 53.0) * 3.0));
    // The star's inner colour, for the splatter (sampled at the sprite centre).
    float3 splatCol = ((pick == 0) ? powSprite.sample(s, float2(0.5))
                     : (pick == 1) ? bangSprite.sample(s, float2(0.5))
                                   : popSprite.sample(s, float2(0.5))).rgb;

    float2 dvp = in.uv - c; dvp.x *= aspect;
    // Splatter: a few ink dabs flung outward around the sprite in its inner colour, thrown out
    // quickly then fading with the sprite.
    float splat = 0.0;
    float throwT = smoothstep(0.0, 0.22, t);
    for (int k = 0; k < 10; k++) {
        float fk = float(k);
        float ka = fk / 10.0 * 6.2831 + spectra_hash11(fk) * 0.7;
        float kr = halfSz * (0.85 + spectra_hash11(fk + 3.0) * 0.55) * throwT;   // tighter to the sprite
        float2 sc = c + float2(cos(ka), sin(ka)) * float2(kr / aspect, kr);
        float ksz = halfSz * (0.06 + 0.10 * spectra_hash11(fk + 7.0));
        float2 dd = (in.uv - sc); dd.x *= aspect;
        splat = max(splat, smoothstep(ksz, 0.0, length(dd)));
    }
    float3 outc = base * (1.0 - splat * fade * 0.55) + splatCol * splat * fade * 0.55;

    float2 luv = dvp / (2.0 * halfSz) + 0.5;
    if (all(luv >= 0.0) && all(luv <= 1.0)) {
        float4 sp = (pick == 0) ? powSprite.sample(s, luv)
                  : (pick == 1) ? bangSprite.sample(s, luv)
                                : popSprite.sample(s, luv);      // premultiplied
        // Hand-drawn roughness: nibble the sprite edge with noise so it doesn't read as a clean
        // vector decal (interior stays solid since the noise only bites where alpha is partial).
        float rough = spectra_valueNoise(luv * 26.0 + floor(age * 18.0));
        float a = sp.a * (0.80 + 0.20 * rough);
        outc = outc * (1.0 - a * fade) + sp.rgb * fade;
    }
    return spectra_compositeRGBA(base, outc, u);
}

// (The Painting "paint ripple" is no longer a separate composite effect — it now lives inside
// style.oil: holding the button boosts the oil's vanGogh parameter in a ripple around the cursor
// via `oil_vanGoghBoost` in Style.metal. See fx_style_oil_cells / fx_style_oil_combine.)

// MARK: - Drag / trail effects (pointer block)

// Golden Hour drag: sparse floating gold dust — independent fading motes scattered around the
// recent pointer path that drift upward and fade on their OWN age, never joined into a line.
// params: 0..3 color, 4 size
fragment float4 fx_int_dragTrail(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float live = int_trailLive(u), n = int_trailCount(u);
    if (live <= 0.0 || n < 1.0) return float4(base, 1.0);
    float aspect = int_aspect(u), sz = max(u.params[4], 0.004);
    float2 p = in.uv; p.x *= aspect;
    int cnt = int(min(n, 12.0));
    float acc = 0.0;
    for (int i = 0; i < 12; i++) {
        if (i >= cnt) break;
        float2 tp = int_trail(u, i); tp.x *= aspect;
        float age = float(i) / 12.0;                       // older trail points = older motes
        // A few motes per sampled point, hash-scattered and drifting up as they age — each is its
        // own little gaussian dot, with no segment joining it to the next (so it reads as dust).
        for (int m = 0; m < 3; m++) {
            float seed = float(i) * 4.0 + float(m) * 1.37;
            float hx = spectra_hash11(seed) - 0.5;
            float hy = spectra_hash11(seed + 9.1);
            float hs = spectra_hash11(seed + 3.7);
            float2 off = float2(hx * sz * 5.0, -(0.5 + hy) * age * 0.06 - hs * sz * 2.0);  // up-drift
            float ms = sz * (0.35 + 0.8 * hs);             // varied mote size
            float dd = length(p - (tp + off));
            float mote = smoothstep(ms, 0.0, dd) * (1.0 - age) * (0.4 + 0.6 * hy);  // independent fade
            acc = max(acc, mote);
        }
    }
    return spectra_compositeRGBA(base, base + int_color(u) * acc * live, u);
}

// Liquid surface-tension trail: refract the image toward the recent path.
// params: 0 strength
fragment float4 fx_int_liquidTrail(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float live = int_trailLive(u), n = int_trailCount(u);
    if (live <= 0.0 || n < 1.0) return float4(base, 1.0);
    float aspect = int_aspect(u), str = max(u.params[0], 0.0);
    float2 disp = float2(0.0);
    for (int i = 0; i < 12; i++) {
        if (float(i) >= n) break;
        float2 dv = int_av(in.uv, int_trail(u, i), aspect);
        float dd = length(dv);
        disp += normalize(dv + 1e-5) * exp(-dd * 45.0) * (1.0 - float(i) / 12.0);
    }
    float3 c = spectra_tex(src, in.uv - disp * str * 0.02 * live).rgb;
    return spectra_compositeRGBA(base, c, u);
}

// Cipher glyphs stamped along the pointer path (Matrix).
// params: 0..3 color, 4 glyphSize
fragment float4 fx_int_glyphTrail(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float live = int_trailLive(u), n = int_trailCount(u);
    if (live <= 0.0 || n < 1.0) return float4(base, 1.0);
    float aspect = int_aspect(u), gs = max(u.params[4], 0.01), acc = 0.0;
    for (int i = 0; i < 12; i++) {
        if (float(i) >= n) break;
        float2 luv = int_av(in.uv, int_trail(u, i), aspect) / gs + 0.5;
        if (all(luv >= 0.0) && all(luv <= 1.0))
            acc = max(acc, glitch_glyph(luv, float(i) * 3.0) * (1.0 - float(i) / 12.0));
    }
    return spectra_compositeRGBA(base, base + int_color(u) * acc * live, u);
}

// Noir: a soft shadow that deforms (darkens) under the drag path.
// params: 0 darkness, 1 radius
fragment float4 fx_int_shadowDeform(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float live = int_trailLive(u), n = int_trailCount(u);
    if (live <= 0.0 || n < 1.0) return float4(base, 1.0);
    float aspect = int_aspect(u), rad = max(u.params[1], 0.01), shade = 0.0;
    for (int i = 0; i < 12; i++) {
        if (float(i) >= n) break;
        float dd = length(int_av(in.uv, int_trail(u, i), aspect));
        shade = max(shade, smoothstep(rad, 0.0, dd) * (1.0 - float(i) / 12.0));
    }
    return spectra_compositeRGBA(base, base * (1.0 - clamp(u.params[0] * shade * live, 0.0, 0.8)), u);
}

// MARK: - Scroll / movement effects (event block)

// Matrix: columns of glyphs drift in the scroll direction.
// params: 0..3 color, 4 columns, 5 life
fragment float4 fx_int_scrollDrift(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_scrollAge(u), env = spectra_eventEnvelope(age, max(u.params[5], 0.1));
    if (env <= 0.0) return float4(base, 1.0);
    float aspect = int_aspect(u), cols = max(u.params[4], 4.0);
    float dir = (int_scrollDelta(u).y >= 0.0) ? 1.0 : -1.0;
    float2 cell = float2(in.uv.x * cols, in.uv.y * cols / aspect - dir * age * 6.0);
    float g = glitch_glyph(fract(cell), floor(cell.x) + floor(cell.y) * 0.13);
    return spectra_compositeRGBA(base, base + int_color(u) * g * env * 0.8, u);
}

// Print Art: CMYK registration offset driven by pointer + scroll velocity.
// params: 0 strength
fragment float4 fx_int_cmykShift(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float vel = clamp(int_pointerSpeed(u) * 0.6 + length(int_scrollDelta(u)) * 0.02, 0.0, 1.0);
    float amt = vel * max(u.params[0], 0.0) * 0.01;
    if (amt <= 1e-5) return float4(base, 1.0);
    float3 cyan = spectra_tex(src, in.uv + float2(amt, 0.0)).rgb;
    float3 mag  = spectra_tex(src, in.uv - float2(amt, 0.0)).rgb;
    float3 yel  = spectra_tex(src, in.uv + float2(0.0, amt)).rgb;
    return spectra_compositeRGBA(base, float3(cyan.r, mag.g, yel.b), u);
}

// Fuji: a small warm disposable-camera light-leak that PERSISTS while the button is held (a thin
// diagonal flare confined to a tight blob), TRACKING the live cursor so the leak slides along with
// a drag instead of staying pinned to the press origin; eases out shortly after release.
// params: 0..3 color, 4 life (unused — the press envelope drives liveness)
fragment float4 fx_int_lightLeak(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float live = int_trailLive(u);                                // held → 1; fades ~120 ms after release
    if (live <= 0.0) return float4(base, 1.0);
    float2 d = int_av(in.uv, int_trail(u, 0), int_aspect(u));     // vector to the LIVE cursor (trail head), so the leak follows a drag
    float streak = exp(-pow((d.x - d.y) * 12.0, 2.0));           // ovalness halved (wider, rounder flare)
    float radial = exp(-dot(d, d) * 600.0);                      // size halved (4× coefficient = ½ radius)
    return spectra_compositeRGBA(base, base + int_color(u) * streak * radial * live * 0.25, u);
}

// Comic: speed-lines radiating from a fast cursor.
// params: 0 density, 1 falloff
fragment float4 fx_int_speedLines(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float env = clamp(int_pointerSpeed(u) * 1.5 - 0.15, 0.0, 1.0);
    if (env <= 0.0) return float4(base, 1.0);
    float2 dv = int_av(in.uv, int_curPointer(u), int_aspect(u));
    float ang = atan2(dv.y, dv.x), d = length(dv);
    float lines = smoothstep(0.55, 0.85, 0.5 + 0.5 * sin(ang * max(u.params[0], 8.0)));
    float fade = smoothstep(max(u.params[1], 0.05), 0.12, d);
    return spectra_compositeRGBA(base, mix(base, base * 0.15, lines * fade * env * 0.6), u);
}

// MARK: - Space-switch effects (event block)

// Cyberpunk: radial velocity streaks across the space transition.
// params: 0 strength, 1 life
fragment float4 fx_int_hyperspaceStreak(RasterizerData in [[stage_in]],
                                        texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                        constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float env = spectra_eventEnvelope(int_spaceAge(u), max(u.params[1], 0.1));
    if (env <= 0.0) return float4(base, 1.0);
    float2 dir = in.uv - 0.5;
    float3 acc = base;
    for (int k = 1; k <= 6; k++) acc += spectra_tex(src, in.uv - dir * 0.03 * float(k) * env * max(u.params[0], 0.0)).rgb;
    acc /= 7.0;
    return spectra_compositeRGBA(base, mix(base, acc, env), u);
}

// Matrix: a dense glyph-rain burst filling the space-switch black bar.
// params: 0..3 color, 4 columns, 5 life
fragment float4 fx_int_spaceGlyphRain(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_spaceAge(u), env = spectra_eventEnvelope(age, max(u.params[5], 0.1));
    if (env <= 0.0) return float4(base, 1.0);
    float aspect = int_aspect(u), cols = max(u.params[4], 8.0);
    float2 cell = float2(in.uv.x * cols, in.uv.y * cols / aspect - age * 10.0);
    float g = glitch_glyph(fract(cell), floor(cell.x) * 1.3 + floor(cell.y));
    return spectra_compositeRGBA(base, base + int_color(u) * g * env, u);
}

// Noir: an iris closing to black then opening across the space switch.
// params: 0 life
fragment float4 fx_int_iris(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_spaceAge(u), life = max(u.params[0], 0.2);
    if (age < 0.0 || age > life) return float4(base, 1.0);
    float t = age / life;
    // Soft closing vignette tracking the Space swipe: open at the start, fully shut at the
    // half-way point, re-expanding as the next Space comes on-screen. `close` is 0→1→0 over the
    // transition (sine, so the motion eases at both ends).
    float close = sin(t * 3.14159265);
    float d = length(int_av(in.uv, float2(0.5), int_aspect(u)));   // 0 centre … ~0.72 corner
    float radius = mix(1.0, -0.4, close);                          // dark-edge radius shrinks inward
    float vig = smoothstep(radius, radius + 0.30, d);              // soft edge, not a hard iris circle
    return spectra_compositeRGBA(base, base * (1.0 - vig), u);
}

// Fuji: film-sprocket squares sweeping the space-switch transition.
// params: 0..3 color, 4 life
fragment float4 fx_int_filmSquares(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float age = int_spaceAge(u), env = spectra_eventEnvelope(age, max(u.params[4], 0.1));
    if (env <= 0.0) return float4(base, 1.0);
    float strip = step(in.uv.y, 0.12) + step(0.88, in.uv.y);
    float2 hole = fract(float2(in.uv.x * 14.0 - age * 8.0, in.uv.y * 8.0));
    float sq = step(0.25, hole.x) * step(hole.x, 0.75) * step(0.25, hole.y) * step(hole.y, 0.75);
    return spectra_compositeRGBA(base, mix(base, int_color(u), strip * sq * env), u);
}

// MARK: - Window-lifecycle bursts (event block; rect = the window's last position)

inline bool int_isClose(constant SpectraUniforms &u)   { float k = int_lifeKind(u); return k > 1.5 && k < 2.5; }
inline bool int_isMinimize(constant SpectraUniforms &u){ float k = int_lifeKind(u); return k > 2.5; }
inline bool int_isOpen(constant SpectraUniforms &u)    { float k = int_lifeKind(u); return k > 0.5 && k < 1.5; }
inline float2 int_lifeCenter(constant SpectraUniforms &u) { float4 r = int_lifeRect(u); return r.xy + r.zw * 0.5; }

// Frutiger: a bubble pops where a closed window was.
// params: 0..3 color, 4 life
fragment float4 fx_int_bubblePop(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    if (!int_isClose(u)) return float4(base, 1.0);
    float age = int_lifeAge(u), life = max(u.params[4], 0.1), env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float d = length(int_av(in.uv, int_lifeCenter(u), int_aspect(u)));
    float r = 0.12 * (age / life);
    float ring = smoothstep(0.02, 0.0, abs(d - r));
    return spectra_compositeRGBA(base, base + int_color(u) * ring * env, u);
}

// Frutiger: bubbles drift from a minimized window toward the Dock.
// params: 0..3 color, 4 life
fragment float4 fx_int_bubbleTrail(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    if (!int_isMinimize(u)) return float4(base, 1.0);
    float age = int_lifeAge(u), life = max(u.params[4], 0.1), env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float aspect = int_aspect(u), t = age / life, acc = 0.0;
    float2 start = int_lifeCenter(u), dir = normalize(int_dockDir(u) + 1e-4);
    for (int i = 0; i < 6; i++) {
        float ph = t - float(i) * 0.12;
        if (ph < 0.0 || ph > 1.0) continue;
        float2 pos = start + dir * ph * 0.6;
        float dd = length(int_av(in.uv, pos, aspect));
        acc = max(acc, smoothstep(0.02, 0.0, dd) * (1.0 - ph));
    }
    return spectra_compositeRGBA(base, base + int_color(u) * acc * env, u);
}

// Cyberpunk: a glitch flash where a window opened.
// params: 0 life
fragment float4 fx_int_windowGlitch(RasterizerData in [[stage_in]],
                                    texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                    constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    if (!int_isOpen(u)) return float4(base, 1.0);
    float age = int_lifeAge(u), env = spectra_eventEnvelope(age, max(u.params[0], 0.1));
    if (env <= 0.0) return float4(base, 1.0);
    float4 r = int_lifeRect(u);
    if (any(in.uv < r.xy) || any(in.uv > r.xy + r.zw)) return float4(base, 1.0);
    float band = step(0.5, fract(in.uv.y * 40.0 + age * 30.0));
    float2 sh = float2(0.02 * band * env, 0.0);
    float3 g = float3(spectra_tex(src, in.uv + sh).r, base.g, spectra_tex(src, in.uv - sh).b);
    return spectra_compositeRGBA(base, mix(base, g + float3(0.0, 0.3, 0.4) * band, env), u);
}

// Golden Hour: a soft shadow collapses inward where a window closed/minimized.
// params: 0 life
fragment float4 fx_int_shadowCollapse(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    if (!(int_isClose(u) || int_isMinimize(u))) return float4(base, 1.0);
    float age = int_lifeAge(u), life = max(u.params[0], 0.1), env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float d = length(int_av(in.uv, int_lifeCenter(u), int_aspect(u)));
    float r = 0.18 * (1.0 - age / life);            // collapses inward
    float shade = smoothstep(r + 0.05, r, d) * (1.0 - smoothstep(r, r - 0.06, d));
    return spectra_compositeRGBA(base, base * (1.0 - 0.5 * shade * env), u);
}

// Noir: a silent-film caption boundary collapses where a window closed/minimized.
// params: 0 life
fragment float4 fx_int_captionCollapse(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    if (!(int_isClose(u) || int_isMinimize(u))) return float4(base, 1.0);
    float age = int_lifeAge(u), life = max(u.params[0], 0.1), env = spectra_eventEnvelope(age, life);
    if (env <= 0.0) return float4(base, 1.0);
    float4 r = int_lifeRect(u);
    float2 cen = r.xy + r.zw * 0.5;
    float2 hf = r.zw * 0.5 * (1.0 - age / life);    // boundary shrinks to the centre
    float2 dv = abs(in.uv - cen);
    float frame = step(hf.x - 0.004, dv.x) * step(dv.x, hf.x + 0.004)
                + step(hf.y - 0.004, dv.y) * step(dv.y, hf.y + 0.004);
    float inside = step(dv.x, hf.x) * step(dv.y, hf.y);
    float3 outc = mix(base, float3(0.0), inside * 0.4 * env);          // darken the collapsing interior
    outc = mix(outc, float3(0.95), clamp(frame, 0.0, 1.0) * env);      // white caption border
    return spectra_compositeRGBA(base, outc, u);
}

// Matrix: a glyph scramble over a newly-opened window that resolves to its content.
// params: 0..3 color, 4 life, 5 columns
fragment float4 fx_int_decode(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    if (!int_isOpen(u)) return float4(base, 1.0);
    float age = int_lifeAge(u), life = max(u.params[4], 0.1);
    if (age < 0.0 || age > life) return float4(base, 1.0);
    float4 r = int_lifeRect(u);
    if (any(in.uv < r.xy) || any(in.uv > r.xy + r.zw)) return float4(base, 1.0);
    float t = age / life;
    float aspect = int_aspect(u), cols = max(u.params[5], 8.0);
    float2 cell = float2(in.uv.x * cols, in.uv.y * cols / aspect);
    float lockT = spectra_hash21(floor(cell));        // per-cell resolve time
    float scrambled = step(t, lockT);                 // 1 while still scrambling
    float g = glitch_glyph(fract(cell), floor(cell.x) + floor(cell.y) + floor(age * 20.0));
    return spectra_compositeRGBA(base, mix(base, int_color(u) * g, scrambled), u);
}
