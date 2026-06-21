import Foundation

/// Aggregates the non-color built-in categories. The per-category providers
/// (`SharpenEffects`, `BlurEffects`, …) live in `Effects/Categories/` with their
/// matching Metal shaders in `Shaders/`. This aggregator is updated to include
/// each category once it is added.
enum AdditionalEffects {
    static var all: [EffectDescriptor] {
        var all: [EffectDescriptor] = []
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
