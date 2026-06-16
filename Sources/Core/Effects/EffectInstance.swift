import Foundation

/// A configured occurrence of an effect within a chain. Value type so the
/// renderer can take cheap, thread-safe snapshots while the UI mutates the
/// authoritative copy on the main actor.
struct EffectInstance: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// References an `EffectDescriptor` by id (resolved via `EffectRegistry`).
    let descriptorID: String
    /// Optional user-assigned name; falls back to the descriptor name when nil.
    var name: String?
    var isEnabled: Bool
    /// Inspector disclosure state (persisted for convenience).
    var isExpanded: Bool
    var universal: UniversalParameters
    /// Parameter values keyed by `EffectParameter.id`.
    var values: [String: ParameterValue]
    /// Optional group membership.
    var groupID: UUID?
    /// Per-instance random seed (stable once created) for stochastic effects.
    var seed: Float

    init(descriptor: EffectDescriptor, groupID: UUID? = nil) {
        self.id = UUID()
        self.descriptorID = descriptor.id
        self.name = nil
        self.isEnabled = true
        self.isExpanded = true
        self.universal = .default
        self.values = descriptor.defaultValues()
        self.groupID = groupID
        self.seed = Float.random(in: 0..<1)
    }

    /// Build an instance from a descriptor id and a sparse set of overrides
    /// (used by presets/documents authored without a live descriptor). Missing
    /// values fall back to the descriptor defaults at render time.
    init(
        descriptorID: String,
        isEnabled: Bool = true,
        values: [String: ParameterValue] = [:],
        universal: UniversalParameters = .default,
        groupID: UUID? = nil
    ) {
        self.id = UUID()
        self.descriptorID = descriptorID
        self.name = nil
        self.isEnabled = isEnabled
        self.isExpanded = true
        self.universal = universal
        self.values = values
        self.groupID = groupID
        self.seed = Float.random(in: 0..<1)
    }

    /// Resolve a parameter value, falling back to the descriptor default.
    func value(_ id: String, default fallback: ParameterValue) -> ParameterValue {
        values[id] ?? fallback
    }
}

/// A collapsible, independently toggleable grouping of consecutive effects.
struct EffectGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var isCollapsed: Bool

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.isEnabled = true
        self.isCollapsed = false
    }
}

/// The full, persistable description of an effect chain: an ordered list of
/// effect instances plus their group metadata. This is the unit shared between
/// presets, documents, and the live render snapshot.
struct EffectChain: Codable, Hashable, Sendable {
    var effects: [EffectInstance]
    var groups: [EffectGroup]

    init(effects: [EffectInstance] = [], groups: [EffectGroup] = []) {
        self.effects = effects
        self.groups = groups
    }

    /// Whether an instance is *effectively* enabled, accounting for its group.
    func isEffectivelyEnabled(_ instance: EffectInstance) -> Bool {
        guard instance.isEnabled else { return false }
        if let groupID = instance.groupID, let group = groups.first(where: { $0.id == groupID }) {
            return group.isEnabled
        }
        return true
    }

    var isEmpty: Bool { effects.isEmpty }

    /// Structural equivalence for preset identification: the same effects in the
    /// same order with the same descriptor, enabled state, universal parameters,
    /// and parameter values. Per-instance identity (`id`, `seed`, custom `name`,
    /// disclosure/group state) is ignored because it doesn't change the rendered
    /// result — so a freshly-applied preset still matches its library entry even
    /// though every instance got a new random id and seed on load.
    func matchesPreset(_ other: EffectChain) -> Bool {
        guard effects.count == other.effects.count else { return false }
        for (a, b) in zip(effects, other.effects) {
            if a.descriptorID != b.descriptorID { return false }
            if a.isEnabled != b.isEnabled { return false }
            if a.universal != b.universal { return false }
            if a.values != b.values { return false }
        }
        return true
    }
}
