import Foundation
import simd

/// Built-in retro / CRT and analog-television effects. Each descriptor's
/// parameter order is the GPU slot order its Metal function reads (see
/// `Retro.metal`).
enum RetroEffects {
    static let all: [EffectDescriptor] = [
        crt, crtAdvanced, scanlines, shadowMask, apertureGrille, curvature,
        bloom, phosphorGlow, compositeVideo, rfSignalLoss, colorBleed,
        ntsc, pal, analogTelevision,
    ]

    static let crt = EffectDescriptor(
        id: "retro.crt", name: "CRT", category: .retro,
        subtitle: "Classic tube: scanlines, mask, curvature.", icon: "tv",
        function: "fx_crt_crt",
        parameters: [
            .slider("scanline", "Scanline", 0...1, default: 0.35),
            .slider("mask", "Mask", 0...1, default: 0.4),
            .slider("curvature", "Curvature", 0...0.5, default: 0.12),
            .slider("brightness", "Brightness", 0.5...2, default: 1.25),
            .slider("linePressWarp", "Press Line Warp", 0...0.3, default: 0,
                    group: "Interaction", help: "Bend the scanlines toward the cursor while a button is held (MAOE §7.2)."),
            .slider("warpRadius", "Warp Radius", 0.05...0.5, default: 0.18, group: "Interaction"),
        ],
        tags: ["crt", "tube", "scanline"], consumesPointer: true)

    static let crtAdvanced = EffectDescriptor(
        id: "retro.crtAdvanced", name: "CRT Advanced", category: .retro,
        subtitle: "Richer tube with bloom and vignette.", icon: "tv.fill",
        function: "fx_crt_crtAdvanced",
        parameters: [
            .slider("scanline", "Scanline", 0...1, default: 0.35),
            .slider("maskStrength", "Mask Strength", 0...1, default: 0.45),
            .slider("curvature", "Curvature", 0...0.5, default: 0.14),
            .slider("bloom", "Bloom", 0...1, default: 0.4),
            .slider("vignette", "Vignette", 0...1, default: 0.5),
            .slider("linePressWarp", "Press Line Warp", 0...0.3, default: 0,
                    group: "Interaction", help: "Bend the scanlines toward the cursor while a button is held (MAOE §7.2)."),
            .slider("warpRadius", "Warp Radius", 0.05...0.5, default: 0.18, group: "Interaction"),
        ],
        tags: ["crt", "tube", "bloom", "vignette"], consumesPointer: true)

    static let scanlines = EffectDescriptor(
        id: "retro.scanlines", name: "Scanlines", category: .retro,
        subtitle: "Darken alternating horizontal lines.", icon: "lines.measurement.horizontal",
        function: "fx_crt_scanlines",
        parameters: [
            .slider("count", "Count", 80...1080, default: 480, step: 1),
            .slider("strength", "Strength", 0...1, default: 0.5),
            .slider("linePressWarp", "Press Line Warp", 0...0.3, default: 0,
                    group: "Interaction", help: "Bend the scanlines toward the cursor while a button is held (MAOE §7.2)."),
            .slider("warpRadius", "Warp Radius", 0.05...0.5, default: 0.18, group: "Interaction"),
        ],
        tags: ["scanline", "lines"], consumesPointer: true)

    static let shadowMask = EffectDescriptor(
        id: "retro.shadowMask", name: "Shadow Mask", category: .retro,
        subtitle: "RGB triad shadow mask.", icon: "circle.grid.3x3.fill",
        function: "fx_crt_shadowMaskFx",
        parameters: [
            .slider("strength", "Strength", 0...1, default: 0.5),
            .slider("scale", "Scale", 1...8, default: 3),
        ],
        tags: ["mask", "triad", "phosphor"])

    static let apertureGrille = EffectDescriptor(
        id: "retro.apertureGrille", name: "Aperture Grille", category: .retro,
        subtitle: "Vertical RGB phosphor stripes.", icon: "lines.measurement.vertical",
        function: "fx_crt_apertureGrilleFx",
        parameters: [
            .slider("strength", "Strength", 0...1, default: 0.5),
            .slider("scale", "Scale", 1...8, default: 3),
        ],
        tags: ["grille", "trinitron", "stripes"])

    static let curvature = EffectDescriptor(
        id: "retro.curvature", name: "Curvature", category: .retro,
        subtitle: "Barrel warp with edge vignette.", icon: "rectangle.dashed",
        function: "fx_crt_curvature",
        parameters: [
            .slider("amount", "Amount", 0...0.6, default: 0.2),
        ],
        tags: ["curve", "barrel", "warp"])

    static let bloom = EffectDescriptor(
        id: "retro.bloom", name: "CRT Bloom", category: .retro,
        subtitle: "Glow from bright phosphor areas.", icon: "sparkles",
        parameters: [
            .slider("threshold", "Threshold", 0...1, default: 0.6),
            .slider("intensity", "Intensity", 0...2, default: 0.6),
        ],
        // Separable: horizontal thresholded blur then vertical blur (7+7 taps),
        // replacing the old single-pass 7×7 = 49-tap gather.
        passes: [
            EffectPass("fx_crt_bloom_h", direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_crt_bloom_v", direction: SIMD2<Float>(0, 1)),
        ],
        tags: ["bloom", "glow"])

    static let phosphorGlow = EffectDescriptor(
        id: "retro.phosphorGlow", name: "Phosphor Glow", category: .retro,
        subtitle: "Soft phosphor smear and persistence.", icon: "rays",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("persistence", "Persistence", 0...1, default: 0.5),
        ],
        // Half-res smear pyramid: box downsample → half-res H blur+seed → half-res V blur →
        // full-res composite/upsample (which also does the history feedback). Keeping the blurs
        // at half res is cheaper than folding the V blur into the full-res upsample.
        passes: [
            EffectPass("fx_blur_downsample", scale: 0.5),
            EffectPass("fx_crt_phosphor_h", scale: 0.5, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_crt_phosphor_v", scale: 0.5, direction: SIMD2<Float>(0, 1)),
            EffectPass("fx_crt_phosphor_up"),
        ],
        tags: ["phosphor", "glow", "smear"], isAnimated: true, needsHistory: true)

    static let compositeVideo = EffectDescriptor(
        id: "retro.compositeVideo", name: "Composite Video", category: .retro,
        subtitle: "Luma/chroma crosstalk via YIQ.", icon: "cable.connector",
        function: "fx_crt_composite",
        parameters: [
            .slider("artifacts", "Artifacts", 0...1, default: 0.4),
            .slider("bleed", "Bleed", 0...1, default: 0.5),
        ],
        tags: ["composite", "yiq", "video"])

    static let rfSignalLoss = EffectDescriptor(
        id: "retro.rfSignalLoss", name: "RF Signal Loss", category: .retro,
        subtitle: "Animated static and sync tearing.", icon: "antenna.radiowaves.left.and.right",
        function: "fx_crt_rfLoss",
        parameters: [
            .slider("noise", "Noise", 0...1, default: 0.4),
            .slider("dropout", "Dropout", 0...1, default: 0.3),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["rf", "static", "signal", "noise"],
        isAnimated: true)

    static let colorBleed = EffectDescriptor(
        id: "retro.colorBleed", name: "Color Bleed", category: .retro,
        subtitle: "Horizontal chroma smear.", icon: "drop.triangle",
        function: "fx_crt_colorBleed",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.5),
        ],
        tags: ["bleed", "chroma", "smear"])

    static let ntsc = EffectDescriptor(
        id: "retro.ntsc", name: "NTSC", category: .retro,
        subtitle: "YIQ bandlimited NTSC look.", icon: "tv.badge.wifi",
        function: "fx_crt_ntsc",
        parameters: [
            .slider("artifacts", "Artifacts", 0...1, default: 0.4),
            .slider("fringing", "Fringing", 0...1, default: 0.4),
        ],
        tags: ["ntsc", "yiq", "broadcast"])

    static let pal = EffectDescriptor(
        id: "retro.pal", name: "PAL", category: .retro,
        subtitle: "Softer PAL broadcast look.", icon: "tv.badge.wifi",
        function: "fx_crt_pal",
        parameters: [
            .slider("artifacts", "Artifacts", 0...1, default: 0.3),
            .slider("softness", "Softness", 0...1, default: 0.5),
        ],
        tags: ["pal", "yiq", "broadcast"])

    static let analogTelevision = EffectDescriptor(
        id: "retro.analogTelevision", name: "Analog Television", category: .retro,
        subtitle: "Full set: scanlines, mask, bleed, noise.", icon: "tv.and.hifispeaker.fill",
        function: "fx_crt_analogTV",
        parameters: [
            .slider("scanline", "Scanline", 0...1, default: 0.3),
            .slider("mask", "Mask", 0...1, default: 0.35),
            .slider("bleed", "Bleed", 0...1, default: 0.4),
            .slider("vignette", "Vignette", 0...1, default: 0.45),
            .slider("noise", "Noise", 0...1, default: 0.25),
            .slider("linePressWarp", "Press Line Warp", 0...0.3, default: 0,
                    group: "Interaction", help: "Bend the scanlines toward the cursor while a button is held (MAOE §7.2)."),
            .slider("warpRadius", "Warp Radius", 0.05...0.5, default: 0.18, group: "Interaction"),
        ],
        tags: ["analog", "television", "vintage"],
        isAnimated: true, consumesPointer: true)
}
