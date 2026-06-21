import Foundation

/// Aggregates every built-in effect category into the full library. Each category
/// provides its descriptors as a static array; this is the single place that knows
/// the complete set. The per-category providers (`ColorEffects`, `SharpenEffects`, …)
/// live in `Effects/Categories/` with their matching Metal shaders in `Shaders/`.
enum BuiltInEffects {
    static func all() -> [EffectDescriptor] {
        var all: [EffectDescriptor] = []
        all += ColorEffects.all
        all += SharpenEffects.all
        all += BlurEffects.all
        all += DistortionEffects.all
        all += RetroEffects.all
        all += VHSEffects.all
        all += CamcorderEffects.all
        all += FilmEffects.all
        all += NoiseEffects.all
        all += PixelEffects.all
        all += GlitchEffects.all
        all += EnvironmentEffects.all
        all += StyleEffects.all
        all += SystemEffects.all
        return all
    }
}
