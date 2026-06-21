#include "SpectraCommon.h"

// Environment effects: atmospheric weather and light overlays. Each fragment
// function samples the effect input on texture(0), the original (for
// compositing) on texture(1), reads parameters in declaration order from
// u.params[], and composites the result via spectra_compositeRGBA.
//
// Geometry that needs to look uniform on screen (round flakes, circular flare
// rings) is computed in an aspect-corrected space where one unit is square.

// Aspect ratio (width / height) of the render target, guarded against zero.
inline float fx_env_aspect(constant SpectraUniforms &u) {
    return max(u.resolution.x, 1.0) / max(u.resolution.y, 1.0);
}

// Smooth fbm built from gradient noise; returns roughly [0,1].
inline float fx_env_fbm(float2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float total = 0.0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * spectra_gradientNoise(p);
        total += amplitude;
        p = p * 2.02 + float2(11.7, 5.3);
        amplitude *= 0.5;
    }
    return value / max(total, 1.0e-4);
}

// MARK: - Rain (intensity, speed, angle): streaks + subtle refraction

fragment float4 fx_env_rain(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];
    float angle = u.params[2] * 0.0174532925; // degrees -> radians

    // Slanted rain space: rotate uv so streaks fall along +y.
    float2 p = in.uv;
    p.x *= fx_env_aspect(u);
    float2 r = spectra_rotate(p - 0.5, angle) + 0.5;

    float density = mix(20.0, 90.0, clamp(intensity, 0.0, 1.0));
    float2 cell = float2(r.x * density, r.y * density * 0.18);
    float column = floor(cell.x);
    float colSeed = spectra_hash11(column + u.seed * 53.0);

    // Each column scrolls at its own phase and rate.
    float fall = u.time * (1.0 + speed * 3.0) * (0.6 + colSeed * 0.9);
    float y = cell.y + fall + colSeed * 17.0;
    float drop = fract(y);
    float dropID = floor(y);
    float bright = spectra_hash21(float2(column, dropID));

    // Thin vertical streak with a bright head and fading tail.
    float across = abs(fract(cell.x) - 0.5) * 2.0;
    float streak = smoothstep(1.0, 0.25, across);
    float tail = smoothstep(0.0, 0.18, drop) * smoothstep(1.0, 0.45, drop);
    float spawn = step(0.35, bright);
    float streakAmt = streak * tail * spawn * clamp(intensity, 0.0, 1.0);

    // Subtle horizontal refraction along the streak.
    float2 refr = float2(spectra_rotate(float2(streakAmt * 0.006, 0.0), -angle));
    refr.x /= fx_env_aspect(u);
    float3 c = spectra_tex(src, in.uv + refr).rgb;

    float3 processed = c + streakAmt * float3(0.55, 0.6, 0.7);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Fog (density, height, speed): drifting height-based fog

fragment float4 fx_env_fog(RasterizerData in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           texture2d<float> orig [[texture(1)]],
                           constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float density = u.params[0];
    float height = u.params[1];
    float speed = u.params[2];

    float3 c = spectra_tex(src, in.uv).rgb;

    // Fog thickens toward the bottom up to `height`.
    float vertical = 1.0 - smoothstep(0.0, max(height, 0.02), in.uv.y);

    // Drifting soft noise field.
    float2 drift = float2(u.time * speed * 0.05, u.time * speed * 0.012);
    float n = fx_env_fbm(in.uv * float2(3.0, 1.6) + drift + u.seed * 7.0, 5);
    n = n * 0.7 + 0.45;

    float amount = clamp(density, 0.0, 1.0) * vertical * n;
    float3 fogColor = float3(0.72, 0.75, 0.78);
    float3 processed = mix(c, fogColor, clamp(amount, 0.0, 1.0));
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Snow (intensity, speed, size): falling flakes across layers

fragment float4 fx_env_snow(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];
    float size = u.params[2];

    float3 c = spectra_tex(src, in.uv).rgb;
    float aspect = fx_env_aspect(u);

    float flakes = 0.0;
    // Three depth layers: nearer layers are bigger, faster, brighter.
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float scale = mix(7.0, 16.0, fl / 2.0);
        float depth = 1.0 - fl / 3.0; // 1=near .. ~0.33 far
        float drift = sin(u.time * (0.4 + fl * 0.2) + fl * 2.1) * 0.12;

        float2 p = float2(in.uv.x * aspect + drift, in.uv.y);
        p *= scale;
        p.y += u.time * speed * (0.5 + depth * 0.9) + fl * 31.0 + u.seed * 13.0;

        float2 cellID = floor(p);
        float2 f = fract(p);
        float2 jitter = spectra_hash22(cellID + fl * 7.0);
        float spawn = step(1.0 - clamp(intensity, 0.0, 1.0), spectra_hash21(cellID + fl * 19.0));
        float d = length(f - jitter);
        float radius = mix(0.05, 0.16, size) * depth;
        flakes += (1.0 - smoothstep(radius * 0.3, radius, d)) * spawn * depth;
    }

    float3 processed = c + clamp(flakes, 0.0, 1.0) * float3(0.95, 0.97, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Dust (intensity, speed): floating illuminated motes

fragment float4 fx_env_dust(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];

    float3 c = spectra_tex(src, in.uv).rgb;
    float aspect = fx_env_aspect(u);

    float motes = 0.0;
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float scale = mix(9.0, 20.0, fl / 2.0);
        float depth = 1.0 - fl / 3.0;

        // Slow, meandering drift in two axes.
        float2 wob = float2(sin(u.time * (0.3 + fl * 0.13) + fl) ,
                            cos(u.time * (0.21 + fl * 0.11) + fl * 1.7)) * 0.18;
        float2 p = float2(in.uv.x * aspect, in.uv.y) * scale;
        p += wob * scale * 0.15 + u.time * speed * 0.06 * float2(0.3, -0.5);
        p += fl * 23.0 + u.seed * 9.0;

        float2 cellID = floor(p);
        float2 f = fract(p);
        float2 jitter = spectra_hash22(cellID + fl * 5.0);
        float spawn = step(0.78 - clamp(intensity, 0.0, 1.0) * 0.5,
                           spectra_hash21(cellID + fl * 11.0));
        float d = length(f - jitter);
        // Twinkle so motes glint as they drift.
        float twinkle = 0.5 + 0.5 * sin(u.time * 2.0 + spectra_hash21(cellID) * 6.28);
        motes += smoothstep(0.12 * depth, 0.0, d) * spawn * depth * twinkle;
    }

    float3 processed = c + clamp(motes, 0.0, 1.0) * clamp(intensity, 0.0, 1.0) * float3(1.0, 0.95, 0.8);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Bubbles (density, size, speed, opacity): rising glass-bubble bokeh

// The Frutiger Aero signature, rebuilt as real glass spheres. Each rises with a
// gentle sway and carries: a faint refraction lens that bends the desktop behind
// it, a bright Fresnel rim, thin-film (soap) iridescence cycling around the rim,
// and a primary + secondary specular glint. Every layer samples its FULL 3x3 cell
// neighbourhood, so a bubble straddling a cell border is drawn whole instead of
// being clipped at the seam (the "badly cropped" artifact of the old version).
fragment float4 fx_env_bubbles(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float density = clamp(u.params[0], 0.0, 1.0);
    float size = clamp(u.params[1], 0.0, 1.0);
    float speed = clamp(u.params[2], 0.0, 1.0);
    float opacity = clamp(u.params[3], 0.0, 1.0);
    bool popOn  = u.params[4] > 0.5;
    bool foamOn = u.params[5] > 0.5;
    float aspect = fx_env_aspect(u);

    float3 glow = float3(0.0);
    float2 refr = float2(0.0);   // accumulated refraction offset, in UV space
    const float kTwoPi = 6.28318530718;
    float tempo = 0.6 + speed;                       // per-bubble weave/bob tempo scales with Speed
    float2 uvA = float2(in.uv.x * aspect, in.uv.y);  // aspect-square space, hoisted out of the loops
    float spawnGate = 0.80 - density * 0.55;         // loop-invariant spawn threshold

    // Three depth layers: near bubbles are larger, faster, sharper; far ones smaller and
    // softened into bokeh. A separate fine foam layer is added after the loops.
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float scale = mix(5.0, 11.0, fl / 2.0);
        float depth = 1.0 - fl / 3.0;            // 1 near .. ~0.33 far
        float dof = 1.0 - depth;                 // 0 near .. ~0.67 far: how much to soften
        float baseRadius = mix(0.18, 0.42, size) * depth;  // per-bubble size scales off this

        // The stream rises as a whole (uv.y points down, so add time to drift up); each
        // bubble adds its own weave/bob below.
        float2 p = uvA * scale;
        p.y += u.time * speed * (0.18 + depth * 0.32) + fl * 17.0 + u.seed * 11.0;

        float2 baseCell = floor(p);
        float2 f = fract(p);

        // Visit this cell and its 8 neighbours so border-straddling bubbles draw whole.
        for (int oy = -1; oy <= 1; oy++) {
            for (int ox = -1; ox <= 1; ox++) {
                float2 cellOff = float2(float(ox), float(oy));
                float2 cellID = baseCell + cellOff;
                // Sparse spawn: only a subset of cells carry a bubble.
                if (spectra_hash21(cellID + fl * 13.0) < spawnGate) { continue; }

                // Per-bubble traits in 3 hash lookups: position, (size,path), (texture,pop).
                float2 jitter = spectra_hash22(cellID + fl * 6.0);
                float2 r1 = spectra_hash22(cellID + fl * 31.0);
                float2 r2 = spectra_hash22(cellID + fl * 59.0);
                float hSize = r1.x, hPath = r1.y, hTex = r2.x, hPop = r2.y;

                // Per-bubble path: a wide horizontal weave plus a slower vertical bob, each at
                // its own rate/phase. Bounded so the bubble stays in its 3x3 footprint, and the
                // bob momentarily speeds up / slows the rise so no two move alike.
                float wob = sin(u.time * (0.5 + hPath * 1.3) * tempo + hPath * kTwoPi);
                float bob = cos(u.time * (0.4 + hTex  * 0.8) * tempo + hTex  * kTwoPi);
                jitter += float2(wob * 0.22, bob * 0.10);

                // Pop: ~40% of bubbles rupture on a slow personal clock. The clock only sets WHEN;
                // the burst itself runs in real seconds so it always lasts < 100ms, whatever the
                // clock rate. The rest just rise. A birth fade-in keeps a re-spawn from blinking.
                float alpha = 1.0;       // body visibility
                float pp = 0.0;          // 0..1 progress through the ~90ms burst
                if (popOn && hPop > 0.60) {
                    float lifeRate = 0.05 + hTex * 0.04;
                    float life = fract(u.time * lifeRate + hPop * 9.0);
                    float popWin = lifeRate * 0.09;                     // 0.09s slice of the cycle => < 100ms
                    pp = clamp((life - (1.0 - popWin)) / popWin, 0.0, 1.0);
                    alpha = smoothstep(0.0, 0.05, life)                 // gentle ~1s birth fade-in
                          * (1.0 - smoothstep(0.0, 0.30, pp));         // body torn away ~27ms into the burst
                }

                // Per-bubble size: ~0.6x .. 1.35x the layer radius, with a quick pre-rupture swell.
                float radius = baseRadius * mix(0.60, 1.35, hSize) * (1.0 + smoothstep(0.0, 0.25, pp) * 0.15);

                float2 q = (f - cellOff) - jitter;       // vector from bubble centre, cell units
                float d2 = dot(q, q);                     // squared distance: cheaper cull, no sqrt yet
                float rMax = radius * (1.10 + dof * 0.12 + pp);   // extra room for the expanding rupture ring
                if (d2 > rMax * rMax) { continue; }       // skip the sqrt + shading for the far majority
                float nd = sqrt(d2) / max(radius, 1.0e-4);   // 0 centre .. 1 rim

                // Depth-of-field: far bubbles get a softer edge and a broader, dimmer rim/glint.
                float edgeSoft = 0.04 + dof * 0.14;
                float disc = 1.0 - smoothstep(0.94 - edgeSoft, 1.04 + edgeSoft, nd);  // soft AA edge
                float rim = smoothstep(mix(0.55, 0.40, dof), 0.97, nd) * disc;        // Fresnel rim
                float body = disc * 0.09;                                             // faint glass interior

                // Primary glint wanders off the upper-left default; broadens with depth (bokeh).
                float2 gdir = float2(0.30, 0.30) + (float2(hPath, hTex) - 0.5) * 0.34;
                float specW = mix(0.30, 0.52, dof);
                float spec1 = smoothstep(radius * specW, 0.0, length(q + gdir * radius));
                float spec2 = smoothstep(radius * specW * 0.55, 0.0, length(q - float2(0.34, 0.28) * radius));

                // Aero sparkle: a thin 4-point star on the main glint, only on the sharp near bubbles.
                float2 g = (q + gdir * radius) / max(radius, 1.0e-4);
                float starH = smoothstep(0.55, 0.0, abs(g.y)) * smoothstep(0.95, 0.0, abs(g.x));
                float starV = smoothstep(0.55, 0.0, abs(g.x)) * smoothstep(0.95, 0.0, abs(g.y));
                float star = (starH + starV) * spec1 * depth * depth;

                // Thin-film iridescence: ring frequency, phase and strength all vary per bubble,
                // so some read as clear glass and others as oily soap film.
                float iridAmt = mix(0.15, 0.85, hTex);
                float3 irid = 0.5 + 0.5 * cos(kTwoPi * (nd * mix(1.0, 2.6, hPath) + hTex)
                                              + float3(0.0, 2.094, 4.188));
                float3 glass  = mix(float3(0.45, 0.85, 0.95), float3(0.52, 0.95, 0.78), hSize); // aqua..green
                float3 rimCol = mix(float3(0.80, 0.95, 1.00), irid, iridAmt);

                float3 contrib = body * glass
                               + rim * mix(0.40, 0.72, hPath) * rimCol
                               + spec1 * 0.95 * float3(1.0)
                               + spec2 * 0.45 * float3(0.90, 0.97, 1.0)
                               + star * 0.60 * float3(1.0);
                glow += depth * alpha * contrib;

                // Rupture ring: a thin aqua/iridescent shell that races outward past the rim and
                // fades within the burst. Tinted (not white) and additive, so it outlives the body.
                if (pp > 0.0) {
                    float ringR = 1.0 + pp * 0.7;                  // travels from rim outward
                    float e = (nd - ringR) * 10.0;
                    float ring = exp(-e * e) * sin(pp * 3.14159);  // thin shell, brightens then fades
                    float3 ringCol = mix(glass, rimCol, 0.5);      // aqua-green, lightly iridescent
                    glow += depth * ring * 0.55 * ringCol;
                }

                // Refraction: a convex lens pulls the background toward the bubble centre,
                // strongest near the rim. Convert q from cell units back to UV.
                float refrAmt = smoothstep(0.20, 1.0, nd) * disc * depth * alpha;
                float2 qUV = float2(q.x / (aspect * scale), q.y / scale);
                refr -= qUV * refrAmt * 0.18;
            }
        }
    }

    // Foam: a fine, fast layer of tiny specks for froth / cluster detail. Single-cell lookup
    // (no 3x3 neighbourhood) — at this size any edge clipping is invisible, so it stays cheap.
    if (foamOn) {
        float2 fp = uvA * 26.0;
        fp.y += u.time * speed * 0.85 + u.seed * 7.0;
        float2 fc = floor(fp);
        if (spectra_hash21(fc + 3.0) > 0.92 - density * 0.10) {
            float2 fj = spectra_hash22(fc) - 0.5;
            float fd = length(fract(fp) - 0.5 - fj * 0.7);
            float spk = smoothstep(0.17, 0.0, fd);
            glow += spk * 0.28 * float3(0.85, 0.96, 1.0);
        }
    }

    float3 c = spectra_tex(src, in.uv + refr).rgb;       // desktop, refracted through the glass
    glow = clamp(glow, 0.0, 1.5) * opacity;
    float3 processed = 1.0 - (1.0 - c) * (1.0 - clamp(glow, 0.0, 1.0));   // screen the glossy light
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Underwater (intensity, speed): caustic warble + blue tint

fragment float4 fx_env_underwater(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];
    float t = u.time * speed;

    // Wobbling UV displacement, like looking through moving water.
    float2 w;
    w.x = sin(in.uv.y * 18.0 + t * 1.3) + sin(in.uv.y * 31.0 - t * 0.7);
    w.y = cos(in.uv.x * 22.0 - t * 1.1) + cos(in.uv.x * 14.0 + t * 0.9);
    float2 uv = in.uv + w * u.texelSize * (8.0 * clamp(intensity, 0.0, 1.0));
    float3 c = spectra_tex(src, uv).rgb;

    // Caustic light bands from layered cellular noise.
    float2 cp = in.uv * 6.0 + float2(t * 0.25, t * 0.18) + u.seed * 4.0;
    float ca = spectra_cellular(cp).x;
    float cb = spectra_cellular(cp * 1.7 - t * 0.2).x;
    float caustic = pow(1.0 - min(ca, cb), 4.0);

    float3 tint = float3(0.15, 0.45, 0.6);
    float3 processed = mix(c, c * (1.0 - 0.35 * intensity) + tint * 0.25 * intensity, clamp(intensity, 0.0, 1.0));
    processed += caustic * 0.5 * clamp(intensity, 0.0, 1.0) * float3(0.6, 0.85, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Heat Haze (intensity, speed): rising shimmer UV warp

fragment float4 fx_env_heatHaze(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float intensity = u.params[0];
    float speed = u.params[1];
    float t = u.time * speed;

    // Shimmer is stronger toward the bottom (hot ground) and rises upward.
    float rise = 1.0 - in.uv.y;
    float field = spectra_gradientNoise(float2(in.uv.x * 14.0, in.uv.y * 8.0 - t * 2.0) + u.seed * 6.0);
    field += spectra_gradientNoise(float2(in.uv.x * 27.0 + 5.0, in.uv.y * 16.0 - t * 3.3)) * 0.5;
    field = (field - 0.75);

    float warp = field * rise * clamp(intensity, 0.0, 1.0);
    float2 offset = float2(warp, warp * 0.4) * u.texelSize * 26.0;
    float3 processed = spectra_tex(src, in.uv + offset).rgb;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - God Rays (sun point, intensity, decay): radial light scattering

fragment float4 fx_env_godRays(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 sun = float2(u.params[0], u.params[1]);
    float intensity = u.params[2];
    float decay = u.params[3];

    float3 c = spectra_tex(src, in.uv).rgb;

    // March from the pixel toward the sun, accumulating bright luminance.
    // A per-pixel hash offsets the start position within [0,1) of one step so
    // all pixels don't sample the same discrete positions; this breaks the
    // structured banding that appears at low sample counts.
    const int SAMPLES = 32;
    float2 delta = (in.uv - sun) / float(SAMPLES);
    float jitter = spectra_hash21(in.uv * u.resolution + u.seed * 97.0);
    float2 coord = in.uv - delta * jitter;
    float illum = 1.0;
    float rays = 0.0;
    float dec = mix(1.0, 0.9, clamp(decay, 0.0, 1.0));
    for (int i = 0; i < SAMPLES; i++) {
        coord -= delta;
        float3 s = spectra_tex(src, coord).rgb;
        float bright = smoothstep(0.6, 1.0, spectra_luma(s));
        rays += bright * illum;
        illum *= dec;
    }
    rays /= float(SAMPLES);

    // Falls off with distance from the sun so the source stays brightest.
    float fall = 1.0 - smoothstep(0.0, 1.3, distance(in.uv, sun));
    float3 rayColor = float3(1.0, 0.92, 0.7);
    float3 processed = c + rays * fall * clamp(intensity, 0.0, 1.0) * 2.0 * rayColor;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Sun Glare (sun point, intensity): bright bloom at the sun

fragment float4 fx_env_sunGlare(RasterizerData in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> orig [[texture(1)]],
                                constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 sun = float2(u.params[0], u.params[1]);
    float intensity = u.params[2];

    float3 c = spectra_tex(src, in.uv).rgb;
    float aspect = fx_env_aspect(u);

    float2 d = (in.uv - sun);
    d.x *= aspect;
    float r = length(d);

    // Soft circular bloom core plus a tight hot center.
    float bloom = exp(-r * r * 14.0);
    float core = exp(-r * r * 120.0);

    // Anamorphic-style starburst streaks.
    float ang = atan2(d.y, d.x);
    float burst = pow(abs(cos(ang * 3.0)), 8.0) * exp(-r * 5.0);

    float glare = (bloom * 0.8 + core + burst * 0.5) * clamp(intensity, 0.0, 1.0);
    float3 glareColor = float3(1.0, 0.96, 0.85);
    float3 processed = c + glare * glareColor;
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Lens Flare (sun point, intensity): ghosts + halo along sun axis

inline float fx_env_ghost(float2 uv, float2 pos, float aspect, float size) {
    float2 d = uv - pos;
    d.x *= aspect;
    float r = length(d);
    return smoothstep(size, 0.0, r);
}

fragment float4 fx_env_lensFlare(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> orig [[texture(1)]],
                                 constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float2 sun = float2(u.params[0], u.params[1]);
    float intensity = u.params[2];

    float3 c = spectra_tex(src, in.uv).rgb;
    float aspect = fx_env_aspect(u);
    float2 center = float2(0.5, 0.5);

    // Axis from sun through screen center; ghosts repeat along it.
    float2 axis = center - sun;

    float3 flare = float3(0.0);
    // Chromatic ghosts at fractional positions along the axis.
    const int GHOSTS = 6;
    for (int i = 0; i < GHOSTS; i++) {
        float fi = float(i);
        float tpos = (fi + 1.0) * 0.32;
        float2 gpos = sun + axis * tpos;
        float size = mix(0.02, 0.09, fract(fi * 0.37 + 0.2));
        float g = fx_env_ghost(in.uv, gpos, aspect, size);
        // Slight per-ghost color tint for chromatic feel.
        float3 tint = 0.5 + 0.5 * cos(fi * 1.3 + float3(0.0, 2.0, 4.0));
        flare += g * tint * (0.4 + 0.3 * fract(fi * 0.61));
    }

    // Soft halo ring centered on screen.
    float2 hd = in.uv - center;
    hd.x *= aspect;
    float hr = length(hd);
    float halo = smoothstep(0.06, 0.0, abs(hr - 0.32)) * 0.6;
    flare += halo * float3(0.7, 0.8, 1.0);

    // Bright anchor at the sun.
    flare += fx_env_ghost(in.uv, sun, aspect, 0.05) * float3(1.0, 0.95, 0.8);

    float3 processed = c + flare * clamp(intensity, 0.0, 1.0);
    return spectra_compositeRGBA(base, processed, u);
}

// MARK: - Cloud Overlay (coverage, speed): fbm cloud shadows/overlay

fragment float4 fx_env_clouds(RasterizerData in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> orig [[texture(1)]],
                              constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float coverage = u.params[0];
    float speed = u.params[1];

    float3 c = spectra_tex(src, in.uv).rgb;
    float aspect = fx_env_aspect(u);

    // Two drifting noise layers for parallax body.
    float2 p = float2(in.uv.x * aspect, in.uv.y) * 2.5;
    float2 drift = float2(u.time * speed * 0.03, u.time * speed * 0.008);
    float n1 = fx_env_fbm(p + drift + u.seed * 5.0, 6);
    float n2 = fx_env_fbm(p * 1.9 - drift * 1.4 + 31.0, 4);
    float cloud = n1 * 0.7 + n2 * 0.3;

    // Coverage drives the threshold: more coverage -> denser clouds.
    float lo = mix(0.7, 0.15, clamp(coverage, 0.0, 1.0));
    float mask = smoothstep(lo, lo + 0.35, cloud);

    // Bright cloud bodies, with darker shadow cores beneath them.
    float3 cloudColor = float3(0.92, 0.93, 0.96);
    float shadow = smoothstep(lo + 0.05, lo - 0.2, cloud) * 0.4;
    float3 processed = c * (1.0 - shadow);
    processed = mix(processed, cloudColor, mask * 0.75);
    return spectra_compositeRGBA(base, processed, u);
}
