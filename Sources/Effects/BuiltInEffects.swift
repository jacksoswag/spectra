import Foundation

/// Aggregates every built-in effect category into the full library. Each category
/// provides its descriptors as a static array; this is the single place that knows
/// the complete set. The per-category providers (`ColorEffects`, `SharpenEffects`, …)
/// live in `Effects/Categories/` with their matching Metal shaders in `Shaders/`.
enum BuiltInEffects {
    static func all() -> [EffectDescriptor] {
        // A flat list of each category's arrays, joined once. A long `+` chain trips Swift's
        // expression type-checker ("unable to type-check in reasonable time"), so flatMap a
        // homogeneous array literal instead.
        [ColorEffects.all, SharpenEffects.all, BlurEffects.all, DistortionEffects.all,
         RetroEffects.all, VHSEffects.all, CamcorderEffects.all, FilmEffects.all,
         NoiseEffects.all, PixelEffects.all, GlitchEffects.all, EnvironmentEffects.all,
         StyleEffects.all, InteractionEffects.all, CursorEffects.all,
         WindowChromeEffects.all, SystemEffects.all].flatMap { $0 }
    }
}
