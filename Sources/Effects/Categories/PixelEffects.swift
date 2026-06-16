import Foundation
import simd

/// Built-in pixel effects: pixelation, dithering, quantization, and retro-console
/// looks. Each descriptor's parameter order is the GPU slot order its Metal
/// function reads (see `Pixel.metal`).
enum PixelEffects {
    static let all: [EffectDescriptor] = [
        pixelate, pixelSort, dither, orderedDither, bayerDither, floydSteinberg,
        colorQuantize, retroResolution, gameBoy, ps1, n64, arcade,
    ]

    static let pixelate = EffectDescriptor(
        id: "pixel.pixelate", name: "Pixelation", category: .pixel,
        subtitle: "Snap the image to a coarse block grid.", icon: "squareshape.split.3x3",
        function: "fx_pixel_pixelate",
        parameters: [
            .slider("blockSize", "Block Size", 1...128, default: 12, step: 1, unit: "px"),
        ],
        tags: ["mosaic", "blocks", "grid"])

    static let pixelSort = EffectDescriptor(
        id: "pixel.sort", name: "Pixel Sort", category: .pixel,
        subtitle: "Smear bright pixels into glitchy runs.", icon: "arrow.left.and.right",
        function: "fx_pixel_sort",
        parameters: [
            .slider("threshold", "Threshold", 0...1, default: 0.55),
            .slider("length", "Length", 1...48, default: 18, step: 1, unit: "px"),
            .toggle("vertical", "Vertical", default: false),
        ],
        tags: ["sort", "glitch", "smear"])

    static let dither = EffectDescriptor(
        id: "pixel.dither", name: "Dithering", category: .pixel,
        subtitle: "Hashed noise dither before quantization.", icon: "circle.grid.3x3",
        function: "fx_pixel_dither",
        parameters: [
            .integer("levels", "Levels", 2...32, default: 4),
            .slider("strength", "Strength", 0...2, default: 1),
        ],
        tags: ["dither", "noise", "quantize"])

    static let orderedDither = EffectDescriptor(
        id: "pixel.orderedDither", name: "Ordered Dither", category: .pixel,
        subtitle: "Patterned ordered dither over a scalable grid.", icon: "square.grid.3x3.fill",
        function: "fx_pixel_ordered",
        parameters: [
            .integer("levels", "Levels", 2...32, default: 4),
            .slider("scale", "Scale", 1...8, default: 1, step: 1),
        ],
        tags: ["dither", "ordered", "pattern"])

    static let bayerDither = EffectDescriptor(
        id: "pixel.bayerDither", name: "Bayer Dither", category: .pixel,
        subtitle: "Classic 4×4 Bayer matrix dither.", icon: "square.grid.4x3.fill",
        function: "fx_pixel_bayer",
        parameters: [
            .integer("levels", "Levels", 2...32, default: 3),
        ],
        tags: ["dither", "bayer", "matrix"])

    static let floydSteinberg = EffectDescriptor(
        id: "pixel.floydSteinberg", name: "Floyd-Steinberg", category: .pixel,
        subtitle: "Error-diffusion dither approximation.", icon: "square.grid.3x3.topleft.filled",
        function: "fx_pixel_floyd",
        parameters: [
            .integer("levels", "Levels", 2...16, default: 3),
        ],
        tags: ["dither", "error diffusion", "floyd"])

    static let colorQuantize = EffectDescriptor(
        id: "pixel.colorQuantize", name: "Color Quantization", category: .pixel,
        subtitle: "Reduce the palette via per-channel rounding.", icon: "paintpalette",
        function: "fx_pixel_quantizeFx",
        parameters: [
            .integer("levels", "Levels", 2...64, default: 8),
        ],
        tags: ["quantize", "palette", "posterize"])

    static let retroResolution = EffectDescriptor(
        id: "pixel.retroResolution", name: "Retro Resolution", category: .pixel,
        subtitle: "Downsample to a low res, nearest upscale.", icon: "rectangle.compress.vertical",
        function: "fx_pixel_retroRes",
        parameters: [
            .slider("targetWidth", "Target Width", 16...640, default: 160, step: 1, unit: "px"),
        ],
        tags: ["downsample", "lowres", "retro"])

    static let gameBoy = EffectDescriptor(
        id: "pixel.gameBoy", name: "Game Boy", category: .pixel,
        subtitle: "4-shade DMG green palette at low res.", icon: "gamecontroller",
        function: "fx_pixel_gameboy",
        parameters: [
            .slider("strength", "Strength", 0...1, default: 1),
        ],
        tags: ["gameboy", "dmg", "green", "handheld"])

    static let ps1 = EffectDescriptor(
        id: "pixel.ps1", name: "PS1", category: .pixel,
        subtitle: "Vertex-snap jitter, dither, 16-bit color.", icon: "cube",
        function: "fx_pixel_ps1",
        parameters: [
            .slider("jitter", "Jitter", 0...1, default: 0.5),
            .slider("dither", "Dither", 0...1, default: 0.6),
            .integer("depth", "Color Depth", 2...32, default: 32),
        ],
        tags: ["ps1", "playstation", "jitter", "lowpoly"])

    static let n64 = EffectDescriptor(
        id: "pixel.n64", name: "Nintendo 64", category: .pixel,
        subtitle: "Characteristic soft, dithered N64 look.", icon: "n.square",
        function: "fx_pixel_n64",
        parameters: [
            .slider("blur", "Blur", 0...1, default: 0.5),
            .slider("dither", "Dither", 0...1, default: 0.5),
        ],
        tags: ["n64", "nintendo", "soft", "blur"])

    static let arcade = EffectDescriptor(
        id: "pixel.arcade", name: "Arcade", category: .pixel,
        subtitle: "Low-res CRT-arcade palette and scanlines.", icon: "gamecontroller.fill",
        function: "fx_pixel_arcade",
        parameters: [
            .slider("scanline", "Scanline", 0...1, default: 0.4),
            .slider("palette", "Palette", 0...1, default: 0.5),
        ],
        tags: ["arcade", "crt", "cabinet", "lowres"])
}
