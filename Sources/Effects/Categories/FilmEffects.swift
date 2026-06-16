import Foundation
import simd

/// Built-in film emulation effects. Each descriptor's parameter order is the GPU
/// slot order its Metal function reads (see `Film.metal`). Animated effects
/// (grain, dust, scratches, weave, leaks, flicker, burn) set `isAnimated: true`.
enum FilmEffects {
    static let all: [EffectDescriptor] = [
        sixteenMM, thirtyFiveMM, seventyMM, kodak, fuji,
        grain, dust, scratches, gateWeave, lightLeaks,
        halation, bloom, flicker, burn,
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
        ],
        tags: ["grain", "texture", "noise"],
        isAnimated: true)

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
