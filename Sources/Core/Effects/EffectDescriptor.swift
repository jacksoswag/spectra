import Foundation
import simd

/// Identifies a *system effect*'s runtime controller. A descriptor carrying a
/// `controllerKind` performs a side effect when its stack row is effectively
/// enabled (driving yabai window opacity/tiling, or managing the adaptive tint
/// overlay) instead of running a Metal pass. The resolver drops these from the
/// render chain; `SpectraEngine` reconciles them through `SystemEffectsController`.
enum EffectControllerKind: String, Codable, Hashable, Sendable {
    case windowTransparency
    case windowLayout
    case adaptiveTint
}

/// A single GPU pass within an effect.
///
/// Most effects are one pass. Separable or iterative effects (e.g. Gaussian
/// blur) declare multiple passes; the renderer ping-pongs intermediate textures
/// between them. The renderer always binds the pass's sampling source on
/// `texture(0)` and the effect's *original* input on `texture(1)` so the final
/// pass can composite universal parameters against the unmodified image.
struct EffectPass: Hashable, Sendable {
    /// Name of the Metal fragment (or, when `isCompute`, kernel) function backing this pass.
    let fragmentFunction: String
    /// Render-target size relative to the chain resolution (1 = full res).
    var scale: Float
    /// Direction vector supplied to the shader (separable/directional passes).
    var direction: SIMD2<Float>
    /// When true this pass is a compute kernel: the renderer dispatches it over the
    /// target with the source bound at texture(0), the effect input at texture(1),
    /// aux at 2+, history at 10, and the writable output at texture(11).
    var isCompute: Bool
    /// When set, the pass's render-target scale is read from this parameter slot
    /// (clamped to 0.4...1.0) instead of `scale`, so a "Render Scale" slider can trade
    /// quality for speed at runtime. `scale` is the fallback when the slot reads ~0.
    var scaleParam: Int?
    /// When set, the output of the earlier pass at this index is bound at texture(9) for
    /// this pass (in addition to src/orig). The renderer keeps that earlier output alive
    /// instead of recycling it. Lets a late pass reuse an intermediate result (e.g. the oil
    /// combine reusing the smoothed structure tensor) rather than recomputing it.
    var tapPass: Int?

    init(_ fragmentFunction: String, scale: Float = 1.0, direction: SIMD2<Float> = .zero,
         isCompute: Bool = false, scaleParam: Int? = nil, tapPass: Int? = nil) {
        self.fragmentFunction = fragmentFunction
        self.scale = scale
        self.direction = direction
        self.isCompute = isCompute
        self.scaleParam = scaleParam
        self.tapPass = tapPass
    }
}

/// Immutable definition of an effect: its identity, editable parameters, and the
/// GPU passes that realise it. Descriptors are produced in code (built-in
/// library) or at runtime (imported/authored custom effects) and resolved by
/// `id` from the `EffectRegistry`.
struct EffectDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: EffectCategory
    let subtitle: String
    let iconSystemName: String
    let parameters: [EffectParameter]
    let passes: [EffectPass]
    let tags: [String]
    let isCustom: Bool
    /// True if the effect varies over time (animated noise, jitter, flicker) and
    /// therefore needs continuous redraw even when the source is static.
    let isAnimated: Bool
    /// True if the effect samples the previous frame's processed output (bound at
    /// fragment texture 10), e.g. feedback trails, datamosh, frame hold.
    let needsHistory: Bool
    /// When set, the effect only counts as animated (forcing idle redraws) while this
    /// parameter reads > 0 — e.g. film.grain "speed" at 0 is a static pattern that should
    /// not keep the chain re-rendering on an idle desktop.
    let animatedParam: String?
    /// When non-nil this is a *system effect*: it drives a side-effecting controller
    /// (window transparency, tiling, the adaptive tint overlay) when effectively
    /// enabled, and carries no GPU `passes`. The resolver excludes it from the render
    /// chain; the engine reconciles it through `SystemEffectsController`.
    let controllerKind: EffectControllerKind?

    init(
        id: String,
        name: String,
        category: EffectCategory,
        subtitle: String = "",
        icon: String? = nil,
        parameters: [EffectParameter] = [],
        passes: [EffectPass],
        tags: [String] = [],
        isCustom: Bool = false,
        isAnimated: Bool = false,
        needsHistory: Bool = false,
        animatedParam: String? = nil,
        controllerKind: EffectControllerKind? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.subtitle = subtitle
        self.iconSystemName = icon ?? category.iconSystemName
        self.parameters = parameters
        self.passes = passes
        self.tags = tags
        self.isCustom = isCustom
        self.isAnimated = isAnimated
        self.needsHistory = needsHistory
        self.animatedParam = animatedParam
        self.controllerKind = controllerKind
    }

    /// Whether this descriptor is a system effect (drives a controller, not a GPU pass).
    var isSystemEffect: Bool { controllerKind != nil }

    /// Convenience for the common single-pass effect.
    init(
        id: String,
        name: String,
        category: EffectCategory,
        subtitle: String = "",
        icon: String? = nil,
        function: String,
        parameters: [EffectParameter] = [],
        tags: [String] = [],
        isCustom: Bool = false,
        isAnimated: Bool = false,
        needsHistory: Bool = false,
        animatedParam: String? = nil
    ) {
        self.init(
            id: id, name: name, category: category, subtitle: subtitle, icon: icon,
            parameters: parameters, passes: [EffectPass(function)],
            tags: tags, isCustom: isCustom, isAnimated: isAnimated, needsHistory: needsHistory,
            animatedParam: animatedParam
        )
    }

    /// Base index into the GPU `params[]` array for a given parameter, derived
    /// from declaration order and each parameter's component count.
    func slot(for parameterID: String) -> Int {
        var offset = 0
        for parameter in parameters {
            if parameter.id == parameterID { return offset }
            offset += parameter.componentCount
        }
        return offset
    }

    /// Total number of GPU float slots consumed by this effect's parameters.
    var totalSlots: Int {
        parameters.reduce(0) { $0 + $1.componentCount }
    }

    /// Default value map for a fresh instance.
    func defaultValues() -> [String: ParameterValue] {
        var values: [String: ParameterValue] = [:]
        for parameter in parameters {
            values[parameter.id] = parameter.defaultValue
        }
        return values
    }

    static func == (lhs: EffectDescriptor, rhs: EffectDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
