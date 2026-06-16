import Foundation

/// One building block within a composed effect: a reference to a built-in effect
/// descriptor plus the baked parameter values and universal settings the author
/// dialled in while composing.
struct ComposedStage: Codable, Hashable, Sendable {
    var descriptorID: String
    var values: [String: ParameterValue]
    var universal: UniversalParameters

    init(descriptorID: String, values: [String: ParameterValue] = [:], universal: UniversalParameters = .default) {
        self.descriptorID = descriptorID
        self.values = values
        self.universal = universal
    }

    init(_ instance: EffectInstance) {
        self.descriptorID = instance.descriptorID
        self.values = instance.values
        self.universal = instance.universal
    }
}

/// A parameter of one stage that the author chose to surface on the finished
/// composite, so users can tune it without opening the composer.
struct ExposedParameter: Codable, Hashable, Sendable, Identifiable {
    /// Stable id of the parameter as it appears on the composite (e.g. "p0").
    var id: String
    /// Display label on the composite.
    var label: String
    /// Which stage the parameter comes from.
    var stageIndex: Int
    /// The source parameter's id within that stage's descriptor.
    var sourceParamID: String
}

/// A reusable effect authored in the visual composer: a pipeline of building
/// blocks, the parameters exposed on it, and its metadata. Expanded into its
/// component passes by `ChainResolver`, so it renders as a single library effect.
struct ComposedEffect: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var category: EffectCategory
    var tags: [String]
    var stages: [ComposedStage]
    var exposed: [ExposedParameter]
    var isAnimated: Bool
    var thumbnailPNGBase64: String?
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: String = "composed.\(UUID().uuidString.prefix(8))",
        name: String,
        subtitle: String = "Composed effect",
        category: EffectCategory = .custom,
        tags: [String] = ["composed"],
        stages: [ComposedStage] = [],
        exposed: [ExposedParameter] = [],
        isAnimated: Bool = false,
        thumbnailPNGBase64: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.category = category
        self.tags = tags
        self.stages = stages
        self.exposed = exposed
        self.isAnimated = isAnimated
        self.thumbnailPNGBase64 = thumbnailPNGBase64
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// The library descriptor representing this composite. Its parameters are the
    /// exposed ones (resolved against their source stages); it declares no passes
    /// of its own because `ChainResolver` expands it into its stages.
    @MainActor
    func makeDescriptor(registry: EffectRegistry) -> EffectDescriptor {
        let params: [EffectParameter] = exposed.compactMap { exposed in
            guard exposed.stageIndex < stages.count,
                  let descriptor = registry.descriptor(stages[exposed.stageIndex].descriptorID),
                  let source = descriptor.parameters.first(where: { $0.id == exposed.sourceParamID }) else { return nil }
            let baked = stages[exposed.stageIndex].values[exposed.sourceParamID] ?? source.defaultValue
            return EffectParameter(
                id: exposed.id, name: exposed.label, control: source.control,
                defaultValue: baked, group: nil, help: source.help)
        }
        return EffectDescriptor(
            id: id, name: name, category: category, subtitle: subtitle,
            icon: "square.stack.3d.up.fill", parameters: params, passes: [],
            tags: tags, isCustom: true, isAnimated: isAnimated)
    }
}
