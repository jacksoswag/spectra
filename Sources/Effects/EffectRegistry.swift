import Foundation
import Metal
import Observation

/// Central catalog of every available effect descriptor — built-in and custom.
/// Resolves descriptors by id and supplies the runtime-compiled library for
/// custom effects. Injected; not a global singleton.
@MainActor
@Observable
final class EffectRegistry {
    private(set) var descriptors: [EffectDescriptor] = []
    @ObservationIgnored private var byID: [String: EffectDescriptor] = [:]
    @ObservationIgnored private var customLibraries: [String: MTLLibrary] = [:]

    init() {
        register(BuiltInEffects.all())
    }

    // MARK: - Registration

    func register(_ descriptors: [EffectDescriptor]) {
        for descriptor in descriptors { byID[descriptor.id] = descriptor }
        rebuild()
    }

    func registerCustom(_ descriptor: EffectDescriptor, library: MTLLibrary?) {
        byID[descriptor.id] = descriptor
        if let library { customLibraries[descriptor.id] = library }
        rebuild()
    }

    func unregister(_ id: String) {
        byID[id] = nil
        customLibraries[id] = nil
        rebuild()
    }

    private func rebuild() {
        descriptors = byID.values.sorted { lhs, rhs in
            if lhs.category == rhs.category { return lhs.name < rhs.name }
            return categoryOrder(lhs.category) < categoryOrder(rhs.category)
        }
    }

    private func categoryOrder(_ category: EffectCategory) -> Int {
        EffectCategory.allCases.firstIndex(of: category) ?? .max
    }

    // MARK: - Lookup

    func descriptor(_ id: String) -> EffectDescriptor? { byID[id] }

    func customLibrary(for id: String) -> MTLLibrary? { customLibraries[id] }

    var categories: [EffectCategory] {
        let present = Set(descriptors.map(\.category))
        return EffectCategory.allCases.filter { present.contains($0) }
    }

    func effects(in category: EffectCategory) -> [EffectDescriptor] {
        descriptors.filter { $0.category == category }
    }

    /// Fuzzy-ish search over name, subtitle, tags, and category.
    func search(_ query: String) -> [EffectDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return descriptors }
        return descriptors.filter { descriptor in
            descriptor.name.lowercased().contains(trimmed)
                || descriptor.subtitle.lowercased().contains(trimmed)
                || descriptor.category.displayName.lowercased().contains(trimmed)
                || descriptor.tags.contains { $0.lowercased().contains(trimmed) }
        }
    }

}
