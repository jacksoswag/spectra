import Foundation
import simd

/// Built-in color grading effects. Each descriptor's parameter order is the GPU
/// slot order its Metal function reads (see `Color.metal`).
enum ColorEffects {
    static let all: [EffectDescriptor] = [
        brightness, contrast, saturation, vibrance, exposure, gamma,
        highlights, shadows, whites, blacks, blackPoint, whitePoint,
        temperature, tint, sepia, invert, posterize, solarize,
        colorBalance, levels, hueShift, channelMixer, toneCurve,
        curves, lut, gradientMap,
    ]

    static let brightness = EffectDescriptor(
        id: "color.brightness", name: "Brightness", category: .color,
        subtitle: "Lift or lower overall luminance.", icon: "sun.max",
        function: "fx_brightness",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)],
        tags: ["exposure", "light"])

    static let contrast = EffectDescriptor(
        id: "color.contrast", name: "Contrast", category: .color,
        subtitle: "Expand or compress tonal range.", icon: "circle.lefthalf.filled",
        function: "fx_contrast",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)],
        tags: ["tone"])

    static let saturation = EffectDescriptor(
        id: "color.saturation", name: "Saturation", category: .color,
        subtitle: "Intensify or mute all colors.", icon: "drop.halffull",
        function: "fx_saturation",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)])

    static let vibrance = EffectDescriptor(
        id: "color.vibrance", name: "Vibrance", category: .color,
        subtitle: "Boost muted colors, protect skin tones.", icon: "drop.fill",
        function: "fx_vibrance",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)])

    static let exposure = EffectDescriptor(
        id: "color.exposure", name: "Exposure", category: .color,
        subtitle: "Adjust in photographic stops.", icon: "camera.aperture",
        function: "fx_exposure",
        parameters: [.slider("stops", "Stops", -3...3, default: 0, unit: "EV")])

    static let gamma = EffectDescriptor(
        id: "color.gamma", name: "Gamma", category: .color,
        subtitle: "Non-linear midtone response.", icon: "function",
        function: "fx_gamma",
        parameters: [.slider("gamma", "Gamma", 0.1...3, default: 1)])

    static let highlights = EffectDescriptor(
        id: "color.highlights", name: "Highlights", category: .color,
        subtitle: "Recover or push bright tones.", icon: "sun.max.fill",
        function: "fx_highlights",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)])

    static let shadows = EffectDescriptor(
        id: "color.shadows", name: "Shadows", category: .color,
        subtitle: "Lift or deepen dark tones.", icon: "moon.fill",
        function: "fx_shadows",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)])

    static let whites = EffectDescriptor(
        id: "color.whites", name: "Whites", category: .color,
        subtitle: "Set the upper tonal anchor.", icon: "square.fill",
        function: "fx_whites",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)])

    static let blacks = EffectDescriptor(
        id: "color.blacks", name: "Blacks", category: .color,
        subtitle: "Set the lower tonal anchor.", icon: "square",
        function: "fx_blacks",
        parameters: [.slider("amount", "Amount", -1...1, default: 0)])

    static let blackPoint = EffectDescriptor(
        id: "color.blackPoint", name: "Black Point", category: .color,
        subtitle: "Remap the darkest input value.", icon: "circle.fill",
        function: "fx_blackPoint",
        parameters: [.slider("point", "Black Point", 0...0.5, default: 0)])

    static let whitePoint = EffectDescriptor(
        id: "color.whitePoint", name: "White Point", category: .color,
        subtitle: "Remap the brightest input value.", icon: "circle",
        function: "fx_whitePoint",
        parameters: [.slider("point", "White Point", 0.5...1, default: 1)])

    static let temperature = EffectDescriptor(
        id: "color.temperature", name: "Temperature", category: .color,
        subtitle: "Warm/cool color balance.", icon: "thermometer.medium",
        function: "fx_temperature",
        parameters: [.slider("amount", "Temperature", -1...1, default: 0)])

    static let tint = EffectDescriptor(
        id: "color.tint", name: "Tint", category: .color,
        subtitle: "Green/magenta color balance.", icon: "eyedropper",
        function: "fx_tint",
        parameters: [.slider("amount", "Tint", -1...1, default: 0)])

    static let sepia = EffectDescriptor(
        id: "color.sepia", name: "Sepia", category: .color,
        subtitle: "Classic warm monochrome.", icon: "photo",
        function: "fx_sepia",
        parameters: [.slider("amount", "Amount", 0...1, default: 1)])

    static let invert = EffectDescriptor(
        id: "color.invert", name: "Invert", category: .color,
        subtitle: "Photographic negative.", icon: "circle.righthalf.filled",
        function: "fx_invert",
        parameters: [.slider("amount", "Amount", 0...1, default: 1)])

    static let posterize = EffectDescriptor(
        id: "color.posterize", name: "Posterize", category: .color,
        subtitle: "Quantize each channel into bands.", icon: "square.stack.3d.up",
        function: "fx_posterize",
        parameters: [.integer("levels", "Levels", 2...32, default: 6)])

    static let solarize = EffectDescriptor(
        id: "color.solarize", name: "Solarize", category: .color,
        subtitle: "Invert tones above a threshold.", icon: "sun.haze",
        function: "fx_solarize",
        parameters: [.slider("threshold", "Threshold", 0...1, default: 0.5)])

    static let colorBalance = EffectDescriptor(
        id: "color.colorBalance", name: "Color Balance", category: .color,
        subtitle: "Shift color across shadows, midtones, and highlights.", icon: "slider.horizontal.3",
        function: "fx_colorBalance",
        parameters: [
            .slider("cyanRed", "Cyan ⟷ Red", -1...1, default: 0, group: "Midtones"),
            .slider("magentaGreen", "Magenta ⟷ Green", -1...1, default: 0, group: "Midtones"),
            .slider("yellowBlue", "Yellow ⟷ Blue", -1...1, default: 0, group: "Midtones"),
            .slider("shadowCyanRed", "Cyan ⟷ Red", -1...1, default: 0, group: "Shadows"),
            .slider("shadowMagentaGreen", "Magenta ⟷ Green", -1...1, default: 0, group: "Shadows"),
            .slider("shadowYellowBlue", "Yellow ⟷ Blue", -1...1, default: 0, group: "Shadows"),
            .slider("highCyanRed", "Cyan ⟷ Red", -1...1, default: 0, group: "Highlights"),
            .slider("highMagentaGreen", "Magenta ⟷ Green", -1...1, default: 0, group: "Highlights"),
            .slider("highYellowBlue", "Yellow ⟷ Blue", -1...1, default: 0, group: "Highlights"),
        ])

    static let levels = EffectDescriptor(
        id: "color.levels", name: "Levels", category: .color,
        subtitle: "Input/output remapping with gamma.", icon: "chart.bar",
        function: "fx_levels",
        parameters: [
            .slider("inBlack", "Input Black", 0...1, default: 0, group: "Input"),
            .slider("inWhite", "Input White", 0...1, default: 1, group: "Input"),
            .slider("gamma", "Gamma", 0.1...3, default: 1, group: "Input"),
            .slider("outBlack", "Output Black", 0...1, default: 0, group: "Output"),
            .slider("outWhite", "Output White", 0...1, default: 1, group: "Output"),
        ])

    static let hueShift = EffectDescriptor(
        id: "color.hueShift", name: "Hue Shift", category: .color,
        subtitle: "Rotate all hues.", icon: "paintbrush",
        function: "fx_hueShift",
        parameters: [.angle("degrees", "Hue Rotation", default: 0)])

    static let channelMixer = EffectDescriptor(
        id: "color.channelMixer", name: "Channel Mixer", category: .color,
        subtitle: "Per-output 3×3 channel matrix.", icon: "square.grid.3x3",
        function: "fx_channelMixer",
        parameters: [
            .slider("rr", "Red ← Red", -2...2, default: 1, group: "Red Output"),
            .slider("rg", "Red ← Green", -2...2, default: 0, group: "Red Output"),
            .slider("rb", "Red ← Blue", -2...2, default: 0, group: "Red Output"),
            .slider("gr", "Green ← Red", -2...2, default: 0, group: "Green Output"),
            .slider("gg", "Green ← Green", -2...2, default: 1, group: "Green Output"),
            .slider("gb", "Green ← Blue", -2...2, default: 0, group: "Green Output"),
            .slider("br", "Blue ← Red", -2...2, default: 0, group: "Blue Output"),
            .slider("bg", "Blue ← Green", -2...2, default: 0, group: "Blue Output"),
            .slider("bb", "Blue ← Blue", -2...2, default: 1, group: "Blue Output"),
        ])

    static let toneCurve = EffectDescriptor(
        id: "color.toneCurve", name: "Tone Curve", category: .color,
        subtitle: "Lift / gamma / gain with contrast.", icon: "point.topleft.down.curvedto.point.bottomright.up",
        function: "fx_toneCurve",
        parameters: [
            .slider("lift", "Lift", -0.5...0.5, default: 0),
            .slider("gamma", "Gamma", 0.1...3, default: 1),
            .slider("gain", "Gain", 0.25...2.5, default: 1),
            .slider("contrast", "Contrast", -1...1, default: 0),
        ])

    static let curves = EffectDescriptor(
        id: "color.curves", name: "Curves", category: .color,
        subtitle: "Freehand RGB tone curve.", icon: "point.topleft.down.curvedto.point.bottomright.up.fill",
        function: "fx_color_curves",
        parameters: [
            .curve("curve", "Tone Curve", help: "Drag points; double-click to remove, tap to add."),
        ],
        tags: ["curve", "tone", "grade"])

    static let lut = EffectDescriptor(
        id: "color.lut", name: "LUT", category: .color,
        subtitle: "Apply a color lookup table.", icon: "cube.transparent",
        function: "fx_color_lut",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 1),
            .lut("lut", "Look", LUTLooks.names, default: "Teal & Orange"),
        ],
        tags: ["lut", "look", "grade", "cube"])

    static let gradientMap = EffectDescriptor(
        id: "color.gradientMap", name: "Gradient Map", category: .color,
        subtitle: "Map luminance through a gradient.", icon: "circle.lefthalf.filled",
        function: "fx_color_gradientMap",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 1),
            .gradient("gradient", "Gradient", default: [
                GradientStop(position: 0, color: SIMD4(0.05, 0.02, 0.2, 1)),
                GradientStop(position: 0.5, color: SIMD4(0.8, 0.3, 0.2, 1)),
                GradientStop(position: 1, color: SIMD4(1.0, 0.95, 0.7, 1)),
            ]),
        ],
        tags: ["gradient", "map", "duotone", "grade"])
}
