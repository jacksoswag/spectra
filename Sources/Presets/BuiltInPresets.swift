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

/// The curated, shipped preset library: a small hand-tuned set across Cinematic
/// and Retro. Accessibility lives in Settings now (it taps the real macOS system
/// accessibility settings rather than custom shaders). Each preset references
/// built-in effect ids; unknown ids are skipped gracefully at resolve time.
enum BuiltInPresets {
    static let all: [Preset] = [
        // MARK: Cinematic

        preset(1, "Noir", .cinematic, "Filmic high-contrast black & white.", ["mono", "noir", "film"], [
            fx("color.saturation", ["amount": s(-1.0)]),
            fx("color.contrast", ["amount": s(0.28)]),
            fx("color.toneCurve", ["lift": s(-0.03), "gain": s(1.04), "contrast": s(0.22)]),
            fx("film.halation", strength: 0.25),                       // subtle highlight glow
            fx("film.grain", ["intensity": s(0.3), "size": s(1.2)]),   // fine large-format grain
        ]),

        preset(12, "Dreamy", .cinematic, "Soft, glowing, ethereal.", ["dream", "soft"], [
            // Bloom's half-res glow already supplies the soft diffusion, so the separate
            // full-res Gaussian blur is dropped — it cost 4 passes (incl. a full-res
            // upsample) for softness bloom largely duplicates. Bloom is nudged up to
            // compensate. Keeps the ethereal look at ~28% fewer passes.
            fx("film.bloom", strength: 0.7),
            fx("film.halation", strength: 0.5),
            fx("color.temperature", ["amount": s(0.15)]),
            fx("color.brightness", ["amount": s(0.05)]),
            fx("film.lightLeaks", strength: 0.4),
        ]),

        preset(2, "Blade Runner", .cinematic, "Smoggy BR2049-city grade: cool teal shadows, muted blue-grey midtones, restrained magenta neon, soft amber highlights.", ["moody", "cyberpunk", "teal", "desaturated"], [
            // The old grade ran a hot purple→magenta→neon-red ramp at 0.7 and
            // boosted saturation/vibrance, which "deep-fried" the image. The 2049
            // LA city look is the opposite: dark, cool, smoggy and DESATURATED,
            // with only restrained magenta/pink neon accents and a touch of warm
            // amber in the brightest highlights. We map luminance through a muted,
            // low-saturation ramp (channel values kept close together so nothing
            // reads as pure neon) and pull the gradient amount way down so it tints
            // rather than replaces. Most of the image lives in the cool blue-grey
            // midtone, exactly where 2049's city footage sits.
            fx("color.gradientMap", [
                "amount": s(0.4),
                "gradient": .gradient([
                    GradientStop(position: 0.0,  color: SIMD4(0.03, 0.07, 0.09, 1)),  // near-black cyan shadow
                    GradientStop(position: 0.28, color: SIMD4(0.10, 0.22, 0.24, 1)),  // desaturated teal
                    GradientStop(position: 0.55, color: SIMD4(0.30, 0.36, 0.42, 1)),  // cool blue-grey midtone (most of the frame)
                    GradientStop(position: 0.80, color: SIMD4(0.52, 0.36, 0.46, 1)),  // dusty muted magenta neon accent
                    GradientStop(position: 1.0,  color: SIMD4(0.86, 0.74, 0.58, 1)),  // soft warm amber highlight
                ]),
            ]),
            fx("color.colorBalance", [
                "shadowCyanRed": s(-0.08), "shadowYellowBlue": s(0.10),  // gentle teal push in the shadows
                "highYellowBlue": s(-0.06),                              // faint warm lift in highlights
            ]),
            fx("color.saturation", ["amount": s(-0.18)]),               // read desaturated / understated
            fx("color.vibrance", ["amount": s(0.15)]),                  // just enough to keep neon accents alive
            fx("color.contrast", ["amount": s(0.14)]),                  // gentle, not deep-fried
            fx("film.bloom", strength: 0.3),                            // subtle atmospheric haze, not blown out
            fx("film.halation", strength: 0.18),
        ]),

        preset(17, "Film", .cinematic, "Light, non-invasive film grain and grade.", ["film", "grain", "subtle"], [
            fx("film.grain", ["intensity": s(0.22), "size": s(1.5)]),
            fx("color.toneCurve", ["contrast": s(0.1), "gain": s(1.02)]),
            fx("film.kodak", ["amount": s(0.4)]),
        ]),

        preset(15, "Disposable Camera", .cinematic, "Warm flash-lit 35mm snapshot.", ["film", "snapshot", "warm"], [
            fx("color.temperature", ["amount": s(0.16)]),
            fx("color.vibrance", ["amount": s(0.22)]),
            fx("color.shadows", ["amount": s(0.10)]),
            fx("color.highlights", ["amount": s(-0.08)]),
            fx("film.grain", ["intensity": s(0.4), "speed": s(0.15)]),   // slow, gently evolving grain
            fx("film.lightLeaks", strength: 0.25),
            fx("sharpen.sharpen", strength: 0.3),                      // flash-lit punch
        ]),

        // MARK: Retro

        preset(6, "CRT Monitor", .retro, "Gently curved vacuum-tube with scanlines, shadow mask, and phosphor glow.", ["crt", "tube"], [
            fx("retro.crtAdvanced", [
                "scanline": s(0.4), "maskStrength": s(0.45),
                "curvature": s(0.10), "bloom": s(0.6), "vignette": s(0.3),
            ]),
            fx("retro.phosphorGlow", ["intensity": s(0.5), "persistence": s(0.4)]),
        ]),

        preset(3, "The Matrix", .retro, "Hacky terminal grade with subtle falling code rain: crushed blacks, faint phosphor green.", ["green", "hacker", "digital", "rain"], [
            fx("color.colorBalance", [
                "cyanRed": s(-0.1), "magentaGreen": s(0.2), "yellowBlue": s(-0.2),
                "highMagentaGreen": s(0.15),                           // green lives in highlights only
            ]),
            fx("color.blacks", ["amount": s(-0.25)]),                  // crush the blacks
            fx("color.contrast", ["amount": s(0.30)]),
            fx("color.vibrance", ["amount": s(-0.1)]),
            // Replaces the old "noise.digital" flashing squares (too invasive) with
            // Matrix-style falling glyphs. Tuned subtle: low opacity, moderate
            // column density and a gentle scroll, plus a reduced universal strength
            // so the rain reads as an ambient overlay rather than taking over.
            fx("glitch.digitalRain", [
                "intensity": s(0.45), "density": s(0.45), "speed": s(0.8),
            ], strength: 0.7),
            fx("retro.scanlines", strength: 0.2),                      // softened so the rain leads the look
            fx("retro.phosphorGlow", ["intensity": s(0.3), "persistence": s(0.3)]),  // subtle CRT-green bloom
        ]),

        preset(16, "VHS", .retro, "Worn tape: soft, mild chroma drift.", ["vhs", "tape", "analog"], [
            fx("vhs.tracking", strength: 0.2),
            fx("vhs.chromaDrift", strength: 0.3),
            fx("vhs.colorSmear", strength: 0.3),
            fx("vhs.generationLoss", strength: 0.4),
            fx("noise.filmGrain", strength: 0.25),
        ]),

        preset(7, "Camcorder", .retro, "Understated 90s consumer camcorder.", ["camcorder", "90s", "analog"], [
            fx("camcorder.consumer90s", ["intensity": s(0.45)]),
            fx("camcorder.interlace", strength: 0.3),
            fx("color.temperature", ["amount": s(0.1)]),
            fx("noise.filmGrain", strength: 0.2),
            fx("camcorder.recOSD"),
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
