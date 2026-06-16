import Foundation
import simd

/// Built-in blur effects. Each descriptor's parameter order is the GPU slot
/// order its Metal function reads (see `Blur.metal`). The Gaussian blur is a
/// two-pass separable filter; all other blurs are single-pass golden-angle or
/// line gathers with bounded tap counts.
enum BlurEffects {
    static let all: [EffectDescriptor] = [
        gaussian, lens, directional, motion, zoom, bokeh, depth, tiltShift,
    ]

    static let gaussian = EffectDescriptor(
        id: "blur.gaussian", name: "Gaussian Blur", category: .blur,
        subtitle: "Smooth separable softening.", icon: "drop",
        parameters: [.slider("radius", "Radius", 0...64, default: 8, unit: "px")],
        passes: [
            EffectPass("fx_blur_downsample", scale: 0.5),
            EffectPass("fx_blur_gaussian_h", scale: 0.5, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_blur_gaussian_v", scale: 0.5, direction: SIMD2<Float>(0, 1)),
            EffectPass("fx_blur_gaussian_up", scale: 1.0),
        ],
        tags: ["soften", "defocus", "smooth"])

    static let lens = EffectDescriptor(
        id: "blur.lens", name: "Lens Blur", category: .blur,
        subtitle: "Disc-shaped optical bokeh.", icon: "camera.aperture",
        parameters: [.slider("radius", "Radius", 0...48, default: 12, unit: "px")],
        passes: [
            EffectPass("fx_blur_downsample", scale: 0.5),
            EffectPass("fx_blur_lens", scale: 0.5),
            EffectPass("fx_blur_gaussian_up", scale: 1.0),
        ],
        tags: ["bokeh", "defocus", "optical"])

    static let directional = EffectDescriptor(
        id: "blur.directional", name: "Directional Blur", category: .blur,
        subtitle: "Smear evenly along an angle.", icon: "arrow.left.and.right",
        function: "fx_blur_directional",
        parameters: [
            .angle("angle", "Angle", default: 0),
            .slider("length", "Length", 0...96, default: 24, unit: "px"),
        ],
        tags: ["streak", "smear", "linear"])

    static let motion = EffectDescriptor(
        id: "blur.motion", name: "Motion Blur", category: .blur,
        subtitle: "Trailing smear with falloff.", icon: "figure.run",
        function: "fx_blur_motion",
        parameters: [
            .angle("angle", "Angle", default: 0),
            .slider("amount", "Amount", 0...96, default: 32, unit: "px"),
        ],
        tags: ["movement", "trail", "speed"])

    static let zoom = EffectDescriptor(
        id: "blur.zoom", name: "Zoom Blur", category: .blur,
        subtitle: "Radial streaks toward a center.", icon: "scope",
        function: "fx_blur_zoom",
        parameters: [
            .point("center", "Center", default: SIMD2(0.5, 0.5)),
            .slider("strength", "Strength", 0...0.6, default: 0.2),
        ],
        tags: ["radial", "burst", "speed"])

    static let bokeh = EffectDescriptor(
        id: "blur.bokeh", name: "Bokeh Blur", category: .blur,
        subtitle: "Defocus with blooming highlights.", icon: "sparkles",
        parameters: [
            .slider("radius", "Radius", 0...48, default: 14, unit: "px"),
            .slider("intensity", "Highlight Boost", 0...2, default: 0.7),
        ],
        passes: [
            EffectPass("fx_blur_downsample", scale: 0.5),
            EffectPass("fx_blur_bokeh", scale: 0.5),
            EffectPass("fx_blur_gaussian_up", scale: 1.0),
        ],
        tags: ["bokeh", "highlight", "defocus"])

    static let depth = EffectDescriptor(
        id: "blur.depth", name: "Depth Blur", category: .blur,
        subtitle: "Blur grows away from a focus point.", icon: "camera.metering.center.weighted",
        function: "fx_blur_depth",
        parameters: [
            .point("focusCenter", "Focus Center", default: SIMD2(0.5, 0.5)),
            .slider("focusRange", "Focus Range", 0...0.7, default: 0.25),
            .slider("strength", "Strength", 0...48, default: 18, unit: "px"),
        ],
        tags: ["depth", "focus", "defocus"])

    static let tiltShift = EffectDescriptor(
        id: "blur.tiltShift", name: "Tilt Shift", category: .blur,
        subtitle: "Sharp horizontal band, blurred edges.", icon: "rectangle.split.3x1",
        function: "fx_blur_tiltShift",
        parameters: [
            .slider("focusY", "Focus Y", 0...1, default: 0.5),
            .slider("bandWidth", "Band Width", 0.02...0.6, default: 0.18),
            .slider("strength", "Strength", 0...48, default: 18, unit: "px"),
        ],
        tags: ["miniature", "focus", "band"])
}
