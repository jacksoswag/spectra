import Foundation
import simd

/// Built-in glitch effects: digital corruption and signal failure. Each
/// descriptor's parameter order is the GPU slot order its Metal function reads
/// (see `Glitch.metal`).
enum GlitchEffects {
    static let all: [EffectDescriptor] = [
        datamosh, rgbSplit, scanCorruption, frameTearing, signalCorruption,
        digitalFailure, compression, bufferCorruption, bitCrush, macroblocking,
        frameRepeat, frameSkip, digitalRain,
    ]

    static let datamosh = EffectDescriptor(
        id: "glitch.datamosh", name: "Datamosh", category: .glitch,
        subtitle: "Blocky directional smear from corrupted motion.", icon: "square.grid.3x3.middle.filled",
        function: "fx_glitch_datamosh",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["smear", "motion", "video"], isAnimated: true, needsHistory: true)

    static let rgbSplit = EffectDescriptor(
        id: "glitch.rgbSplit", name: "RGB Split", category: .glitch,
        subtitle: "Offset color channels along an angle.", icon: "circle.hexagongrid",
        function: "fx_glitch_rgbSplit",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.35),
            .angle("angle", "Angle", default: 0),
        ],
        tags: ["chromatic", "aberration", "channels"])

    static let scanCorruption = EffectDescriptor(
        id: "glitch.scanCorruption", name: "Scan Corruption", category: .glitch,
        subtitle: "Random horizontal scanlines jump sideways.", icon: "line.3.horizontal",
        function: "fx_glitch_scanCorruption",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["scanline", "tape", "shift"], isAnimated: true)

    static let frameTearing = EffectDescriptor(
        id: "glitch.frameTearing", name: "Frame Tearing", category: .glitch,
        subtitle: "A moving horizontal tear seam offsets the frame.", icon: "rectangle.split.1x2",
        function: "fx_glitch_frameTearing",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["tear", "vsync", "desync"], isAnimated: true)

    static let signalCorruption = EffectDescriptor(
        id: "glitch.signalCorruption", name: "Signal Corruption", category: .glitch,
        subtitle: "Blocks of garbled and inverted color.", icon: "antenna.radiowaves.left.and.right.slash",
        function: "fx_glitch_signalCorruption",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["transmission", "packet", "noise"], isAnimated: true)

    static let digitalFailure = EffectDescriptor(
        id: "glitch.digitalFailure", name: "Digital Failure", category: .glitch,
        subtitle: "Dropouts, color blocks, and grain combined.", icon: "exclamationmark.triangle",
        function: "fx_glitch_digitalFailure",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["breakdown", "dropout", "corruption"], isAnimated: true)

    static let compression = EffectDescriptor(
        id: "glitch.compression", name: "Compression Glitch", category: .glitch,
        subtitle: "Macroblock displacement and bitrate crush.", icon: "square.grid.4x3.fill",
        function: "fx_glitch_compression",
        parameters: [
            .slider("blockiness", "Blockiness", 0...1, default: 0.5),
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["codec", "macroblock", "bitrate"], isAnimated: true)

    static let bufferCorruption = EffectDescriptor(
        id: "glitch.bufferCorruption", name: "Buffer Corruption", category: .glitch,
        subtitle: "Rows offset by a hashed stride error.", icon: "rectangle.3.group",
        function: "fx_glitch_bufferCorruption",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.5),
            .slider("speed", "Speed", 0...4, default: 1),
        ],
        tags: ["framebuffer", "stride", "rows"], isAnimated: true)

    static let bitCrush = EffectDescriptor(
        id: "glitch.bitCrush", name: "Bit Crush", category: .glitch,
        subtitle: "Reduce bit depth per channel.", icon: "square.stack.3d.down.right",
        function: "fx_glitch_bitCrush",
        parameters: [
            .slider("bits", "Bits", 1...8, default: 3, step: 1),
        ],
        tags: ["quantize", "depth", "lofi"])

    static let macroblocking = EffectDescriptor(
        id: "glitch.macroblocking", name: "Macroblocking", category: .glitch,
        subtitle: "Average blocks with occasional block errors.", icon: "squareshape.split.2x2",
        function: "fx_glitch_macroblocking",
        parameters: [
            .slider("blockSize", "Block Size", 4...64, default: 16, step: 1, unit: "px"),
            .slider("intensity", "Error Rate", 0...1, default: 0.4),
        ],
        tags: ["mosaic", "pixelate", "block"])

    static let frameRepeat = EffectDescriptor(
        id: "glitch.frameRepeat", name: "Frame Repeat", category: .glitch,
        subtitle: "Freeze to a time-quantized, stuttering hold.", icon: "arrow.triangle.2.circlepath",
        function: "fx_glitch_frameRepeat",
        parameters: [
            .slider("rate", "Rate", 1...30, default: 8, unit: "Hz"),
        ],
        tags: ["freeze", "stutter", "hold"], isAnimated: true, needsHistory: true)

    static let frameSkip = EffectDescriptor(
        id: "glitch.frameSkip", name: "Frame Skip", category: .glitch,
        subtitle: "Periodic jump and channel flash.", icon: "forward.frame",
        function: "fx_glitch_frameSkip",
        parameters: [
            .slider("rate", "Rate", 1...30, default: 6, unit: "Hz"),
            .slider("intensity", "Intensity", 0...1, default: 0.5),
        ],
        tags: ["skip", "drop", "jump"], isAnimated: true, needsHistory: true)

    // Parameter order is load-bearing: intensity → density → speed maps 1:1 to
    // u.params[0..2] in fx_glitch_digitalRain. Purely time-based, so no history.
    static let digitalRain = EffectDescriptor(
        id: "glitch.digitalRain", name: "Digital Rain", category: .glitch,
        subtitle: "Matrix-style falling phosphor-green code.", icon: "character.cursor.ibeam",
        function: "fx_glitch_digitalRain",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.7),
            .slider("density", "Density", 0...1, default: 0.5),
            .slider("speed", "Speed", 0.1...3, default: 1),
        ],
        tags: ["matrix", "code", "rain", "green"], isAnimated: true)
}
