import Foundation
import simd

/// Built-in environment effects: atmospheric weather and light overlays. Each
/// descriptor's parameter order is the GPU slot order its Metal function reads
/// (see `Environment.metal`). A point parameter occupies two slots (x, y);
/// scalars/angles occupy one.
enum EnvironmentEffects {
    static let all: [EffectDescriptor] = [
        rain, fog, snow, dust, bubbles, underwater,
        heatHaze, godRays, sunGlare, lensFlare, clouds,
    ]

    static let rain = EffectDescriptor(
        id: "environment.rain", name: "Rain", category: .environment,
        subtitle: "Animated falling streaks with subtle refraction.", icon: "cloud.rain",
        function: "fx_env_rain",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...1, default: 0.5),
            .angle("angle", "Angle", default: 12),
        ],
        tags: ["weather", "storm", "drops"],
        isAnimated: true)

    static let fog = EffectDescriptor(
        id: "environment.fog", name: "Fog", category: .environment,
        subtitle: "Drifting height-based atmospheric haze.", icon: "cloud.fog",
        function: "fx_env_fog",
        parameters: [
            .slider("density", "Density", 0...1, default: 0.5),
            .slider("height", "Height", 0.1...1, default: 0.6),
            .slider("speed", "Speed", 0...1, default: 0.4),
        ],
        tags: ["weather", "mist", "haze"],
        isAnimated: true)

    static let snow = EffectDescriptor(
        id: "environment.snow", name: "Snow", category: .environment,
        subtitle: "Animated falling flakes across depth layers.", icon: "snowflake",
        function: "fx_env_snow",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...1, default: 0.4),
            .slider("size", "Flake Size", 0...1, default: 0.5),
        ],
        tags: ["weather", "winter", "flakes"],
        isAnimated: true)

    static let dust = EffectDescriptor(
        id: "environment.dust", name: "Dust Motes", category: .environment,
        subtitle: "Floating illuminated motes drifting in air.", icon: "sparkles",
        function: "fx_env_dust",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...1, default: 0.4),
        ],
        tags: ["motes", "particles", "air"],
        isAnimated: true)

    static let bubbles = EffectDescriptor(
        id: "environment.bubbles", name: "Bubbles", category: .environment,
        subtitle: "Rising glossy water-bubble bokeh.", icon: "bubbles.and.sparkles",
        function: "fx_env_bubbles",
        parameters: [
            .slider("density", "Density", 0...1, default: 0.2),
            .slider("size", "Size", 0...1, default: 0.0),
            .slider("speed", "Speed", 0...1, default: 0.1),
            .slider("opacity", "Opacity", 0...1, default: 0.5),
            .toggle("pop", "Pop", default: true, help: "Bubbles occasionally swell and burst."),
            .toggle("foam", "Foam", default: true, help: "A fine layer of tiny white floaters."),
        ],
        tags: ["bubbles", "bokeh", "frutiger aero", "glossy", "water"],
        isAnimated: true)

    static let underwater = EffectDescriptor(
        id: "environment.underwater", name: "Underwater", category: .environment,
        subtitle: "Caustic warble with a blue water tint.", icon: "water.waves",
        function: "fx_env_underwater",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["water", "caustics", "submerged"],
        isAnimated: true)

    static let heatHaze = EffectDescriptor(
        id: "environment.heatHaze", name: "Heat Haze", category: .environment,
        subtitle: "Rising shimmer warps the image upward.", icon: "sun.haze",
        function: "fx_env_heatHaze",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["heat", "shimmer", "mirage"],
        isAnimated: true)

    static let godRays = EffectDescriptor(
        id: "environment.godRays", name: "God Rays", category: .environment,
        subtitle: "Radial light scattering from a sun position.", icon: "sun.max",
        function: "fx_env_godRays",
        parameters: [
            .point("sun", "Sun", default: SIMD2(0.5, 0.2)),
            .slider("intensity", "Intensity", 0...1, default: 0.6),
            .slider("decay", "Decay", 0...1, default: 0.5),
        ],
        tags: ["light", "crepuscular", "sunbeams"])

    static let sunGlare = EffectDescriptor(
        id: "environment.sunGlare", name: "Sun Glare", category: .environment,
        subtitle: "Bright bloom and starburst at the sun.", icon: "sun.max.fill",
        function: "fx_env_sunGlare",
        parameters: [
            .point("sun", "Sun", default: SIMD2(0.5, 0.3)),
            .slider("intensity", "Intensity", 0...1, default: 0.6),
        ],
        tags: ["light", "bloom", "glare"])

    static let lensFlare = EffectDescriptor(
        id: "environment.lensFlare", name: "Lens Flare", category: .environment,
        subtitle: "Chromatic ghosts and halo along the sun axis.", icon: "camera.filters",
        function: "fx_env_lensFlare",
        parameters: [
            .point("sun", "Sun", default: SIMD2(0.35, 0.3)),
            .slider("intensity", "Intensity", 0...1, default: 0.6),
        ],
        tags: ["light", "ghosts", "optical"])

    static let clouds = EffectDescriptor(
        id: "environment.clouds", name: "Cloud Overlay", category: .environment,
        subtitle: "Drifting fbm clouds with shadow cores.", icon: "cloud",
        function: "fx_env_clouds",
        parameters: [
            .slider("coverage", "Coverage", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...1, default: 0.5),
        ],
        tags: ["sky", "weather", "shadows"],
        isAnimated: true)
}
