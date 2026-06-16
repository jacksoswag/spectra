import Foundation
import simd

/// Built-in procedural noise effects. Every descriptor shares the same parameter
/// layout — intensity, scale, speed, colorize — which is the GPU slot order its
/// Metal function reads (see `Noise.metal`):
///   params[0] = intensity, params[1] = scale, params[2] = speed, params[3] = colorize.
/// All effects animate via `u.time * speed` and use `u.seed` for per-instance
/// variety, so each is marked `isAnimated: true`.
enum NoiseEffects {
    static let all: [EffectDescriptor] = [
        white, gaussian, blue, pink, brown, perlin, simplex, cellular,
        filmGrain, sensor, compression, dust, speckle, digital,
    ]

    /// Shared parameter set in GPU declaration order. `colorize` blends between
    /// monochrome noise and decorrelated per-channel noise.
    private static func params(
        intensity: Double = 0.5,
        scale: Double = 8,
        speed: Double = 1,
        colorize: Double = 0
    ) -> [EffectParameter] {
        [
            .slider("intensity", "Intensity", 0...1, default: intensity),
            .slider("scale", "Scale", 0.1...64, default: scale),
            .slider("speed", "Animation Speed", 0...5, default: speed, unit: "×"),
            .slider("colorize", "Colorize", 0...1, default: colorize),
        ]
    }

    static let white = EffectDescriptor(
        id: "noise.white", name: "White Noise", category: .noise,
        subtitle: "Uniform additive static across the frame.", icon: "waveform.path",
        function: "fx_noise_white",
        parameters: params(intensity: 0.4, scale: 32, speed: 1),
        tags: ["static", "random", "grain"], isAnimated: true)

    static let gaussian = EffectDescriptor(
        id: "noise.gaussian", name: "Gaussian Noise", category: .noise,
        subtitle: "Normally distributed additive noise.", icon: "waveform.path.ecg",
        function: "fx_noise_gaussian",
        parameters: params(intensity: 0.4, scale: 32, speed: 1),
        tags: ["normal", "random", "grain"], isAnimated: true)

    static let blue = EffectDescriptor(
        id: "noise.blue", name: "Blue Noise", category: .noise,
        subtitle: "High-frequency noise with the lows removed.", icon: "waveform",
        function: "fx_noise_blue",
        parameters: params(intensity: 0.4, scale: 32, speed: 1),
        tags: ["dither", "high frequency"], isAnimated: true)

    static let pink = EffectDescriptor(
        id: "noise.pink", name: "Pink Noise", category: .noise,
        subtitle: "1/f noise summed from decaying octaves.", icon: "waveform.path",
        function: "fx_noise_pink",
        parameters: params(intensity: 0.4, scale: 6, speed: 0.5),
        tags: ["1/f", "natural", "fbm"], isAnimated: true)

    static let brown = EffectDescriptor(
        id: "noise.brown", name: "Brown Noise", category: .noise,
        subtitle: "Low-frequency drifting fbm clouds.", icon: "waveform.path.badge.minus",
        function: "fx_noise_brown",
        parameters: params(intensity: 0.4, scale: 4, speed: 0.4),
        tags: ["1/f²", "drift", "fbm"], isAnimated: true)

    static let perlin = EffectDescriptor(
        id: "noise.perlin", name: "Perlin Noise", category: .noise,
        subtitle: "Smooth gradient noise.", icon: "scribble.variable",
        function: "fx_noise_perlin",
        parameters: params(intensity: 0.4, scale: 6, speed: 0.5),
        tags: ["gradient", "smooth", "organic"], isAnimated: true)

    static let simplex = EffectDescriptor(
        id: "noise.simplex", name: "Simplex Noise", category: .noise,
        subtitle: "Isotropic simplex gradient noise.", icon: "scribble",
        function: "fx_noise_simplex",
        parameters: params(intensity: 0.4, scale: 6, speed: 0.5),
        tags: ["gradient", "smooth", "organic"], isAnimated: true)

    static let cellular = EffectDescriptor(
        id: "noise.cellular", name: "Cellular Noise", category: .noise,
        subtitle: "Worley F1 feature-distance cells.", icon: "circle.grid.cross",
        function: "fx_noise_cellular",
        parameters: params(intensity: 0.4, scale: 6, speed: 0.5),
        tags: ["worley", "voronoi", "cells"], isAnimated: true)

    static let filmGrain = EffectDescriptor(
        id: "noise.filmGrain", name: "Film Grain", category: .noise,
        subtitle: "Luma-weighted animated photographic grain.", icon: "film",
        function: "fx_noise_filmGrain",
        parameters: params(intensity: 0.5, scale: 40, speed: 1),
        tags: ["film", "grain", "analog"], isAnimated: true)

    static let sensor = EffectDescriptor(
        id: "noise.sensor", name: "Sensor Noise", category: .noise,
        subtitle: "Per-channel read noise with sparse hot pixels.", icon: "camera.metering.spot",
        function: "fx_noise_sensor",
        parameters: params(intensity: 0.4, scale: 48, speed: 1),
        tags: ["camera", "read noise", "hot pixels"], isAnimated: true)

    static let compression = EffectDescriptor(
        id: "noise.compression", name: "Compression Noise", category: .noise,
        subtitle: "8×8 blocky macroblock artifacts.", icon: "rectangle.split.3x3",
        function: "fx_noise_compression",
        parameters: params(intensity: 0.4, scale: 8, speed: 0.5),
        tags: ["jpeg", "blocks", "artifacts"], isAnimated: true)

    static let dust = EffectDescriptor(
        id: "noise.dust", name: "Dust Noise", category: .noise,
        subtitle: "Sparse bright specks of dust and dirt.", icon: "sparkles",
        function: "fx_noise_dust",
        parameters: params(intensity: 0.5, scale: 24, speed: 1),
        tags: ["dust", "specks", "analog"], isAnimated: true)

    static let speckle = EffectDescriptor(
        id: "noise.speckle", name: "Speckle", category: .noise,
        subtitle: "Multiplicative gain noise.", icon: "circle.dotted",
        function: "fx_noise_speckle",
        parameters: params(intensity: 0.4, scale: 16, speed: 1),
        tags: ["multiplicative", "speckle"], isAnimated: true)

    static let digital = EffectDescriptor(
        id: "noise.digital", name: "Digital Noise", category: .noise,
        subtitle: "Quantized bit-crushed random levels.", icon: "square.grid.3x3.fill",
        function: "fx_noise_digital",
        parameters: params(intensity: 0.4, scale: 24, speed: 1),
        tags: ["digital", "quantized", "glitch"], isAnimated: true)
}
