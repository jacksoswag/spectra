import Foundation
import Observation

/// The authoritative, observable model of the active effect chain for one
/// editing context (e.g. the studio's current display target). All mutations
/// flow through methods so a single `onChange` hook can push immutable snapshots
/// to the renderer while SwiftUI observes the properties directly.
@Observable
@MainActor
final class EffectStack {
    private(set) var effects: [EffectInstance] = []
    private(set) var groups: [EffectGroup] = []

    /// Currently selected instance in the inspector.
    var selection: UUID?

    /// Monotonic change counter, useful for cheap diffing.
    private(set) var revision: Int = 0

    /// Called after every mutation with a fresh immutable snapshot. The render
    /// coordinator subscribes to keep the GPU chain in sync. Not observed by
    /// SwiftUI (it's a side channel), so it lives outside `@ObservationIgnored`
    /// concerns by being a plain closure invoked manually.
    @ObservationIgnored
    var onChange: ((EffectChain) -> Void)?

    init(chain: EffectChain = EffectChain()) {
        self.effects = chain.effects
        self.groups = chain.groups
    }

    // MARK: - Snapshot

    func chain() -> EffectChain { EffectChain(effects: effects, groups: groups) }

    func load(_ chain: EffectChain) {
        effects = chain.effects
        groups = chain.groups
        if let selection, !effects.contains(where: { $0.id == selection }) {
            self.selection = effects.first?.id
        }
        didMutate()
    }

    // MARK: - Lookup

    func index(of id: UUID) -> Int? { effects.firstIndex { $0.id == id } }

    subscript(id: UUID) -> EffectInstance? {
        index(of: id).map { effects[$0] }
    }

    var selectedInstance: EffectInstance? {
        guard let selection else { return nil }
        return self[selection]
    }

    // MARK: - Add / remove / reorder

    @discardableResult
    func add(_ descriptor: EffectDescriptor, at index: Int? = nil) -> EffectInstance {
        let instance = EffectInstance(descriptor: descriptor)
        let insertIndex = index ?? effects.count
        effects.insert(instance, at: min(max(insertIndex, 0), effects.count))
        selection = instance.id
        didMutate()
        return instance
    }

    func remove(_ id: UUID) {
        effects.removeAll { $0.id == id }
        if selection == id { selection = effects.first?.id }
        didMutate()
    }

    func removeSelected() {
        if let selection { remove(selection) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        effects.move(fromOffsets: source, toOffset: destination)
        normalizeGroupContiguity()
        didMutate()
    }

    func move(id: UUID, toIndex destination: Int) {
        guard let from = index(of: id) else { return }
        let instance = effects.remove(at: from)
        let clamped = min(max(destination, 0), effects.count)
        effects.insert(instance, at: clamped)
        didMutate()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> EffectInstance? {
        guard let idx = index(of: id) else { return nil }
        var copy = effects[idx]
        copy.id = UUID()
        copy.seed = Float.random(in: 0..<1)
        effects.insert(copy, at: idx + 1)
        selection = copy.id
        didMutate()
        return copy
    }

    func clear() {
        effects.removeAll()
        groups.removeAll()
        selection = nil
        didMutate()
    }

    // MARK: - Per-instance edits

    func update(_ id: UUID, _ mutate: (inout EffectInstance) -> Void) {
        guard let idx = index(of: id) else { return }
        mutate(&effects[idx])
        didMutate()
    }

    func setValue(_ value: ParameterValue, for parameterID: String, on instanceID: UUID) {
        update(instanceID) { $0.values[parameterID] = value }
    }

    func setEnabled(_ enabled: Bool, on instanceID: UUID) {
        update(instanceID) { $0.isEnabled = enabled }
    }

    func toggleEnabled(_ instanceID: UUID) {
        update(instanceID) { $0.isEnabled.toggle() }
    }

    func setExpanded(_ expanded: Bool, on instanceID: UUID) {
        update(instanceID) { $0.isExpanded = expanded }
    }

    /// Rename an instance. An empty/whitespace name clears back to the descriptor name.
    func rename(_ instanceID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(instanceID) { $0.name = trimmed.isEmpty ? nil : trimmed }
    }

    /// Move an instance into a group (or out, with nil), keeping groups contiguous.
    func setGroup(_ groupID: UUID?, for instanceID: UUID) {
        guard let idx = index(of: instanceID) else { return }
        effects[idx].groupID = groupID
        normalizeGroupContiguity()
        didMutate()
    }

    func resetParameters(on instanceID: UUID, to descriptor: EffectDescriptor) {
        update(instanceID) {
            $0.values = descriptor.defaultValues()
            $0.universal = .default
        }
    }

    // MARK: - Groups

    @discardableResult
    func createGroup(named name: String, members: [UUID]) -> EffectGroup {
        let group = EffectGroup(name: name)
        groups.append(group)
        for memberID in members {
            if let idx = index(of: memberID) { effects[idx].groupID = group.id }
        }
        normalizeGroupContiguity()
        didMutate()
        return group
    }

    func ungroup(_ groupID: UUID) {
        for idx in effects.indices where effects[idx].groupID == groupID {
            effects[idx].groupID = nil
        }
        groups.removeAll { $0.id == groupID }
        didMutate()
    }

    func renameGroup(_ groupID: UUID, to name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].name = name
        didMutate()
    }

    func setGroupEnabled(_ enabled: Bool, groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].isEnabled = enabled
        didMutate()
    }

    func toggleGroupCollapsed(_ groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].isCollapsed.toggle()
        didMutate()
    }

    // MARK: - Internals

    /// Keep grouped effects contiguous so the rendered order matches the visual
    /// grouping. Effects retain their relative order; members of each group are
    /// gathered at the position of the group's first member.
    private func normalizeGroupContiguity() {
        guard !groups.isEmpty else { return }
        var seenGroups: [UUID] = []
        var result: [EffectInstance] = []
        var consumed = Set<UUID>()

        for instance in effects {
            guard !consumed.contains(instance.id) else { continue }
            if let groupID = instance.groupID {
                if seenGroups.contains(groupID) { continue }
                seenGroups.append(groupID)
                let members = effects.filter { $0.groupID == groupID }
                result.append(contentsOf: members)
                members.forEach { consumed.insert($0.id) }
            } else {
                result.append(instance)
                consumed.insert(instance.id)
            }
        }
        effects = result
    }

    private func didMutate() {
        revision &+= 1
        onChange?(chain())
    }
}
