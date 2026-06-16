import Foundation
import Metal

/// Turns a persistable `EffectChain` into render-ready `[ResolvedEffect]` by
/// resolving descriptor ids and custom libraries through the registry, dropping
/// disabled or unknown effects, expanding composed effects into their component
/// stages, and baking any texture-backed parameters (curves, gradients, LUTs)
/// into auxiliary textures. Keeps the renderer free of registry knowledge.
@MainActor
struct ChainResolver {
    let registry: EffectRegistry
    var composedStore: ComposedEffectStore?
    var auxFactory: AuxTextureFactory?
    /// Collapse consecutive pointwise colour effects into one fused pass. On by
    /// default; the engine syncs it from settings so it can be turned off.
    var fuseColorPasses = true

    func resolve(_ chain: EffectChain) -> [ResolvedEffect] {
        var result: [ResolvedEffect] = []
        for instance in chain.effects {
            guard chain.isEffectivelyEnabled(instance) else { continue }
            if let composite = composedStore?.effect(for: instance.descriptorID) {
                result.append(contentsOf: expand(composite, instance: instance))
            } else if let descriptor = registry.descriptor(instance.descriptorID) {
                result.append(ResolvedEffect(
                    descriptor: descriptor,
                    instance: instance,
                    customLibrary: registry.customLibrary(for: instance.descriptorID),
                    auxTextures: auxTextures(for: descriptor, instance: instance)))
            }
        }
        return fuse(result)
    }

    /// Replace each maximal run of ≥2 consecutive fusable effects with a single
    /// fused effect. Order is preserved, and the fused output is identical to the
    /// separate passes, so this is a pure performance transform. Runs longer than
    /// `ColorFusion.maxOps` split into multiple fused passes.
    private func fuse(_ effects: [ResolvedEffect]) -> [ResolvedEffect] {
        guard fuseColorPasses else { return effects }
        var result: [ResolvedEffect] = []
        var run: [ResolvedEffect] = []
        func flushRun() {
            var index = 0
            while index < run.count {
                let chunk = Array(run[index..<min(index + ColorFusion.maxOps, run.count)])
                if chunk.count >= 2 {
                    result.append(ResolvedEffect.fused(chunk))
                } else {
                    result.append(contentsOf: chunk)   // a lone effect: leave as its own pass
                }
                index += ColorFusion.maxOps
            }
            run.removeAll(keepingCapacity: true)
        }
        for effect in effects {
            if effect.isFusable {
                run.append(effect)
            } else {
                flushRun()
                result.append(effect)
            }
        }
        flushRun()
        return result
    }

    /// Build the ordered auxiliary textures for an effect's texture-backed
    /// parameters (curve/gradient/LUT), in parameter declaration order — matching
    /// the order the shader binds them at fragment texture index 2+.
    private func auxTextures(for descriptor: EffectDescriptor, instance: EffectInstance) -> [MTLTexture] {
        guard let auxFactory else { return [] }
        var textures: [MTLTexture] = []
        for parameter in descriptor.parameters {
            let value = instance.values[parameter.id] ?? parameter.defaultValue
            switch value {
            case .curve(let points): if let t = auxFactory.curveTexture(points) { textures.append(t) }
            case .gradient(let stops): if let t = auxFactory.gradientTexture(stops) { textures.append(t) }
            case .lut(let name): if let t = auxFactory.lutTexture(named: name) { textures.append(t) }
            default: break
            }
        }
        return textures
    }

    /// Expand a composite into one resolved effect per stage. Exposed-parameter
    /// values on the composite instance override the baked stage values; the
    /// composite's strength scales every stage, and its opacity applies to the
    /// final stage so the whole composite fades as a unit.
    private func expand(_ composite: ComposedEffect, instance: EffectInstance) -> [ResolvedEffect] {
        var result: [ResolvedEffect] = []
        let lastIndex = composite.stages.count - 1
        for (stageIndex, stage) in composite.stages.enumerated() {
            guard let descriptor = registry.descriptor(stage.descriptorID),
                  !descriptor.passes.isEmpty else { continue }   // skip nested/empty
            var values = stage.values
            for exposed in composite.exposed where exposed.stageIndex == stageIndex {
                if let override = instance.values[exposed.id] { values[exposed.sourceParamID] = override }
            }
            var universal = stage.universal
            universal.strength *= instance.universal.strength
            if stageIndex == lastIndex { universal.opacity *= instance.universal.opacity }

            var stageInstance = EffectInstance(
                descriptorID: stage.descriptorID, isEnabled: true, values: values, universal: universal)
            stageInstance.seed = instance.seed
            result.append(ResolvedEffect(
                descriptor: descriptor,
                instance: stageInstance,
                customLibrary: registry.customLibrary(for: stage.descriptorID),
                auxTextures: auxTextures(for: descriptor, instance: stageInstance)))
        }
        return result
    }
}
