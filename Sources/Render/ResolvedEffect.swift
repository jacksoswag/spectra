import Foundation
import Metal

/// An effect instance paired with its resolved descriptor and (for custom
/// effects) the runtime-compiled Metal library that hosts its functions. This is
/// the render-ready unit; the coordinator builds an array of these from an
/// `EffectChain` using the registry, so the renderer needs no registry access.
struct ResolvedEffect {
    let descriptor: EffectDescriptor
    let instance: EffectInstance
    let customLibrary: MTLLibrary?
    /// Optional auxiliary textures bound starting at fragment texture index 2
    /// (e.g. a baked tone curve, a 3D color LUT, or a dither matrix).
    let auxTextures: [MTLTexture]
    /// When set, this is a *fused* effect: a single `fx_color_fused` pass that
    /// applies a run of pointwise colour ops packed into this flat buffer (bound at
    /// fragment buffer index 1). nil for an ordinary effect.
    let fusedOps: [Float]?
    /// Pass indices that a later pass taps (must not be recycled mid-effect). Derived
    /// once here from the descriptor so the renderer doesn't rebuild this set per effect
    /// per frame on the link thread.
    let tappedIndices: Set<Int>

    init(
        descriptor: EffectDescriptor,
        instance: EffectInstance,
        customLibrary: MTLLibrary? = nil,
        auxTextures: [MTLTexture] = [],
        fusedOps: [Float]? = nil
    ) {
        self.descriptor = descriptor
        self.instance = instance
        self.customLibrary = customLibrary
        self.auxTextures = auxTextures
        self.fusedOps = fusedOps
        self.tappedIndices = Set(descriptor.passes.compactMap { $0.tapPass })
    }

    /// Opcode for this effect in `spectra_colorproc` (Color.metal), or nil.
    var fusionOpcode: Int? { ColorFusion.opcodes[descriptor.id] }

    /// Whether this effect can be folded into a fused colour pass: a known
    /// pointwise opcode, built-in (no custom library), no auxiliary textures, a
    /// single pass, and neither animated nor history-dependent.
    var isFusable: Bool {
        fusionOpcode != nil
            && customLibrary == nil
            && auxTextures.isEmpty
            && descriptor.passes.count == 1
            && !descriptor.isAnimated
            && !descriptor.needsHistory
    }

    /// Whether this instance actually animates (needs idle redraws). An effect can declare
    /// `isAnimated` but gate it on a parameter (`animatedParam`): e.g. film.grain at speed 0
    /// is a fixed pattern, so it should not keep the chain re-rendering on a static desktop.
    var isEffectivelyAnimated: Bool {
        guard descriptor.isAnimated else { return false }
        guard let gateID = descriptor.animatedParam else { return true }
        let value = instance.values[gateID] ?? descriptor.parameters.first { $0.id == gateID }?.defaultValue
        return (value?.floats.first ?? 1) > 0.0001
    }

    /// This instance's parameter values flattened into GPU float order (declaration
    /// order, each parameter contributing its component count) — the same packing
    /// `writeParameters` does into `u.params`.
    func parameterFloats() -> [Float] {
        var floats: [Float] = []
        for parameter in descriptor.parameters {
            let value = instance.values[parameter.id] ?? parameter.defaultValue
            floats.append(contentsOf: value.floats)
        }
        return floats
    }

    /// Collapse a run of fusable effects into one synthetic fused effect carrying a
    /// packed op buffer. Layout mirrors `FusedColorOps` in Color.metal:
    /// `[count, (opcode, strength, opacity, blendAmount, blendMode, params[9], pad×2)…]`.
    static func fused(_ group: [ResolvedEffect]) -> ResolvedEffect {
        let count = min(group.count, ColorFusion.maxOps)
        var ops = [Float](repeating: 0, count: 1 + ColorFusion.stride * ColorFusion.maxOps)
        ops[0] = Float(count)
        for i in 0..<count {
            let effect = group[i]
            let b = 1 + i * ColorFusion.stride
            ops[b + 0] = Float(effect.fusionOpcode ?? 0)
            ops[b + 1] = Float(effect.instance.universal.strength)
            ops[b + 2] = Float(effect.instance.universal.opacity)
            ops[b + 3] = Float(effect.instance.universal.blendAmount)
            ops[b + 4] = Float(effect.instance.universal.blendMode.rawValue)
            for (j, v) in effect.parameterFloats().prefix(9).enumerated() {
                ops[b + 5 + j] = v
            }
        }
        return ResolvedEffect(descriptor: ColorFusion.descriptor, instance: ColorFusion.instance, fusedOps: ops)
    }

    /// Pack this effect's parameter values into the uniform parameter slots,
    /// following declaration order.
    func writeParameters(into uniforms: inout SpectraUniforms) {
        uniforms.clearParams()
        var slot = 0
        for parameter in descriptor.parameters {
            let value = instance.values[parameter.id] ?? parameter.defaultValue
            uniforms.setParams(at: slot, value.floats)
            slot += value.componentCount
        }
        // The interaction/injection block begins at param slot `pointerSlotBase`. An effect whose
        // own params reach into it would silently clobber injected pointer/event state (and read
        // garbage). Trip in debug so a too-wide descriptor is caught at first run, not in the field.
        assert(slot <= EffectChainRenderer.pointerSlotBase,
               "Effect \(descriptor.id) declares \(slot) param floats; max is \(EffectChainRenderer.pointerSlotBase) before the interaction block at slot \(EffectChainRenderer.pointerSlotBase).")
    }

    /// Apply this instance's universal parameters to the uniform header.
    func writeUniversal(into uniforms: inout SpectraUniforms) {
        uniforms.strength = Float(instance.universal.strength)
        uniforms.opacity = Float(instance.universal.opacity)
        uniforms.blendAmount = Float(instance.universal.blendAmount)
        uniforms.blendMode = Float(instance.universal.blendMode.rawValue)
        uniforms.seed = instance.seed
    }
}

/// Pointwise colour-pass fusion: a run of consecutive single-tap colour effects is
/// collapsed into one `fx_color_fused` render pass, eliminating the full-resolution
/// read/write between each. The output is identical to running them as separate
/// passes (both paths call the same `colorproc_*` device functions in Color.metal).
enum ColorFusion {
    /// Effect id → opcode, MUST stay in lock-step with `spectra_colorproc` in
    /// Color.metal. The aux-texture-backed colour effects (`color.curves`,
    /// `color.lut`, `color.gradientMap`) are intentionally absent — they bind
    /// textures and cannot be fused.
    static let opcodes: [String: Int] = [
        "color.brightness": 0, "color.contrast": 1, "color.saturation": 2,
        "color.vibrance": 3, "color.exposure": 4, "color.gamma": 5,
        "color.highlights": 6, "color.shadows": 7, "color.whites": 8,
        "color.blacks": 9, "color.blackPoint": 10, "color.whitePoint": 11,
        "color.temperature": 12, "color.tint": 13, "color.sepia": 14,
        "color.invert": 15, "color.posterize": 16, "color.solarize": 17,
        "color.colorBalance": 18, "color.levels": 19, "color.hueShift": 20,
        "color.channelMixer": 21, "color.toneCurve": 22,
    ]
    /// Floats per op in the packed buffer (matches `kFusedOpStride`).
    static let stride = 16
    /// Max ops per fused pass (matches `kFusedMaxOps`); longer runs split.
    static let maxOps = 16
    static let fragmentFunction = "fx_color_fused"

    /// Synthetic descriptor for a fused pass: one `fx_color_fused` pass, no params.
    static let descriptor = EffectDescriptor(
        id: "internal.colorFused", name: "Fused Colour", category: .color,
        function: fragmentFunction, parameters: [])
    /// Neutral instance for the synthetic effect (its buffer-0 uniforms are unused
    /// by the interpreter, which reads per-op universals from the op buffer).
    static let instance = EffectInstance(descriptorID: "internal.colorFused")

    #if DEBUG
    /// Number of opcodes the Metal `spectra_colorproc` switch handles (its highest `case N:`
    /// plus one, in Color.metal). MUST stay in lock-step with that switch and with `opcodes`.
    static let metalOpcodeCount = 23

    /// Startup self-check (debug only): the Swift `opcodes` table and the Metal switch must not
    /// drift. Asserts the opcode values are contiguous `0..<count` and that count matches the
    /// Metal switch, so adding an op on one side without the other trips at first run.
    static func assertOpcodesMatchMetal() {
        assert(opcodes.count == metalOpcodeCount,
               "ColorFusion.opcodes has \(opcodes.count) entries but spectra_colorproc handles \(metalOpcodeCount); keep them in lock-step.")
        assert(Set(opcodes.values) == Set(0..<opcodes.count),
               "ColorFusion.opcodes values must be contiguous 0..<\(opcodes.count) with no gaps or duplicates.")
    }
    #endif
}
