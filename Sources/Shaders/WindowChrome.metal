// WindowChrome.metal — per-window screen-space chrome (MAOE §12)
//
// These effects read the live window-geometry buffer (`WindowGeometry`, bound at buffer
// index 2 when the pass declares `requiresWindowRects`) and paint borders / glows that hug
// each window's rounded rect. Two invariants from the spec:
//
//   • Computed from the LIVE list every frame — never cached. A window absent from the
//     current list contributes no chrome, so a border can't outlive its window (no ghost
//     borders, §5.4).
//   • Opacity-gated by kCGWindowAlpha (meta.x). A closing window fades, and its chrome
//     fades with it, so the close-fade "follows" for free.
//
// All coordinates are display-local top-left UV, matching `in.uv`.

#include "SpectraCommon.h"

// True if `uv` is covered by any window IN FRONT of window `i`. The geometry list is front-to-back
// (index 0 = frontmost), so a higher window has a smaller index. Used so a window's chrome (border,
// ornament) doesn't draw where a window stacked on top of it overlaps — stacked windows don't stack
// effects; the front window occludes the one behind.
inline bool spectra_chromeOccluded(float2 uv, constant WindowGeometry &geo, int i, float aspect) {
    for (int j = 0; j < i; j++) {
        SpectraWindow wj = geo.windows[j];
        if (wj.meta.x <= 0.001) continue;
        if (spectra_windowSDF(uv, wj.rect, wj.meta.z, aspect) < 0.0) return true;
    }
    return false;
}

// Cyberpunk circuit trace along one edge: irregular, random-position / random-length lit runs (NOT a
// uniform comb) that shimmer smoothly at a controlled, frame-rate-independent speed. `along` is the
// edge-parallel coordinate (0 at one end of the edge), `outer`/`inner` the two trace-rule masks,
// `seed` decorrelates one window from another (0 for the screen frame). Returns the additive neon.
inline float3 spectra_cyberCircuit(float along, float outer, float inner, float seed, float time) {
    float cells = 22.0;
    float ci = floor(along * cells);
    float cf = fract(along * cells);
    float dead = step(0.72, spectra_hash11(ci * 5.3 + seed + 2.0));                 // ~28% fully-dead gaps
    float center = 0.16 + 0.68 * spectra_hash11(ci * 1.7 + seed);                   // random trace position in the cell
    float halfLen = 0.10 + 0.30 * spectra_hash11(ci * 3.1 + seed + 4.0);            // random trace length
    float lit = (1.0 - dead) * (1.0 - smoothstep(halfLen * 0.75, halfLen, abs(cf - center)));
    float bright = 0.35 + 0.55 * spectra_hash11(ci * 2.9 + seed + 6.0);
    float phase = spectra_hash11(ci * 4.7 + seed + 9.0);
    float flick = 0.55 + 0.45 * sin(time * 3.5 + phase * 6.2831);                   // smooth ~0.55 Hz shimmer per trace
    float hsel = spectra_hash11(ci * 2.3 + seed + 1.0);
    float3 pal = (hsel < 0.34) ? float3(0.55, 0.18, 0.95)      // purple
               : (hsel < 0.67) ? float3(0.95, 0.25, 0.70)      // pink
                               : float3(0.25, 0.45, 1.00);     // blue
    float trace = (outer + inner * 0.5) * lit * bright * flick;
    return pal * trace * 0.85;
}

// Per-window frame, tailored per world (MAOE §12, redesigned). Not a uniform glow: each style
// draws a real frame on the window's inner edge so it reads as window chrome.
//   style 0 glow     soft coloured halo (legacy)
//   style 1 inset    hard thin line just inside the edge + a dim outer line (Cyberpunk neon)
//   style 2 bevel    directional light/shadow on the edges (Golden Hour)
//   style 3 glass    glossy beveled rim, bright top highlight (Frutiger)
//   style 4 film     white double-line caption frame with sprocket notches (Noir)
//   style 5 pixel    dashed / segmented border (Matrix)
// params: 0 style, 1..4 color(rgba), 5 width (UV-Y), 6 softness, 7 activeOnly (0/1)
fragment float4 fx_chrome_windowBorder(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]],
                                       constant WindowGeometry &geo [[buffer(2)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    int style = int(u.params[0] + 0.5);
    float3 col = float3(u.params[1], u.params[2], u.params[3]);
    float colA = u.params[4];
    float width = max(u.params[5], 1.0e-4);
    float softness = u.params[6];
    float activeOnly = u.params[7];
    float screenFrame = u.params[8];
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);

    float3 outc = base;
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        float alpha = w.meta.x;
        if (alpha <= 0.001) continue;
        if (activeOnly > 0.5 && w.meta.y < 0.5) continue;
        if (spectra_chromeOccluded(in.uv, geo, i, aspect)) continue;     // a front window covers this one's chrome here
        // Only the circuit styles (Matrix 5 / Cyberpunk 6) skip a screen-spanning window — so the
        // neon border never frames the whole screen (Cyberpunk uses `screenFrame` for that instead).
        // Other styles (e.g. Frutiger's glass reflection) MUST still draw on a maximised window.
        if ((style == 5 || style == 6) && w.rect.z > 0.92 && w.rect.w > 0.85) continue;

        float d = spectra_windowSDF(in.uv, w.rect, w.meta.z, aspect);   // <0 inside, 0 at edge
        // Edge geometry: which edge is nearest, and is it the TOP edge (for directional styles).
        float2 hf = w.rect.zw * 0.5;
        float2 rel = in.uv - (w.rect.xy + hf);
        float2 toEdge = hf - abs(rel);                                  // smaller = nearer that edge
        bool vertical = toEdge.x < toEdge.y;                            // nearer a left/right edge
        bool topEdge = (!vertical) && rel.y < 0.0;
        bool leftEdge = vertical && rel.x < 0.0;
        // Per-window seed so the broken-circuit pattern (styles 5/6) differs window to window
        // instead of every frame being identically segmented.
        float wseed = floor(w.rect.x * 137.0 + w.rect.y * 911.0);

        if (style == 1) {
            // Inset: a single crisp hard line just inside the edge — discrete, no glow/blur. The
            // line MIXES toward the colour (not additive), so a dark colour reads as a real dark
            // rule on the window edge (Cyberpunk purple, Print indigo, Comic ink panel).
            float line = (1.0 - smoothstep(0.0, width, abs(d + width))) * step(d, 0.0) * alpha;
            outc = mix(outc, col, line * colA);
        } else if (style == 2) {
            // Bevel: subtle, natural directional edge shading — a faint warm light on the lit
            // edges (top/left) and a soft shadow on the others, so the window sits in the scene
            // instead of wearing a bright frame.
            float band = (1.0 - smoothstep(0.0, width * (1.0 + softness), abs(d))) * step(d, 0.0) * alpha;
            if (topEdge || leftEdge) outc += col * colA * band * 0.14;     // gentle light
            else outc *= (1.0 - 0.32 * band);                             // soft shadow
        } else if (style == 3) {
            // Frutiger glass: a thin EDGE rim plus a rounded glossy HEADER reflection confined to the
            // top of the window — deeper blue, maximalist gel. (The old code's rim term was inverted
            // and washed a bright triangle across the window interior; this stays on the header+edges
            // and never invades the window body.)
            float3 gel = float3(0.42, 0.66, 1.0);                                   // deeper blue gel
            float edge = smoothstep(width, 0.0, abs(d)) * step(d, 0.0) * alpha;     // bright AT the edge only
            outc = mix(outc, gel, edge * 0.22 * colA);
            float hh = w.rect.w * 0.16;                                             // header band height
            float yh = (in.uv.y - w.rect.y) / max(hh, 1.0e-4);                      // 0 top … 1 base of header
            if (d < 0.0 && yh >= 0.0 && yh <= 1.0) {
                float xf = (in.uv.x - w.rect.x) / max(w.rect.z, 1.0e-4);            // 0..1 across the window
                float xr = smoothstep(0.0, 0.14, xf) * smoothstep(1.0, 0.86, xf);  // round the gel-bar ends
                float gloss = (1.0 - yh) * (1.0 - yh) * xr;                         // concave top gloss
                float3 hi = mix(gel, float3(0.88, 0.96, 1.0), 0.55);
                outc = mix(outc, hi, gloss * 0.5 * alpha);
            }
        } else if (style == 4) {
            // Film strip: two thin white lines + periodic sprocket notches along the edge.
            float l1 = 1.0 - smoothstep(0.0, width * 0.4, abs(d + width * 0.6));
            float l2 = 1.0 - smoothstep(0.0, width * 0.4, abs(d + width * 2.2));
            float along = vertical ? in.uv.y : in.uv.x;
            float notch = step(0.55, fract(along * 60.0)) * (1.0 - smoothstep(0.0, width * 2.5, abs(d + width * 1.4)));
            float band = max(max(l1, l2), notch) * alpha;
            outc = mix(outc, col, band * colA);
        } else if (style == 5) {
            // Damaged-terminal circuit frame (Matrix): a dark recessed bezel carrying two layered,
            // hash-broken trace rules (an outer rule + a fainter inner trace) with corroded dead
            // runs and a few brighter solder-node pads — old, broken, heavily-modified hardware, not
            // a clean neon dash. Kept dim so it reads as worn phosphor, not RGB.
            float along = vertical ? in.uv.y : in.uv.x;
            // Recessed dark bezel the traces sit on.
            float bezel = (1.0 - smoothstep(0.0, width * 3.0, abs(d + width * 1.2))) * step(d, 0.0) * alpha;
            outc = mix(outc, outc * 0.22, bezel * 0.85);
            // Outer + inner trace rules at different insets (the layered look).
            float outer = (1.0 - smoothstep(0.0, width * 0.5, abs(d + width * 0.5))) * step(d, 0.0) * alpha;
            float inner = (1.0 - smoothstep(0.0, width * 0.5, abs(d + width * 2.1))) * step(d, 0.0) * alpha;
            float seg = floor(along * 56.0);                                                    // coarser → visible gaps
            float on = step(0.55, spectra_hash11(seg * 1.7 + wseed + (vertical ? 5.0 : 0.0)));  // ~45% on (bigger breaks)
            float corrode = step(0.80, spectra_hash11(seg * 5.3 + wseed + 2.0));                // more fully-dead runs
            float bright = 0.20 + 0.65 * spectra_hash11(seg * 3.1 + wseed);                     // wider brightness spread
            // Temporal flicker: each segment blinks on its own clock (worn phosphor / loose contact).
            float flick = 0.45 + 0.55 * step(0.42, spectra_hash11(seg * 2.1 + wseed + floor(u.time * 7.0)));
            float trace = (outer + inner * 0.5) * on * (1.0 - corrode) * bright * flick;
            float node = step(0.92, spectra_hash11(seg * 2.9 + wseed + 11.0)) * outer * flick;  // sparse solder pads
            outc += col * colA * (trace * 0.7 + node * 0.9);
        } else if (style == 6) {
            // Cyberpunk circuit frame: irregular neon traces at random positions along each edge,
            // shimmering smoothly (frame-rate independent). `cAlong` is window-relative so each
            // window's border is self-contained — no shared screen grid pattern across windows.
            float bezel = (1.0 - smoothstep(0.0, width * 3.0, abs(d + width * 1.2))) * step(d, 0.0) * alpha;
            outc = mix(outc, outc * 0.20, bezel * 0.85);
            float outer = (1.0 - smoothstep(0.0, width * 0.5, abs(d + width * 0.5))) * step(d, 0.0) * alpha;
            float inner = (1.0 - smoothstep(0.0, width * 0.5, abs(d + width * 2.1))) * step(d, 0.0) * alpha;
            float cAlong = vertical ? (in.uv.y - w.rect.y) / max(w.rect.w, 1.0e-4)
                                    : (in.uv.x - w.rect.x) / max(w.rect.z, 1.0e-4);
            outc += spectra_cyberCircuit(cAlong, outer, inner, wseed, u.time);
        } else {
            // Glow (legacy soft halo).
            float band = (1.0 - smoothstep(0.0, width * (1.0 + softness), abs(d))) * alpha;
            outc += col * colA * band;
        }
    }

    // Optional whole-display frame (Cyberpunk): the circuit border wrapping the screen edges,
    // always on regardless of windows. Uses the style-6 RGB-circuit pattern.
    if (screenFrame > 0.5) {
        float dEdgeY = min(in.uv.y, 1.0 - in.uv.y);
        float dEdgeX = min(in.uv.x, 1.0 - in.uv.x) * aspect;
        bool sv = dEdgeX < dEdgeY;
        float d = -min(dEdgeX, dEdgeY);                                   // <0 inside, 0 at the screen edge
        float along = sv ? in.uv.y : in.uv.x * aspect;
        float bezel = (1.0 - smoothstep(0.0, width * 3.0, abs(d + width * 1.2))) * step(d, 0.0);
        outc = mix(outc, outc * 0.20, bezel * 0.85);
        float outer = (1.0 - smoothstep(0.0, width * 0.5, abs(d + width * 0.5))) * step(d, 0.0);
        float inner = (1.0 - smoothstep(0.0, width * 0.5, abs(d + width * 2.1))) * step(d, 0.0);
        outc += spectra_cyberCircuit(along, outer, inner, 0.0, u.time);
    }
    return spectra_compositeRGBA(base, outc, u);
}

// Ornate SPRITE window frame (Noir art-nouveau): real corner artwork, not a procedural glow. A
// bundled corner flourish (texture 11, premultiplied) is placed into each window's four corners,
// mirrored from the single top-left source. The sprite is a BLACK/WHITE double outline, composited
// by its own colour so it reads on light and dark backgrounds; `ink` (params 2..5) is no longer used
// for the corners. The whole-screen frame (corners + a black/white double edge rule) sits BEHIND
// normal windows but is shown in full around a full-screen window (as on an empty desktop). The old
// per-window edge rule was removed.
// params: 0 cornerSize(UV-Y), 1 ruleWidth(UV-Y), 2..5 ink(unused), 6 intensity
fragment float4 fx_chrome_spriteBorder(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]],
                                       texture2d<float> corner [[texture(11)]],
                                       constant WindowGeometry &geo [[buffer(2)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float cs  = max(u.params[0], 1e-4);
    float rw  = max(u.params[1], 1e-5);
    float3 ink = float3(u.params[2], u.params[3], u.params[4]);   // slot 5 is the colour alpha
    float k = clamp(u.params[6], 0.0, 1.0);
    float menuBarH = max(u.params[7], 0.0);   // renderer-injected menu-bar height (UV) — the screen frame clears it
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float rwx = rw / aspect;           // vertical-rule half-width in UV-X (same px as rw in UV-Y)
    constexpr sampler smp(address::clamp_to_edge, filter::linear);
    float3 outc = base;
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        float alpha = w.meta.x;
        if (alpha <= 0.001) continue;
        // A maximised window's corners land exactly on the screen-wide frame's corners below, so its
        // per-window flourishes would stack on (double) those ornate sprites — let the screen frame own them.
        if (w.rect.z > 0.92 && w.rect.w > 0.85) continue;
        if (spectra_chromeOccluded(in.uv, geo, i, aspect)) continue;     // a front window covers this frame here (overlap detection + frontmost favouring)
        float2 lo = w.rect.xy, hi = w.rect.xy + w.rect.zw;
        // Scale the corner flourish with the window size: a big / maximised window gets a large
        // silent-film-title-card frame, small windows a modest one.
        float wsz = min(w.rect.z * aspect, w.rect.w);
        float csW = cs * clamp(wsz / 0.55, 0.6, 2.4);
        float csxW = csW / aspect;
        if (in.uv.x < lo.x - rwx || in.uv.x > hi.x + rwx ||
            in.uv.y < lo.y - rw  || in.uv.y > hi.y + rw) continue;

        // Corner flourishes only — the smooth rounded edge rule that used to ring each window was
        // removed (it read as a plain white border). The single top-left art is mirrored into the
        // four corners via UV flips; composite its own premultiplied colour so the black/white
        // double-outline ornament stays legible on light and dark windows alike.
        float4 spr = float4(0.0);
        if (in.uv.x <= lo.x + csxW && in.uv.y <= lo.y + csW)                   // TL
            spr = corner.sample(smp, float2((in.uv.x - lo.x) / csxW, (in.uv.y - lo.y) / csW));
        else if (in.uv.x >= hi.x - csxW && in.uv.y <= lo.y + csW)              // TR (flip x)
            spr = corner.sample(smp, float2((hi.x - in.uv.x) / csxW, (in.uv.y - lo.y) / csW));
        else if (in.uv.x <= lo.x + csxW && in.uv.y >= hi.y - csW)              // BL (flip y)
            spr = corner.sample(smp, float2((in.uv.x - lo.x) / csxW, (hi.y - in.uv.y) / csW));
        else if (in.uv.x >= hi.x - csxW && in.uv.y >= hi.y - csW)              // BR (flip both)
            spr = corner.sample(smp, float2((hi.x - in.uv.x) / csxW, (hi.y - in.uv.y) / csW));
        float g = alpha * k;
        outc = outc * (1.0 - spr.a * g) + spr.rgb * g;        // premultiplied "over"
    }

    // Screen-wide ornate frame: the corner art mirrored into the four corners of the WHOLE display
    // (a big silent-film title-card border around everything, present even with no windows open).
    {
        // The screen-wide frame sits BEHIND normal windows: if one covers this pixel, let its
        // content occlude the border (vis gates both writes). A FULL-SCREEN window is excluded from
        // that test, so the wallpaper border shows around it exactly as it would on an empty desktop.
        bool covered = false;
        for (int j = 0; j < n; j++) {
            SpectraWindow wj = geo.windows[j];
            if (wj.meta.x <= 0.001) continue;
            if (wj.rect.z > 0.92 && wj.rect.w > 0.85) continue;   // full-screen: show the wallpaper border as if empty
            if (spectra_windowSDF(in.uv, wj.rect, wj.meta.z, aspect) < 0.0) { covered = true; break; }
        }
        float vis = covered ? 0.0 : 1.0;
        // Keep the menu bar readable: inside the top menu-bar strip, let only the bright TEXT (the
        // clock and menu titles) punch through the ornament. The rest of the bar keeps the border —
        // the menu-bar background is dark, the glyphs are bright, so a luma gate isolates the text.
        float inMenuBar = 1.0 - smoothstep(menuBarH - 0.001, menuBarH + 0.001, in.uv.y);
        float textPunch = smoothstep(0.55, 0.78, spectra_lumaRec601(base));
        vis *= 1.0 - inMenuBar * textPunch;
        float scs = max(cs * 2.0, 0.14);            // large screen-corner flourish
        float scsx = scs / aspect;
        float4 ssp = float4(0.0);
        if (in.uv.x <= scsx       && in.uv.y <= scs)        ssp = corner.sample(smp, float2(in.uv.x / scsx, in.uv.y / scs));
        else if (in.uv.x >= 1.0 - scsx && in.uv.y <= scs)        ssp = corner.sample(smp, float2((1.0 - in.uv.x) / scsx, in.uv.y / scs));
        else if (in.uv.x <= scsx       && in.uv.y >= 1.0 - scs)  ssp = corner.sample(smp, float2(in.uv.x / scsx, (1.0 - in.uv.y) / scs));
        else if (in.uv.x >= 1.0 - scsx && in.uv.y >= 1.0 - scs)  ssp = corner.sample(smp, float2((1.0 - in.uv.x) / scsx, (1.0 - in.uv.y) / scs));
        float sg = k * vis;
        outc = outc * (1.0 - ssp.a * sg) + ssp.rgb * sg;        // premultiplied "over"
        // Black/white DOUBLE rule along the screen edges: a white core flanked by black so the frame
        // reads on both light and dark desktops (no single ink that vanishes on a matching wall).
        float dh = min(in.uv.y, 1.0 - in.uv.y);
        float dv = min(in.uv.x, 1.0 - in.uv.x) * aspect;
        float dEsN = min(dh, dv) / rw;                          // distance to the nearest screen edge, in rule-widths
        float blackR = 1.0 - smoothstep(2.2, 2.7, dEsN);        // black band out to ~2.7 widths
        float whiteR = 1.0 - smoothstep(0.5, 0.9, abs(dEsN - 1.1));  // white core centred ~1.1 widths in
        outc = mix(outc, float3(0.0), clamp(blackR, 0.0, 1.0) * k * vis);
        outc = mix(outc, float3(1.0), clamp(whiteR, 0.0, 1.0) * k * vis);
    }
    return spectra_compositeRGBA(base, outc, u);
}

// Per-world MENU-BAR treatment, painted directly onto the shaded top strip (MAOE §9, in-shader
// — no separate overlay window). `heightUV` is the menu-bar height from the top of the screen.
//   style 1 softShadow  Golden Hour: a soft directional shadow under the bar
//   style 2 caption     Noir silent film: warm-dark, scrolling scratches, grain, projector flicker
//   style 3 reflective  Frutiger: glossy top-weighted highlight
//   style 4 pastel      Fuji: a soft pastel wash
// params: 0 style, 1 heightUV, 2 intensity
fragment float4 fx_chrome_menuBar(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float h = max(u.params[1], 1e-4);
    int style = int(u.params[0] + 0.5);
    float k = clamp(u.params[2], 0.0, 1.0);
    // Soft shadow extends a little BELOW the bar; the others act inside the bar only.
    if (in.uv.y > h + 0.02) return float4(base, 1.0);
    float inBar = step(in.uv.y, h);
    float yIn = clamp(in.uv.y / h, 0.0, 1.0);
    float3 outc = base;

    if (style == 1) {
        // Golden Hour: a soft shadow gradient just under the bar's bottom edge.
        float below = smoothstep(h + 0.02, h, in.uv.y) * step(h, in.uv.y);
        outc = base * (1.0 - 0.35 * below * k);
    } else if (style == 2) {
        // Noir silent film. Warm-dark tone + projector flicker.
        float flick = 0.85 + 0.15 * sin(u.time * 31.0) + 0.05 * sin(u.time * 12.3);
        float3 toned = mix(base, float3(spectra_lumaRec601(base)) * float3(1.05, 0.98, 0.86), 0.85);
        outc = toned * (0.45 + 0.2 * flick);
        // Scrolling vertical scratches: a few columns that blink and drift.
        float col = floor(in.uv.x * 90.0);
        float life = spectra_hash11(col + floor(u.time * 6.0));
        float scratch = step(0.92, life) * (0.5 + 0.5 * sin(in.uv.y * 30.0));
        outc += scratch * 0.5;
        // Dust + grain.
        float grain = spectra_hash21(in.uv * u.resolution.xy * 0.5 + u.time * 60.0) - 0.5;
        outc += grain * 0.12;
        // A bright bottom caption rule.
        outc += smoothstep(0.0, 0.06, abs(in.uv.y - h)) < 0.5 ? 0.0 : 0.0;
        outc = mix(base, outc, inBar);
    } else if (style == 3) {
        // Frutiger reflective: a glossy gradient brightest at the top of the bar.
        float gloss = (1.0 - yIn) * (1.0 - yIn);
        outc = mix(base, base * 1.15 + float3(0.05, 0.12, 0.18) * gloss, inBar * k);
    } else if (style == 4) {
        // Fuji pastel wash.
        outc = mix(base, base * 0.96 + float3(0.06, 0.03, 0.02), inBar * 0.5 * k);
    }
    return spectra_compositeRGBA(base, outc, u);
}

// Per-world DOCK treatment painted onto the shaded Dock region (MAOE §9, in-shader). The Dock
// rect (UV) is supplied as a param; nil/zero size no-ops.
//   style 1 grounded   soft ambient shadow under the Dock
//   style 2 stageFrame a bright boundary frame around the Dock
//   style 3 neon       a neon outline (Matrix / Cyberpunk)
//   style 4 pastel     a matte pastel wash
//   style 5 reflective a glossy gradient
// params: 0 style, 1..4 dockRect(x,y,w,h UV), 5 intensity, 6..8 colour
fragment float4 fx_chrome_dock(RasterizerData in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> orig [[texture(1)]],
                               constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float4 rect = float4(u.params[1], u.params[2], u.params[3], u.params[4]);
    if (rect.z <= 0.001 || rect.w <= 0.001) return float4(base, 1.0);
    int style = int(u.params[0] + 0.5);
    float k = clamp(u.params[5], 0.0, 1.0);
    float3 col = float3(u.params[6], u.params[7], u.params[8]);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float d = spectra_windowSDF(in.uv, rect, 0.02, aspect);   // <0 inside the Dock
    float3 outc = base;

    if (style == 1) {
        float shadow = smoothstep(0.03, 0.0, d) * step(0.0, d);   // just outside the Dock
        outc = base * (1.0 - 0.5 * shadow * k);
    } else if (style == 2) {
        float frame = (1.0 - smoothstep(0.0, 0.004, abs(d))) * k;
        outc = mix(base, float3(1.0), frame * 0.6);
    } else if (style == 3) {
        float outline = (1.0 - smoothstep(0.0, 0.005, abs(d))) * k;
        outc = base + col * outline * 1.4;
    } else if (style == 4) {
        float inside = step(d, 0.0);
        outc = mix(base, base * 0.96 + col * 0.1, inside * 0.5 * k);
    } else if (style == 5) {
        float inside = step(d, 0.0);
        float gloss = inside * (1.0 - smoothstep(rect.y, rect.y + rect.w, in.uv.y));
        outc = base + (col * 0.5 + 0.3) * gloss * k;
    }
    return spectra_compositeRGBA(base, outc, u);
}

// Geometry-aware generative rain (MAOE §15.2): falling streaks drawn ONLY in the window gaps
// (occluded behind windows, so it reads as rain on the wallpaper behind your windows), with a
// brighter splash band just above each window's top edge. Window-aware ambient content — the
// clearest "engine, not filter" move.
// params: 0..3 color, 4 density, 5 speed
fragment float4 fx_chrome_windowRain(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]],
                                     constant WindowGeometry &geo [[buffer(2)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);

    // Occlude inside any window (the rain is behind the windows); also find the nearest window
    // top edge directly above for the splash band.
    float splash = 0.0;
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        if (w.meta.x <= 0.001) continue;
        if (spectra_windowSDF(in.uv, w.rect, w.meta.z, aspect) < 0.0) return float4(base, 1.0);
        // Splash: just above a window's top edge, within its horizontal span.
        if (in.uv.x >= w.rect.x && in.uv.x <= w.rect.x + w.rect.z) {
            float dTop = w.rect.y - in.uv.y;                 // >0 = above the window top
            if (dTop > 0.0 && dTop < 0.01) splash = max(splash, (1.0 - dTop / 0.01) * w.meta.x);
        }
    }

    float cols = max(u.params[4], 1.0) * 60.0;
    float2 cell = float2(in.uv.x * cols, in.uv.y * cols / aspect - u.time * max(u.params[5], 0.1) * 9.0);
    float col = floor(cell.x);
    float active = step(0.45, spectra_hash11(col * 1.7));     // not every column rains
    float drop = smoothstep(0.85, 1.0, fract(cell.y)) * active;
    float3 color = float3(u.params[0], u.params[1], u.params[2]);
    float3 outc = base + color * (drop * 0.6 + splash * 1.2);
    return spectra_compositeRGBA(base, outc, u);
}

// Focus spotlight (MAOE §15.1): dim + desaturate everything except the frontmost (focused)
// window, so the OS composes around what you're doing. The focused window is meta.y == 1 from
// the geometry feed (front-most in z-order, a no-AX signal).
// params: 0 dim (0..1)
fragment float4 fx_chrome_focusDim(RasterizerData in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   texture2d<float> orig [[texture(1)]],
                                   constant SpectraUniforms &u [[buffer(0)]],
                                   constant WindowGeometry &geo [[buffer(2)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float dim = clamp(u.params[0], 0.0, 1.0);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float insideFocused = 0.0;
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        if (w.meta.x <= 0.001 || w.meta.y < 0.5) continue;   // only the focused window
        if (spectra_windowSDF(in.uv, w.rect, w.meta.z, aspect) < 0.0) insideFocused = w.meta.x;
    }
    float dimAmt = (1.0 - insideFocused) * dim;
    float3 desat = float3(spectra_luma(base));
    float3 dimmed = mix(base, desat, 0.5) * 0.55;
    return spectra_compositeRGBA(base, mix(base, dimmed, dimAmt), u);
}

// Filter the active window in/out of the effect (MAOE §16.3). Shows the ORIGINAL desktop
// (bound at texture 10 — the chain input when no history effect is present) either INSIDE the
// focused window (mode 0: "let me read this one thing clearly") or everywhere EXCEPT it
// (mode 1: restrict the effect to the focused window). No AX: the focused rect comes from the
// geometry feed's z-order focus flag.
// params: 0 mode (0 punch-out, 1 restrict)
fragment float4 fx_chrome_windowPunch(RasterizerData in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      texture2d<float> orig [[texture(1)]],
                                      constant SpectraUniforms &u [[buffer(0)]],
                                      texture2d<float> desktop [[texture(10)]],
                                      constant WindowGeometry &geo [[buffer(2)]]) {
    float3 processed = spectra_tex(src, in.uv).rgb;
    float3 raw = spectra_tex(desktop, in.uv).rgb;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float insideFocused = 0.0;
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        if (w.meta.x <= 0.001 || w.meta.y < 0.5) continue;
        if (spectra_windowSDF(in.uv, w.rect, w.meta.z, aspect) < 0.0) insideFocused = w.meta.x;
    }
    float showRaw = (u.params[0] < 0.5) ? insideFocused : (1.0 - insideFocused);
    return float4(mix(processed, raw, showRaw), 1.0);
}

// Directional drop shadow cast into the gap beside each window, from one light direction
// (so it agrees with the LightModel). Drawn only OUTSIDE the window and gated by alpha, so a
// closing window's shadow fades with it. NOTE: doubles the macOS native shadow — pair with
// `yabai -m config window_shadow off` (the descriptor is gated on yabai readiness, §12).
// params: 0 lightAngle°, 1 distance(UV), 2 softness(UV), 3 opacity
fragment float4 fx_chrome_windowShadow(RasterizerData in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       texture2d<float> orig [[texture(1)]],
                                       constant SpectraUniforms &u [[buffer(0)]],
                                       constant WindowGeometry &geo [[buffer(2)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float ang = u.params[0] * 3.14159265 / 180.0;
    float2 dir = float2(cos(ang), sin(ang));            // light travel direction (top-left UV)
    float dist = u.params[1], soft = max(u.params[2], 1e-4), op = u.params[3];
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float shadow = 0.0;
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        if (w.meta.x <= 0.001) continue;
        // Shadow = the window shifted along the light direction; keep only the part lying in
        // the gap (outside the real window).
        float dShadow = spectra_windowSDF(in.uv - dir * dist, w.rect, w.meta.z, aspect);
        float dReal = spectra_windowSDF(in.uv, w.rect, w.meta.z, aspect);
        float s = smoothstep(soft, 0.0, dShadow) * smoothstep(0.0, soft, dReal);
        shadow = max(shadow, s * w.meta.x);
    }
    return spectra_compositeRGBA(base, base * (1.0 - clamp(op * shadow, 0.0, 0.85)), u);
}

// Soft vignette hugging each window's INNER edge (paper / pencil look).
// params: 0..3 color, 4 strength, 5 size(UV)
fragment float4 fx_chrome_windowVignette(RasterizerData in [[stage_in]],
                                         texture2d<float> src [[texture(0)]],
                                         texture2d<float> orig [[texture(1)]],
                                         constant SpectraUniforms &u [[buffer(0)]],
                                         constant WindowGeometry &geo [[buffer(2)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float strength = u.params[4], size = max(u.params[5], 1e-4);
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float vig = 0.0;
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        if (w.meta.x <= 0.001) continue;
        float d = spectra_windowSDF(in.uv, w.rect, w.meta.z, aspect);   // negative inside
        if (d >= 0.0) continue;                                          // only inside the window
        float v = smoothstep(-size, 0.0, d);                            // 0 mid, 1 at the edge
        vig = max(vig, v * w.meta.x);
    }
    float3 tint = float3(u.params[0], u.params[1], u.params[2]) * u.params[3];
    float3 outc = mix(base, base * (1.0 - strength) + tint * strength, vig);
    return spectra_compositeRGBA(base, outc, u);
}

// Frutiger glossy header strip: a concave gloss over each window's top ~28 pt, derived from
// the rect (a heuristic title-bar top-strip, no element targeting). Best-effort: a hidden or
// non-standard title bar just gets a thin gloss.
// params: 0..3 gloss tint, 4 height(UV)
fragment float4 fx_chrome_titleStrip(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> orig [[texture(1)]],
                                     constant SpectraUniforms &u [[buffer(0)]],
                                     constant WindowGeometry &geo [[buffer(2)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    float stripH = max(u.params[4], 1e-4);
    float3 tint = float3(u.params[0], u.params[1], u.params[2]);
    float amount = u.params[3];
    float3 outc = base;
    int n = min(int(geo.count + 0.5), kSpectraMaxWindows);
    for (int i = 0; i < n; i++) {
        SpectraWindow w = geo.windows[i];
        if (w.meta.x <= 0.001) continue;
        float2 o = w.rect.xy, sz = w.rect.zw;
        if (in.uv.x < o.x || in.uv.x > o.x + sz.x) continue;
        float yIn = (in.uv.y - o.y) / stripH;
        if (yIn < 0.0 || yIn > 1.0) continue;
        // Concave gloss: bright band near the top, dipping toward the strip's base.
        float gloss = (1.0 - yIn) * (0.6 + 0.4 * (1.0 - smoothstep(0.0, 1.0, yIn)));
        float3 glossy = base + (tint * 0.5 + 0.3) * gloss;
        outc = mix(outc, glossy, amount * w.meta.x);
    }
    return spectra_compositeRGBA(base, outc, u);
}
