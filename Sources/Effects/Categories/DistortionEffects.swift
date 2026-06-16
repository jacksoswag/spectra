import Foundation
import simd

/// Built-in distortion effects. Each descriptor's parameter order is the GPU
/// slot order its Metal function reads (see `Distortion.metal`). A point
/// parameter occupies two slots (x, y); scalars/angles occupy one.
enum DistortionEffects {
    static let all: [EffectDescriptor] = [
        warp, bulge, pinch, fishEye, barrel, chromatic,
        heat, wave, ripple, swirl, shockwave, perspective,
    ]

    static let warp = EffectDescriptor(
        id: "distortion.warp", name: "Warp", category: .distortion,
        subtitle: "Radial sinusoidal warp from a center.", icon: "tornado",
        function: "fx_distort_warp",
        parameters: [
            .point("center", "Center"),
            .slider("amount", "Amount", 0...1, default: 0.4),
        ],
        tags: ["ripple", "wobble"])

    static let bulge = EffectDescriptor(
        id: "distortion.bulge", name: "Bulge", category: .distortion,
        subtitle: "Magnify outward from a point.", icon: "circle.circle",
        function: "fx_distort_bulge",
        parameters: [
            .point("center", "Center"),
            .slider("radius", "Radius", 0.05...1, default: 0.4),
            .slider("amount", "Amount", 0...1, default: 0.5),
        ],
        tags: ["magnify", "lens"])

    static let pinch = EffectDescriptor(
        id: "distortion.pinch", name: "Pinch", category: .distortion,
        subtitle: "Squeeze the image inward.", icon: "arrow.down.right.and.arrow.up.left",
        function: "fx_distort_pinch",
        parameters: [
            .point("center", "Center"),
            .slider("radius", "Radius", 0.05...1, default: 0.4),
            .slider("amount", "Amount", 0...1, default: 0.5),
        ],
        tags: ["squeeze", "vortex"])

    static let fishEye = EffectDescriptor(
        id: "distortion.fishEye", name: "Fish Eye", category: .distortion,
        subtitle: "Strong barrel spherize.", icon: "globe",
        function: "fx_distort_fishEye",
        parameters: [.slider("amount", "Amount", 0...1, default: 0.5)],
        tags: ["lens", "wideAngle"])

    static let barrel = EffectDescriptor(
        id: "distortion.barrel", name: "Barrel Distortion", category: .distortion,
        subtitle: "Lens barrel / pincushion via radial coefficients.", icon: "camera.aperture",
        function: "fx_distort_barrel",
        parameters: [
            .slider("k1", "K1", -0.5...0.5, default: 0.2),
            .slider("k2", "K2", -0.5...0.5, default: 0),
        ],
        tags: ["lens", "pincushion"])

    static let chromatic = EffectDescriptor(
        id: "distortion.chromatic", name: "Chromatic Distortion", category: .distortion,
        subtitle: "Per-channel radial scale for RGB fringing.", icon: "rays",
        function: "fx_distort_chromatic",
        parameters: [.slider("amount", "Amount", 0...1, default: 0.5)],
        tags: ["aberration", "fringe", "rgb"])

    static let heat = EffectDescriptor(
        id: "distortion.heat", name: "Heat Distortion", category: .distortion,
        subtitle: "Animated noise shimmer.", icon: "flame",
        function: "fx_distort_heat",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["shimmer", "mirage", "animated"],
        isAnimated: true)

    static let wave = EffectDescriptor(
        id: "distortion.wave", name: "Wave", category: .distortion,
        subtitle: "Animated sine displacement.", icon: "water.waves",
        function: "fx_distort_wave",
        parameters: [
            .slider("amplitude", "Amplitude", 0...1, default: 0.4),
            .slider("frequency", "Frequency", 0.5...12, default: 4),
            .slider("speed", "Speed", 0...6, default: 2),
        ],
        tags: ["sine", "wobble", "animated"],
        isAnimated: true)

    static let ripple = EffectDescriptor(
        id: "distortion.ripple", name: "Ripple", category: .distortion,
        subtitle: "Animated concentric ripples.", icon: "drop.circle",
        function: "fx_distort_ripple",
        parameters: [
            .point("center", "Center"),
            .slider("amplitude", "Amplitude", 0...1, default: 0.5),
            .slider("frequency", "Frequency", 1...30, default: 12),
            .slider("speed", "Speed", 0...8, default: 3),
        ],
        tags: ["water", "concentric", "animated"],
        isAnimated: true)

    static let swirl = EffectDescriptor(
        id: "distortion.swirl", name: "Swirl", category: .distortion,
        subtitle: "Rotate the image around a point with radial falloff.", icon: "hurricane",
        function: "fx_distort_swirl",
        parameters: [
            .point("center", "Center"),
            .angle("angle", "Angle", default: 90),
            .slider("radius", "Radius", 0.05...1, default: 0.5),
        ],
        tags: ["twist", "vortex", "spiral"])

    static let shockwave = EffectDescriptor(
        id: "distortion.shockwave", name: "Shockwave", category: .distortion,
        subtitle: "Animated expanding ring displacement.", icon: "wave.3.right",
        function: "fx_distort_shockwave",
        parameters: [
            .point("center", "Center"),
            .slider("speed", "Speed", 0.1...6, default: 1.5),
            .slider("width", "Width", 0.02...0.5, default: 0.1),
            .slider("amplitude", "Amplitude", 0...1, default: 0.5),
        ],
        tags: ["blast", "ring", "animated"],
        isAnimated: true)

    static let perspective = EffectDescriptor(
        id: "distortion.perspective", name: "Perspective Warp", category: .distortion,
        subtitle: "Keystone-style horizontal/vertical skew.", icon: "perspective",
        function: "fx_distort_perspective",
        parameters: [
            .slider("horizontal", "Horizontal", -1...1, default: 0.3),
            .slider("vertical", "Vertical", -1...1, default: 0),
        ],
        tags: ["keystone", "tilt", "skew"])
}
