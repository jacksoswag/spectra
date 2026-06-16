import Foundation

/// Aggregates every built-in effect category into the full library. Each
/// category provides its descriptors as a static array; this is the single place
/// that knows the complete set.
enum BuiltInEffects {
    static func all() -> [EffectDescriptor] {
        var all: [EffectDescriptor] = []
        all += ColorEffects.all
        // Additional categories are appended here as they are added to the
        // library (Sharpen, Blur, Distortion, Retro, VHS, Camcorder, Film,
        // Noise, Pixel, Glitch, Environment, Accessibility).
        all += AdditionalEffects.all
        return all
    }
}
