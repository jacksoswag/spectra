import Foundation
import Observation

/// Owns the built-in and user preset collections, recents, and persistence.
/// User presets live as individual JSON files under the presets directory.
@MainActor
@Observable
final class PresetLibrary {
    private(set) var builtIn: [Preset] = []
    private(set) var user: [Preset] = []
    private(set) var recentIDs: [UUID] = []

    private let recentsURL = AppPaths.presetsDirectory.appendingPathComponent("_recents.json")

    init() {
        builtIn = BuiltInPresets.all
        loadUserPresets()
        loadRecents()
    }

    var all: [Preset] { builtIn + user }

    func preset(id: UUID) -> Preset? { all.first { $0.id == id } }

    /// The preset whose chain the live `chain` currently represents (structural
    /// match, ignoring per-instance identity), or nil if the stack is empty or no
    /// longer corresponds to any known preset. This is the source of truth for the
    /// menu's "current preset" label: it reflects what is actually loaded rather
    /// than a persisted name that can go stale once the stack is edited.
    func matchingPreset(for chain: EffectChain) -> Preset? {
        guard !chain.isEmpty else { return nil }
        return all.first { $0.chain.matchesPreset(chain) }
    }

    func presets(in category: PresetCategory) -> [Preset] {
        if category == .user { return user }
        return builtIn.filter { $0.category == category }
    }

    var categories: [PresetCategory] {
        var present = Set(builtIn.map(\.category))
        if !user.isEmpty { present.insert(.user) }
        return PresetCategory.allCases.filter { present.contains($0) }
    }

    var recents: [Preset] {
        recentIDs.compactMap { id in all.first { $0.id == id } }
    }

    func search(_ query: String) -> [Preset] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
                || $0.category.displayName.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: - Mutation

    @discardableResult
    func save(name: String, chain: EffectChain, category: PresetCategory = .user,
              summary: String = "", tags: [String] = []) -> Preset {
        let preset = Preset(name: name, category: category, summary: summary, author: "You",
                            tags: tags, chain: chain, isBuiltIn: false, createdAt: Date())
        user.append(preset)
        persist(preset)
        return preset
    }

    /// Rename a user preset in place (built-in presets are immutable).
    func rename(_ preset: Preset, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = user.firstIndex(where: { $0.id == preset.id }) else { return }
        user[index].name = trimmed
        persist(user[index])
    }

    func add(_ preset: Preset) {
        var imported = preset
        imported.isBuiltIn = false
        if user.contains(where: { $0.id == imported.id }) { imported.id = UUID() }
        user.append(imported)
        persist(imported)
    }

    func update(_ preset: Preset) {
        guard let index = user.firstIndex(where: { $0.id == preset.id }) else { return }
        user[index] = preset
        persist(preset)
    }

    func delete(_ preset: Preset) {
        user.removeAll { $0.id == preset.id }
        recentIDs.removeAll { $0 == preset.id }
        try? FileManager.default.removeItem(at: fileURL(for: preset))
        saveRecents()
    }

    func markRecent(_ preset: Preset) {
        recentIDs.removeAll { $0 == preset.id }
        recentIDs.insert(preset.id, at: 0)
        if recentIDs.count > 8 { recentIDs.removeLast(recentIDs.count - 8) }
        saveRecents()
    }

    // MARK: - Persistence

    private func fileURL(for preset: Preset) -> URL {
        AppPaths.presetsDirectory.appendingPathComponent("\(preset.id.uuidString).json")
    }

    private func persist(_ preset: Preset) {
        try? JSONStore.save(preset, to: fileURL(for: preset))
    }

    private func loadUserPresets() {
        AppPaths.ensureDirectories()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.presetsDirectory, includingPropertiesForKeys: nil) else { return }
        user = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .compactMap { JSONStore.load(Preset.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func loadRecents() {
        recentIDs = JSONStore.load([UUID].self, from: recentsURL) ?? []
    }

    private func saveRecents() {
        try? JSONStore.save(recentIDs, to: recentsURL)
    }
}
