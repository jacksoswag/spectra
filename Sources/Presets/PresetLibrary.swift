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
    /// User-created categories (beyond the built-in spine). Stored so an empty,
    /// freshly-created category still shows, and survives relaunch.
    private(set) var customCategories: [String] = []

    private let recentsURL = AppPaths.presetsDirectory.appendingPathComponent("_recents.json")
    private let categoriesURL = AppPaths.presetsDirectory.appendingPathComponent("_categories.json")

    init() {
        builtIn = BuiltInPresets.all
        loadUserPresets()
        loadRecents()
        loadCategories()
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

    func presets(in category: String) -> [Preset] {
        all.filter { $0.category == category }
    }

    /// Categories to display (menu bar, library grouping, filter chips): built-in
    /// categories that actually have presets, in canonical order; then every custom
    /// category (always shown, even empty, so a freshly-created one is visible); then
    /// "My Presets" when any user preset lives there. Defensive: a category referenced
    /// by a preset but listed nowhere above still appears so nothing is hidden.
    var categories: [String] {
        var result = PresetCategory.builtInNames.filter { name in
            name != PresetCategory.userName && all.contains { $0.category == name }
        }
        result.append(contentsOf: customCategories.filter { !result.contains($0) })
        if all.contains(where: { $0.category == PresetCategory.userName }) {
            result.append(PresetCategory.userName)
        }
        for preset in all where !result.contains(preset.category) { result.append(preset.category) }
        return result
    }

    /// Categories offered when saving/filing a preset: every display category plus the
    /// default "My Presets" bucket (always available even when currently empty).
    var saveTargets: [String] {
        var result = categories
        if !result.contains(PresetCategory.userName) { result.append(PresetCategory.userName) }
        return result
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
                || $0.category.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: - Mutation

    @discardableResult
    func save(name: String, chain: EffectChain, category: String = PresetCategory.userName,
              summary: String = "", icon: String? = nil, tags: [String] = []) -> Preset {
        let preset = Preset(name: name, category: category, icon: icon, summary: summary,
                            author: "You", tags: tags, chain: chain, isBuiltIn: false, createdAt: Date())
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

    // MARK: - Categories

    /// Create a custom category. No-op for blank names, built-in names, or duplicates.
    func addCategory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !PresetCategory.isBuiltIn(trimmed),
              !customCategories.contains(trimmed) else { return }
        customCategories.append(trimmed)
        saveCategories()
    }

    /// Rename a custom category, moving its presets along with it. Built-in categories
    /// are immutable; renaming to a built-in name is rejected.
    func renameCategory(_ old: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !PresetCategory.isBuiltIn(old), !PresetCategory.isBuiltIn(trimmed),
              let index = customCategories.firstIndex(of: old) else { return }
        if customCategories.contains(trimmed) { customCategories.remove(at: index) }
        else { customCategories[index] = trimmed }
        for i in user.indices where user[i].category == old {
            user[i].category = trimmed
            persist(user[i])
        }
        saveCategories()
    }

    /// Delete a custom category. Its presets are NOT deleted — they orphan back to the
    /// default "My Presets" bucket. Built-in categories can't be deleted.
    func deleteCategory(_ name: String) {
        guard !PresetCategory.isBuiltIn(name) else { return }
        customCategories.removeAll { $0 == name }
        for i in user.indices where user[i].category == name {
            user[i].category = PresetCategory.userName
            persist(user[i])
        }
        saveCategories()
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

    private func loadCategories() {
        customCategories = JSONStore.load([String].self, from: categoriesURL) ?? []
    }

    private func saveCategories() {
        try? JSONStore.save(customCategories, to: categoriesURL)
    }
}
