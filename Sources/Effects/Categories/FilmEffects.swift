import Foundation
import simd

/// Built-in film emulation effects. Each descriptor's parameter order is the GPU
/// slot order its Metal function reads (see `Film.metal`). Animated effects
/// (grain, dust, scratches, weave, leaks, flicker, burn) set `isAnimated: true`.
enum FilmEffects {
    static let all: [EffectDescriptor] = [
        sixteenMM, thirtyFiveMM, seventyMM, kodak, fuji,
        grain, dust, scratches, gateWeave, debris, lightLeaks,
        halation, bloom, glow, flicker, burn,
    ]

    static let sixteenMM = EffectDescriptor(
        id: "film.16mm", name: "16mm", category: .film,
        subtitle: "Heavier grain with gate weave.", icon: "film",
        function: "fx_film_16mm",
        parameters: [
            .slider("grain", "Grain", 0...1, default: 0.55),
            .slider("gateWeave", "Gate Weave", 0...1, default: 0.4),
            .slider("contrast", "Contrast", 0...1, default: 0.25),
        ],
        tags: ["celluloid", "grain", "vintage"],
        isAnimated: true)

    static let thirtyFiveMM = EffectDescriptor(
        id: "film.35mm", name: "35mm", category: .film,
        subtitle: "Classic cinema look with halation.", icon: "film",
        function: "fx_film_35mm",
        parameters: [
            .slider("grain", "Grain", 0...1, default: 0.35),
            .slider("halation", "Halation", 0...1, default: 0.5),
        ],
        tags: ["cinema", "grain", "halation"],
        isAnimated: true)

    static let seventyMM = EffectDescriptor(
        id: "film.70mm", name: "70mm", category: .film,
        subtitle: "Large-format clean richness.", icon: "film",
        function: "fx_film_70mm",
        parameters: [
            .slider("grain", "Grain", 0...1, default: 0.15),
            .slider("richness", "Richness", 0...1, default: 0.5),
        ],
        tags: ["large format", "rich", "clean"],
        isAnimated: true)

    static let kodak = EffectDescriptor(
        id: "film.kodak", name: "Kodak", category: .film,
        subtitle: "Warm highlights, teal shadows.", icon: "swatchpalette",
        function: "fx_film_kodak",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.8),
        ],
        tags: ["color science", "warm"])

    static let fuji = EffectDescriptor(
        id: "film.fuji", name: "Fuji", category: .film,
        subtitle: "Cooler, greener color science.", icon: "swatchpalette",
        function: "fx_film_fuji",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.8),
        ],
        tags: ["color science", "cool", "green"])

    static let grain = EffectDescriptor(
        id: "film.grain", name: "Film Grain", category: .film,
        subtitle: "Animated luminance grain.", icon: "circle.grid.3x3.fill",
        function: "fx_film_grain",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.4),
            .slider("size", "Grain Size", 0.5...6, default: 1.8),
            .slider("speed", "Speed", 0...1, default: 1.0),
            .slider("color", "Color Grain", 0...1, default: 0),
        ],
        tags: ["grain", "texture", "noise", "color"],
        isAnimated: true, animatedParam: "speed")   // speed 0 = static pattern, no idle redraw

    static let dust = EffectDescriptor(
        id: "film.dust", name: "Dust", category: .film,
        subtitle: "Animated dust and dirt specks.", icon: "sparkles",
        function: "fx_film_dust",
        parameters: [
            .slider("density", "Density", 0...1, default: 0.4),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["dust", "dirt", "damage"],
        isAnimated: true)

    static let scratches = EffectDescriptor(
        id: "film.scratches", name: "Scratches", category: .film,
        subtitle: "Animated vertical scratches.", icon: "line.diagonal",
        function: "fx_film_scratches",
        parameters: [
            .slider("density", "Density", 0...1, default: 0.4),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["scratches", "damage", "wear"],
        isAnimated: true)

    static let gateWeave = EffectDescriptor(
        id: "film.gateWeave", name: "Gate Weave", category: .film,
        subtitle: "Animated frame jitter and drift.", icon: "move.3d",
        function: "fx_film_gateWeave",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["weave", "jitter", "transport"],
        isAnimated: true)

    static let debris = EffectDescriptor(
        id: "film.debris", name: "Film Debris", category: .film,
        subtitle: "Animated dust and hairs that contrast with the background.", icon: "sparkles",
        function: "fx_film_debris",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("density", "Density", 0...1, default: 0.4),
            .slider("speed", "Speed", 0...1, default: 0.5),
            .slider("invert", "Invert (Dark)", 0...1, default: 0),
        ],
        tags: ["dust", "hair", "debris", "damage"],
        isAnimated: true)

    static let lightLeaks = EffectDescriptor(
        id: "film.lightLeaks", name: "Light Leaks", category: .film,
        subtitle: "Animated colored edge leak.", icon: "sun.haze.fill",
        function: "fx_film_lightLeaks",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.6),
            .slider("position", "Position", 0...1, default: 0.2),
            .slider("speed", "Speed", 0...1, default: 0.4),
        ],
        tags: ["light leak", "flare", "color"],
        isAnimated: true)

    static let halation = EffectDescriptor(
        id: "film.halation", name: "Halation", category: .film,
        subtitle: "Red/orange glow around highlights.", icon: "sun.max.fill",
        parameters: [
            .slider("threshold", "Threshold", 0...1, default: 0.6),
            .slider("intensity", "Intensity", 0...1, default: 0.6),
        ],
        passes: [
            EffectPass("fx_film_glow_prefilter", scale: 0.5),
            EffectPass("fx_film_glow_blur", scale: 0.5, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_film_glow_blur", scale: 0.5, direction: SIMD2<Float>(0, 1)),
            EffectPass("fx_film_halation_combine", scale: 1.0),
        ],
        tags: ["halation", "glow", "highlights"])

    static let bloom = EffectDescriptor(
        id: "film.bloom", name: "Bloom", category: .film,
        subtitle: "Bright luminous highlight bloom.", icon: "rays",
        parameters: [
            .slider("threshold", "Threshold", 0...1, default: 0.65),
            .slider("intensity", "Intensity", 0...1, default: 0.6),
        ],
        passes: [
            EffectPass("fx_film_glow_prefilter", scale: 0.5),
            EffectPass("fx_film_glow_blur", scale: 0.5, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_film_glow_blur", scale: 0.5, direction: SIMD2<Float>(0, 1)),
            EffectPass("fx_film_bloom_combine", scale: 1.0),
        ],
        tags: ["bloom", "glow", "highlights"])

    // Combined bloom + halation from ONE shared blur pyramid (the prefilter and separable blur
    // are identical to Bloom/Halation; only the combine differs). Running ONE pyramid instead of
    // two halves the glow cost — 8 passes → 4 — while the blur stays at HALF resolution so GPU
    // time drops too. `bloom`/`halation` dial each contribution independently; the optional
    // `grain` folds a trailing film grain into the (cheap, single-read) combine for free. Not
    // animated: grain resamples on every delivered frame and is imperceptibly static on a frozen
    // screen, so it adds no idle-repaint cost. See `fx_film_glow_combine` in Film.metal.
    static let glow = EffectDescriptor(
        id: "film.glow", name: "Glow", category: .film,
        subtitle: "Bloom and halation from one shared pyramid.", icon: "rays",
        parameters: [
            .slider("threshold", "Threshold", 0...1, default: 0.6),
            .slider("bloom", "Bloom", 0...2, default: 0.6),
            .slider("halation", "Halation", 0...2, default: 0.4),
            .slider("grain", "Grain", 0...1, default: 0.0),
            .slider("grainSize", "Grain Size", 0.5...6, default: 1.4),
        ],
        passes: [
            EffectPass("fx_film_glow_prefilter", scale: 0.5),
            EffectPass("fx_film_glow_blur", scale: 0.5, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_film_glow_blur", scale: 0.5, direction: SIMD2<Float>(0, 1)),
            EffectPass("fx_film_glow_combine", scale: 1.0),
        ],
        tags: ["bloom", "halation", "glow", "highlights"])

    static let flicker = EffectDescriptor(
        id: "film.flicker", name: "Flicker", category: .film,
        subtitle: "Animated exposure flicker.", icon: "lightbulb.fill",
        function: "fx_film_flicker",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.4),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["flicker", "exposure", "projector"],
        isAnimated: true)

    static let burn = EffectDescriptor(
        id: "film.burn", name: "Film Burn", category: .film,
        subtitle: "Animated burn from a moving hotspot.", icon: "flame.fill",
        function: "fx_film_burn",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.6),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["burn", "blowout", "damage"],
        isAnimated: true)
}
