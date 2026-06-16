import Foundation
import Observation

/// Owns visually-composed effects: registration with the `EffectRegistry` (as
/// placeholder descriptors that `ChainResolver` expands into their stages) and
/// persistence. The composer creates and edits these; the library lists them.
@MainActor
@Observable
final class ComposedEffectStore {
    private(set) var effects: [ComposedEffect] = []

    private let registry: EffectRegistry

    init(registry: EffectRegistry) {
        self.registry = registry
        load()
    }

    func effect(for id: String) -> ComposedEffect? { effects.first { $0.id == id } }

    var ids: Set<String> { Set(effects.map(\.id)) }

    /// Register, persist, and store a composite (insert or replace).
    func upsert(_ effect: ComposedEffect) {
        registry.registerCustom(effect.makeDescriptor(registry: registry), library: nil)
        if let index = effects.firstIndex(where: { $0.id == effect.id }) {
            effects[index] = effect
        } else {
            effects.append(effect)
        }
        persist(effect)
    }

    func remove(_ id: String) {
        effects.removeAll { $0.id == id }
        registry.unregister(id)
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    // MARK: - Persistence

    private func fileURL(for id: String) -> URL {
        AppPaths.composedDirectory.appendingPathComponent("\(id).json")
    }

    private func persist(_ effect: ComposedEffect) {
        try? JSONStore.save(SpectraDocument.composed(effect), to: fileURL(for: effect.id))
    }

    private func load() {
        AppPaths.ensureDirectories()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.composedDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let document = JSONStore.load(SpectraDocument.self, from: file),
                  let effect = document.composed else { continue }
            registry.registerCustom(effect.makeDescriptor(registry: registry), library: nil)
            effects.append(effect)
        }
    }
}
