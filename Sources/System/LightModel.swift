import Foundation
import simd

/// A shared description of the world's light, so shadows and highlights agree across every
/// surface (menu bar, Dock, window chrome) — MAOE §9. Carried on `SystemEffectsState` and read
/// by every system-UI overlay; also feeds the directional-shadow chrome passes.
struct LightModel: Codable, Sendable, Hashable {
    /// Light direction in degrees (0 = from the right, 90 = from below, 210 = Golden Hour).
    var angle: Double
    /// Overall light strength (0…1).
    var intensity: Double
    /// Light colour (RGBA, premultiplied alpha not assumed).
    var color: SIMD4<Double>
    /// Softness of the cast shadow / highlight falloff (0 = hard, 1 = very soft).
    var spread: Double

    init(angle: Double = 210, intensity: Double = 1,
         color: SIMD4<Double> = SIMD4(1, 1, 1, 1), spread: Double = 0.5) {
        self.angle = angle
        self.intensity = intensity
        self.color = color
        self.spread = spread
    }

    /// Unit direction the light travels (toward), in top-left UV space.
    var directionUV: SIMD2<Double> {
        let r = angle * .pi / 180
        return SIMD2(cos(r), sin(r))
    }
}
