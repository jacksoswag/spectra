import Foundation
import simd

/// Concise builder for authoring built-in effect chains. Color effects receive
/// explicit overrides; other effects rely on their tuned defaults plus an
/// optional strength, so presets stay robust regardless of internal parameter
/// naming.
private func fx(_ id: String, _ values: [String: ParameterValue] = [:], strength: Double = 1.0) -> EffectInstance {
    EffectInstance(
        descriptorID: id, values: values,
        universal: UniversalParameters(strength: strength, opacity: 1, blendAmount: 1, blendMode: .normal))
}

private func chain(_ effects: [EffectInstance]) -> EffectChain { EffectChain(effects: effects) }
private func s(_ v: Double) -> ParameterValue { .scalar(v) }
private func i(_ v: Int) -> ParameterValue { .index(v) }   // for .integer / .options params

/// The curated, shipped preset library: distinct "worlds", grouped
/// Cinematic / Retro / Artistic / Utility. Each references built-in effect ids; unknown ids
/// are skipped gracefully at resolve time. Parameter values are
/// grounded in the real `EffectDescriptor` slots and tuned against the shader math
/// (e.g. glow gates on `max(r,g,b)`, so white UI always blooms and universal
/// `strength`, not `threshold`, is the readability lever).
enum BuiltInPresets {
    static let all: [Preset] = [
        // MARK: Cinematic

        preset(1, "Noir", .cinematic, "Darkroom-accurate black-and-white built on real film color science.", ["mono", "noir", "black and white", "bw", "monochrome", "darkroom", "film"], [
            // True B&W as a photographic process: a green-weighted Tri-X channel
            // mix decides how color maps to gray, then a selenium split-tone prints
            // it. Not a saturation pull to zero.
            fx("color.channelMixer", [
                "rr": s(0.30), "rg": s(0.62), "rb": s(0.08),
                "gr": s(0.30), "gg": s(0.62), "gb": s(0.08),
                "br": s(0.30), "bg": s(0.62), "bb": s(0.08),
            ]),
            fx("color.saturation", ["amount": s(-1.0)]),               // clamp residual chroma to neutral
            fx("color.toneCurve", ["lift": s(-0.02), "gain": s(1.06), "contrast": s(0.20)]),
            fx("color.contrast", ["amount": s(0.16)]),
            fx("color.colorBalance", [
                "shadowCyanRed": s(-0.04), "shadowYellowBlue": s(0.06),  // selenium-cool shadows, eased off true black
                "highYellowBlue": s(-0.05),                              // faint warm-paper highlight
            ]),
            fx("film.halation", ["threshold": s(0.62)], strength: 0.20),
            fx("film.grain", ["intensity": s(0.17), "size": s(1.3), "speed": s(0.0)]),  // static, off the 0.18 daily ceiling
        ]),

        preset(12, "Golden Hour", .cinematic, "Warm halation glow and golden-hour bloom, the whole desktop lit like magic-hour cinema.", ["golden hour", "dream", "soft", "warm", "glow", "halcyon"], [
            // One shared bloom + halation pyramid (film.glow) instead of two separate 4-pass
            // glows: the half-res prefilter + horizontal blur feed a single full-res combine
            // that emits both the soft bloom and the warm halation ring (the vertical blur is
            // folded into that combine). 10 passes → 5, look unchanged.
            fx("film.glow", ["threshold": s(0.6), "bloom": s(0.7), "halation": s(0.5)], strength: 0.7),
            fx("color.temperature", ["amount": s(0.15)]),
            fx("color.brightness", ["amount": s(0.05)]),
            fx("film.lightLeaks", strength: 0.4),
        ]),

        preset(18, "Fuji-Film", .cinematic, "Warm 2000s disposable-camera look: an amber flash-lit cast, punchy contrast, heavy live grain, and faint black dust.", ["fuji-film", "fuji", "film", "disposable", "warm", "2000s", "flash", "grade"], [
            // Warm consumer/disposable color: an amber cast, lifted muddy blacks with
            // punchy midtone contrast, a faint green midtone (the cheap-C-41 tell),
            // golden highlights, heavy 60fps color grain, a small warm flash halation,
            // and sparse inverted (black) debris.
            fx("color.temperature", ["amount": s(0.15)]),               // warm amber cast
            fx("color.toneCurve", ["lift": s(0.015), "gain": s(1.0), "contrast": s(0.14)]),  // lifted blacks + punch
            fx("color.colorBalance", [
                "magentaGreen": s(0.05),                                 // faint green midtone (cheap film)
                "shadowCyanRed": s(0.03), "shadowYellowBlue": s(-0.04),  // warm, muddy shadows
                "highCyanRed": s(0.06), "highYellowBlue": s(-0.12),      // golden yellow-red highlights
            ]),
            fx("color.saturation", ["amount": s(0.12)]),                // punchy consumer chroma
            fx("color.vibrance", ["amount": s(0.10)]),                  // restore muted-color richness
            fx("film.glow", ["threshold": s(0.70), "bloom": s(0.18), "halation": s(0.6)], strength: 0.22),  // warm flash bloom + halation
            // Heavier emulsion grain that resamples every frame (speed 1 = 60Hz) with chroma
            // grain (color 0.6) from the three independent dye-layer fields, not just luma.
            fx("film.grain", ["intensity": s(0.13), "size": s(1.7), "speed": s(1.0), "color": s(0.6)]),
            // Sparse black dust for the cheap-print feel (inverted to black, reduced 75%).
            fx("film.debris", ["intensity": s(0.5), "density": s(0.32), "speed": s(0.5), "invert": s(1.0)], strength: 0.14),
        ]),

        preset(20, "Liquid Glass", .cinematic, "Liquid Glass for your whole Mac: crisp, cool, specular, without blurring a pixel you need to read.", ["liquid glass", "glass", "frutiger aero", "aqua", "futuristic", "clean", "depth", "macos tahoe"], [
            // Glass as a material, delivered through cool color and specular edges,
            // with deliberately no blur on the layer you read.
            fx("color.temperature", ["amount": s(-0.13)]),            // dielectric/aluminium blue-white
            fx("color.tint", ["amount": s(0.06)]),                    // cancel the magenta of cooling
            fx("color.whitePoint", ["point": s(0.99)]),               // speculars just under clip
            fx("color.blackPoint", ["point": s(0.010)]),              // whisper of scatter inside the slab
            fx("color.vibrance", ["amount": s(0.12)]),                // kept <=0.14 so it never reads as OLED
            fx("color.highlights", ["amount": s(-0.06)]),             // glossy roll-off without hazing white pages
            fx("sharpen.clarity", ["amount": s(0.22)]),               // midtone-gated optical crispness
            // Stand-in for a Fresnel specular edge (no glass.specularEdge shader yet);
            // strength <=0.14 so it never reads as Film-style bloom.
            fx("film.halation", ["threshold": s(0.72)], strength: 0.14),
        ]),

        preset(23, "Cyberpunk", .cinematic, "Your desktop as a neon-lit night city: crushed blacks, blooming magenta-cyan light, built for streams and setup tours.", ["neon", "night", "magenta", "cyan", "cyberpunk", "blade runner", "synthwave", "gaming"], [
            // Light sources are precious, the dark between them absolute. The
            // dual-tone is the identity; the (frame-smearing) directional streak is
            // dropped in favor of the gradient + bloom.
            fx("color.blackPoint", ["point": s(0.06)]),               // crush shadows to void
            fx("color.contrast", ["amount": s(0.32)]),
            fx("color.gradientMap", [
                "amount": s(0.55),
                "gradient": .gradient([
                    GradientStop(position: 0.0,  color: SIMD4(0.02, 0.05, 0.09, 1)),  // near-black cyan
                    GradientStop(position: 0.45, color: SIMD4(0.28, 0.10, 0.30, 1)),  // magenta-violet midtone
                    GradientStop(position: 0.78, color: SIMD4(0.85, 0.18, 0.55, 1)),  // hot magenta (stays magenta to separate from Y2K)
                    GradientStop(position: 1.0,  color: SIMD4(0.55, 0.92, 1.00, 1)),  // electric cyan-white
                ]),
            ]),
            fx("color.vibrance", ["amount": s(0.45)]),
            fx("color.colorBalance", [
                "shadowCyanRed": s(-0.18), "shadowYellowBlue": s(0.20),
                "highCyanRed": s(0.14), "highMagentaGreen": s(-0.12),
            ]),
            // Combined bloom + halation in one 3-pass pyramid (was bloom 4 + halation 4), with
            // the binding grain folded into its combine (was a separate pass). The barely-there
            // chromatic fringe (amount 0.012) is dropped. 13 passes → 6.
            fx("film.glow", [
                "threshold": s(0.55), "bloom": s(0.7), "halation": s(0.4),
                "grain": s(0.22), "grainSize": s(1.4),
            ], strength: 0.8),
            // (The wet-night rain overlay was dropped: its falling streaks read as distracting
            //  moving lines over the desktop. The gradient + bloom carry the identity.)
        ]),

        // MARK: Retro

        preset(6, "CRT", .retro, "The glow and grain of a real phosphor tube: scanlines, shadow mask, and temporal persistence.", ["crt", "tube", "retro", "scanlines", "phosphor", "vintage"], [
            // One simple tube: the built-in shadow mask + curvature + bloom + vignette,
            // plus a soft phosphor glow. No separate aperture grille or chroma bleed,
            // which were "shattering" the image into stripes and ghosting an offset.
            fx("retro.crtAdvanced", [
                "scanline": s(0.4), "maskStrength": s(0.45),
                "curvature": s(0.10), "bloom": s(0.6), "vignette": s(0.3),
            ]),
            fx("retro.phosphorGlow", ["intensity": s(0.5), "persistence": s(0.4)]),
        ]),

        preset(3, "Matrix", .retro, "A live hacker terminal: animated code rain over a near-mono green-black world.", ["matrix", "green", "hacker", "digital", "rain", "code rain", "terminal"], [
            // One color, one light source: green pixels glowing out of black glass.
            fx("color.blacks", ["amount": s(-0.32)]),                 // deep green-black base
            fx("color.colorBalance", [
                "magentaGreen": s(0.10), "highMagentaGreen": s(0.20),  // green into highlights/mids only, shadows stay neutral
                "highCyanRed": s(-0.08), "highYellowBlue": s(-0.12),
            ]),
            fx("color.contrast", ["amount": s(0.30)]),
            fx("color.vibrance", ["amount": s(-0.35)]),               // near-monochrome; ease to -0.20 if you rely on red/amber status colors
            fx("retro.scanlines", ["count": s(720), "strength": s(0.18)], strength: 0.5),  // faint, high-count so text survives
            fx("retro.phosphorGlow", ["intensity": s(0.35), "persistence": s(0.30)]),  // now a 3-pass smear
            // Depth-layered cryptographic rain: three layers (far small/slow/dim → near
            // large/fast/bright) of stroke-built 5x7 glyphs receding into the screen. Intensity
            // lifted from 0.32 so the depth reads as a feature, not just ambient set-dressing.
            fx("glitch.digitalRain", ["intensity": s(0.45), "density": s(0.62), "speed": s(1.4)], strength: 0.5),
            // (Dropped the cohesion grain: the 16-bit working space + predither already
            //  de-band the dark green field, and phosphor/scanlines/rain texture the frame.)
        ]),

        preset(16, "VHS", .retro, "Magnetic-tape decay running live on your desktop: warm chroma bleed, tracking drift, and tape hiss.", ["vhs", "tape", "analog", "retro", "camcorder", "90s"], [
            // Usable tape: the chroma/luma desync identity (bleed + smear) plus a little
            // motion, but no head-switch tear (it made the menu bar unreadable), no
            // gaussian softening (kept it blurry and cost a 4-pass pyramid), and no NTSC
            // dot-crawl fringing (hurt text). Sharper, lighter, and menu-bar-legible.
            fx("color.temperature", ["amount": s(0.16)]),             // warm amber tape cast
            fx("color.saturation", ["amount": s(0.18)]),              // run reds a little hot
            fx("color.contrast", ["amount": s(-0.10)]),               // mild luma compression
            fx("color.colorBalance", [
                "magentaGreen": s(-0.05),
                "shadowYellowBlue": s(0.08), "highCyanRed": s(0.10),  // blue-green shadows, red highlights
            ]),
            fx("retro.colorBleed", ["amount": s(0.30)]),              // horizontal chroma smear, eased for legibility
            fx("vhs.colorSmear", ["amount": s(0.22)], strength: 0.6), // chroma lag trailing bright regions
            fx("vhs.tracking", ["intensity": s(0.12), "speed": s(0.4)], strength: 0.4),
            fx("vhs.jitter", ["amount": s(0.08), "speed": s(0.5)], strength: 0.3),
            fx("noise.filmGrain", ["intensity": s(0.16), "scale": s(40), "speed": s(1.0)]),  // tape hiss
        ]),

        preset(24, "Frutiger Aero", .retro, "Lush nature-tech glass: vivid aqua-greens, clean skies, and glossy bubble bloom.", ["frutiger aero", "aqua", "y2k", "glossy", "nature", "bubbles", "2000s"], [
            // The early-2000s "nature-tech" optimism: humid aqua-greens, clean sky blues,
            // glossy white gel highlights. Greener and fresher than Y2K/Aqua; warm-white
            // (never magenta) highlights keep it clear of Cyberpunk.
            fx("color.saturation", ["amount": s(0.24)]),              // global candy chroma lift
            fx("color.vibrance", ["amount": s(0.62)]),                // protect-skin richness on top of saturation
            fx("color.temperature", ["amount": s(-0.15)]),            // cool, fresh cast
            fx("color.colorBalance", [
                "magentaGreen": s(0.10),                              // push green into the world
                "shadowYellowBlue": s(0.26),                          // blue-cyan shadows
                "highCyanRed": s(-0.10), "highYellowBlue": s(-0.18),  // clean warm-white highlights
            ]),
            fx("color.gradientMap", [
                "amount": s(0.34),                                    // clear nature-glass ramp
                "gradient": .gradient([
                    GradientStop(position: 0.0,  color: SIMD4(0.02, 0.14, 0.20, 1)),  // deep teal
                    GradientStop(position: 0.42, color: SIMD4(0.16, 0.66, 0.58, 1)),  // vivid aqua-green
                    GradientStop(position: 0.75, color: SIMD4(0.45, 0.85, 0.96, 1)),  // clean sky aqua
                    GradientStop(position: 1.0,  color: SIMD4(1.00, 0.99, 0.94, 1)),  // glossy warm-white
                ]),
            ]),
            // Glossy bubble bloom + warm gel halation from one shared glow pyramid.
            fx("film.glow", ["threshold": s(0.60), "bloom": s(0.75), "halation": s(0.4)], strength: 0.85),
            fx("sharpen.clarity", ["amount": s(0.35)]),               // edge recovery for text under bloom
            // The signature: rising glass bubbles with refraction, a Fresnel rim, thin-film
            // iridescence, and dual speculars (full neighbourhood sampling, so they never clip).
            fx("environment.bubbles", ["density": s(0.42), "size": s(0.55), "speed": s(0.4), "opacity": s(0.5)]),
        ]),

        // MARK: Artistic
        // Full-frame "worlds" that re-render the desktop as another medium. Each
        // chains the composable Artistic passes (Style.metal) plus a baked palette
        // LUT. The painterly worlds run their Kuwahara at half resolution.

        preset(30, "Impressionism", .artistic, "Soft impressionist painting: brush-like strokes that follow the forms, broken color, and a faint canvas tooth, with text kept readable.", ["impressionism", "impressionist", "oil", "painterly", "monet", "van gogh", "brush", "art"], [
            // Colour-region brush cells oriented by the smoothed structure tensor: flat areas
            // merge into big strokes, busy areas/text keep small ones, boundaries snap to colour
            // edges, broken colour per cell, faint canvas tooth. Brushstroke Size is a range
            // (lo = smallest/complex, hi = largest/flat); the rest of the look is baked.
            fx("style.oil", ["strokeRange": .range(0.0, 1.0), "colorVar": s(1.0), "temporal": s(0.3), "canvas": s(0.4), "renderScale": s(0.25), "detail": s(1.0), "amount": s(1.0), "flow": s(1.0), "warp": s(1.0), "edgeSmooth": s(1.0)]),
            fx("color.vibrance", ["amount": s(0.18)]),
        ]),

        preset(31, "Studio Ghibli", .artistic, "Soft hand-painted animation: warm painterly fields, a sage-and-sky palette, and gentle ink.", ["ghibli", "anime", "painterly", "cozy", "warm", "miyazaki", "art"], [
            // Softer painterly than Van Gogh, warm grade, light ink kept off small text.
            fx("style.painterly", ["radius": s(5), "anisotropy": s(0.45), "sharpness": s(0.4), "detail": s(0.25)]),
            fx("style.quantize", ["bands": i(6), "smoothness": s(0.7), "saturation": s(0.12), "blackPoint": s(0.0)]),
            fx("color.lut", ["amount": s(0.8), "lut": .lut("Ghibli")]),
            fx("style.ink", ["thickness": s(1.0), "threshold": s(0.62), "opacity": s(0.45), "softness": s(0.5), "color": .color(SIMD4(0.16, 0.12, 0.10, 1))]),
            // Faint warm motes drifting in the light, the cozy Ghibli dust-in-sunbeam touch.
            fx("environment.dust", ["intensity": s(0.35), "speed": s(0.35)], strength: 0.6),
        ]),

        preset(32, "90's Anime", .artistic, "Gritty cel animation: abstracted flat colors, heavy dark linework, a moody grade, and faint analog grain.", ["90s anime", "anime", "retro anime", "cel", "akira", "ova", "moody", "art"], [
            // One strong cel pass: abstraction dissolves text, luminance bands into
            // bold flat tones, and outlines come from the abstracted shape edges.
            fx("style.cel", ["bands": i(4), "saturation": s(0.45), "inkStrength": s(1.0), "inkWidth": s(2.2), "smoothness": s(0.15), "abstraction": s(0.75)]),
            fx("color.lut", ["amount": s(0.9), "lut": .lut("90s Anime")]),
            fx("noise.filmGrain", ["intensity": s(0.06), "scale": s(60), "speed": s(1.0)]),  // faint cel-on-tape grain
            fx("retro.scanlines", ["count": s(900), "strength": s(0.06)], strength: 0.35),    // whisper of a scanline
        ]),

        preset(33, "Comic Book", .artistic, "Your desktop printed as a comic page: a Ben-Day halftone screen on paper, bold black outlines, and punchy ink colors.", ["comic", "pop art", "halftone", "ben-day", "cartoon", "ink", "newsprint", "art"], [
            // Texture-imposing: prints a halftone page so even flat UI reads as a comic.
            fx("style.comic", ["bands": i(3), "saturation": s(0.5), "inkStrength": s(0.9), "inkWidth": s(1.6), "dotDensity": s(0.5), "abstraction": s(0.7), "paper": s(0.85)]),
            fx("color.lut", ["amount": s(0.55), "lut": .lut("Comic")]),
        ]),

        preset(35, "Watercolor", .artistic, "A soft watercolor wash: pooled pigment edges, pale pastel tones, and visible cold-press paper.", ["watercolor", "paint", "pastel", "soft", "journal", "cozy", "paper", "art"], [
            // Light isotropic painterly (wet, non-directional). Quantize sets the flat
            // pools, then soft low-opacity "ink" pools pigment along those pool edges
            // (ink after quantize, so the Sobel rings the visible tone boundaries).
            fx("style.painterly", ["radius": s(3), "anisotropy": s(0.2), "sharpness": s(0.3), "detail": s(0.30)]),
            fx("style.quantize", ["bands": i(8), "smoothness": s(0.8), "saturation": s(0.05), "blackPoint": s(0.0)]),
            fx("style.ink", ["thickness": s(1.0), "threshold": s(0.60), "opacity": s(0.30), "softness": s(0.7), "color": .color(SIMD4(0.20, 0.18, 0.22, 1))]),
            fx("style.paper", ["intensity": s(0.35), "scale": s(2.5), "tint": .color(SIMD4(0.97, 0.96, 0.92, 1))]),
            fx("color.lut", ["amount": s(0.7), "lut": .lut("Watercolor")]),
        ]),

        preset(36, "Pencil Sketch", .artistic, "A hand-drawn graphite sketch: contour lines, cross-hatch shading, and warm paper.", ["pencil", "sketch", "graphite", "drawing", "hatch", "monochrome", "art"], [
            fx("color.saturation", ["amount": s(-1.0)]),               // graphite is monochrome
            fx("style.ink", ["thickness": s(1.0), "threshold": s(0.55), "opacity": s(0.85), "softness": s(0.4), "color": .color(SIMD4(0.12, 0.12, 0.13, 1))]),
            fx("style.hatch", ["spacing": s(5), "strength": s(0.6), "angle": s(35)]),
            fx("color.lut", ["amount": s(0.7), "lut": .lut("Graphite")]),
            fx("style.paper", ["intensity": s(0.4), "scale": s(3.0), "tint": .color(SIMD4(0.95, 0.93, 0.87, 1))]),
        ]),

        // MARK: Utility

        preset(21, "Studio", .utility, "A calibrated display upgrade: deeper blacks, richer midtones, and crisp clarity, all day.", ["studio", "calibrated", "oled", "contrast", "display", "panel"], [
            // Deepen, never restyle. Deep blacks + a gentle symmetric contrast + a touch
            // of vibrance and midtone clarity reads as a better panel. No global gain
            // (which deep-fried and clipped highlights) and no large-radius local contrast
            // (which quilted and rang on text). Subtle by design; safe for all-day use.
            fx("color.blackPoint", ["point": s(0.012)]),              // deep true blacks, gentle
            fx("color.contrast", ["amount": s(0.10)]),                // rich contrast around mid-grey, no brightening
            fx("color.vibrance", ["amount": s(0.12)]),                // subtle P3-leaning richness, clip-protected
            fx("sharpen.clarity", ["amount": s(0.18)]),               // midtone crispness; midtone-gated, no quilt or ring
        ]),

        preset(22, "Reading", .utility, "Paper-white for your whole screen: lifted dark-UI glare, softened peak white, and re-crispened text.", ["reading", "comfort", "eye strain", "paper", "dyslexia", "dark academia", "focus", "warm display", "meares irlen"], [
            // The physics of paper, not a yellow overlay: warm the white point,
            // compress the top of the tone scale, lift black, then re-crisp text.
            fx("color.temperature", ["amount": s(0.10)]),             // lower than Dreamy's 0.12 so the warmths diverge
            fx("color.tint", ["amount": s(-0.04)]),                   // trace green → Bianca cream, not amber
            fx("color.sepia", ["amount": s(0.06)]),                   // subliminal bind onto one paper tone
            fx("color.shadows", ["amount": s(0.07)]),                 // lift black toward charcoal, de-glare dark UI
            fx("color.contrast", ["amount": s(-0.06)]),               // pull peak white off the glare ceiling
            fx("sharpen.unsharpMask", ["amount": s(0.45), "radius": s(2)]),  // radius is device px at renderScale 1.0
        ]),
    ]

    private static func preset(
        _ n: Int, _ name: String, _ category: PresetCategory, _ summary: String,
        _ tags: [String], _ effects: [EffectInstance]
    ) -> Preset {
        Preset(id: uuid(n), name: name, category: category, summary: summary, author: "Spectra",
               tags: tags, chain: chain(effects), isBuiltIn: true)
    }

    /// Stable, deterministic ids so recents survive launches.
    private static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5EC42A00-0000-0000-0000-%012X", n))!
    }
}
