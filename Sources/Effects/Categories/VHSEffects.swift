import Foundation
import simd

/// Built-in VHS tape effects. Each descriptor's parameter order is the GPU slot
/// order its Metal function reads (see `VHS.metal`).
enum VHSEffects {
    static let all: [EffectDescriptor] = [
        tracking, wrinkle, dropouts, chromaDrift, headSwitch, jitter,
        roll, noiseBands, damage, generationLoss, colorSmear, audioTracking,
    ]

    static let tracking = EffectDescriptor(
        id: "vhs.tracking", name: "Tracking Errors", category: .vhs,
        subtitle: "Horizontal band displacement drifting vertically.",
        icon: "wave.3.right",
        function: "fx_vhs_tracking",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...2, default: 0.6),
            .slider("linePressWarp", "Press Line Warp", 0...0.3, default: 0,
                    group: "Interaction", help: "Pull the tracking bands toward the cursor while a button is held (MAOE §7.2)."),
            .slider("warpRadius", "Warp Radius", 0.02...0.5, default: 0.2, group: "Interaction"),
        ],
        tags: ["tracking", "glitch", "tape"],
        isAnimated: true, consumesPointer: true)

    static let wrinkle = EffectDescriptor(
        id: "vhs.wrinkle", name: "Tape Wrinkle", category: .vhs,
        subtitle: "A warped, creased horizontal band.",
        icon: "scribble.variable",
        function: "fx_vhs_wrinkle",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("position", "Position", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...3, default: 1.0),
        ],
        tags: ["wrinkle", "warp", "tape"],
        isAnimated: true)

    static let dropouts = EffectDescriptor(
        id: "vhs.dropouts", name: "Dropouts", category: .vhs,
        subtitle: "White and black streak dropouts.",
        icon: "bolt.horizontal",
        function: "fx_vhs_dropouts",
        parameters: [
            .slider("density", "Density", 0...1, default: 0.4),
            .slider("speed", "Speed", 0...3, default: 1.0),
        ],
        tags: ["dropout", "streak", "glitch"],
        isAnimated: true)

    static let chromaDrift = EffectDescriptor(
        id: "vhs.chromaDrift", name: "Chromatic Drift", category: .vhs,
        subtitle: "Chroma offset horizontally from luma.",
        icon: "camera.filters",
        function: "fx_vhs_chromaDrift",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.5),
        ],
        tags: ["chroma", "color", "bleed"])

    static let headSwitch = EffectDescriptor(
        id: "vhs.headSwitch", name: "Head Switching Noise", category: .vhs,
        subtitle: "Torn, noisy strip along the bottom.",
        icon: "rectangle.bottomthird.inset.filled",
        function: "fx_vhs_headSwitch",
        parameters: [
            .slider("height", "Height", 0...0.3, default: 0.08),
            .slider("intensity", "Intensity", 0...1, default: 0.7),
        ],
        tags: ["head", "noise", "tear"],
        isAnimated: true)

    static let jitter = EffectDescriptor(
        id: "vhs.jitter", name: "Horizontal Jitter", category: .vhs,
        subtitle: "Per-line horizontal shake.",
        icon: "arrow.left.and.right",
        function: "fx_vhs_jitter",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.4),
            .slider("speed", "Speed", 0...3, default: 1.0),
        ],
        tags: ["jitter", "shake", "instability"],
        isAnimated: true)

    static let roll = EffectDescriptor(
        id: "vhs.roll", name: "Vertical Roll", category: .vhs,
        subtitle: "Image rolls vertically with a hold tear.",
        icon: "arrow.up.arrow.down",
        function: "fx_vhs_roll",
        parameters: [
            .slider("speed", "Speed", -2...2, default: 0.5),
        ],
        tags: ["roll", "vertical hold", "scroll"],
        isAnimated: true)

    static let noiseBands = EffectDescriptor(
        id: "vhs.noiseBands", name: "Noise Bands", category: .vhs,
        subtitle: "Moving noisy horizontal bands.",
        icon: "lines.measurement.horizontal",
        function: "fx_vhs_noiseBands",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.6),
            .slider("count", "Count", 1...12, default: 4, step: 1),
            .slider("speed", "Speed", 0...3, default: 0.8),
        ],
        tags: ["noise", "bands", "interference"],
        isAnimated: true)

    static let damage = EffectDescriptor(
        id: "vhs.damage", name: "Tape Damage", category: .vhs,
        subtitle: "Combined dropouts, tears and noise.",
        icon: "exclamationmark.triangle",
        function: "fx_vhs_damage",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...3, default: 1.0),
        ],
        tags: ["damage", "decay", "glitch"],
        isAnimated: true)

    static let generationLoss = EffectDescriptor(
        id: "vhs.generationLoss", name: "Generation Loss", category: .vhs,
        subtitle: "Softening, chroma bleed, noise and desaturation.",
        icon: "square.stack.3d.down.right",
        function: "fx_vhs_genLoss",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.6),
        ],
        tags: ["generation", "dub", "degrade"])

    static let colorSmear = EffectDescriptor(
        id: "vhs.colorSmear", name: "Color Smear", category: .vhs,
        subtitle: "Horizontal chroma lag and smear.",
        icon: "paintbrush.pointed",
        function: "fx_vhs_smear",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.5),
        ],
        tags: ["smear", "chroma", "lag"])

    static let audioTracking = EffectDescriptor(
        id: "vhs.audioTracking", name: "Audio-Reactive Tracking", category: .vhs,
        subtitle: "Tracking error pulsing with a synthesized envelope.",
        icon: "waveform",
        function: "fx_vhs_audioTracking",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...2, default: 1.0),
        ],
        tags: ["audio", "reactive", "tracking"],
        isAnimated: true)
}
