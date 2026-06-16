import Foundation

/// Parameters every effect instance carries regardless of type. These are
/// applied generically by the renderer's compositing helper (`spectra_composite`
/// in `Common.metal`), so each effect gets strength/blend/opacity for free.
struct UniversalParameters: Codable, Hashable, Sendable {
    /// Overall effect intensity. Mixes processed output back toward the input.
    var strength: Double = 1.0
    /// Final opacity of the composited result.
    var opacity: Double = 1.0
    /// How much of the chosen blend mode to apply (0 = normal mix).
    var blendAmount: Double = 1.0
    /// Compositing operator between input and processed output.
    var blendMode: BlendMode = .normal

    static let `default` = UniversalParameters()
}
