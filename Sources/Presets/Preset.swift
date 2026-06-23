import Foundation

/// The fixed, built-in preset categories. `Preset.category` is a free-form `String`
/// (so users can add/rename/delete their own categories at runtime); this enum is the
/// catalog of the shipped built-ins — their canonical order, icons, and the default
/// "My Presets" bucket. Built-in names can't be renamed or deleted; custom ones can.
enum PresetCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case cinematic = "Cinematic"
    case retro = "Retro"
    case artistic = "Artistic"
    case utility = "Utility"
    case experimental = "Experimental"
    case user = "My Presets"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var iconSystemName: String {
        switch self {
        case .cinematic: "film.stack"
        case .retro: "tv.fill"
        case .artistic: "paintbrush.pointed.fill"
        case .utility: "eye"
        case .experimental: "atom"
        case .user: "person.fill"
        }
    }

    /// Built-in category names in canonical order — the fixed spine the dynamic
    /// category list is built around.
    static var builtInNames: [String] { allCases.map(\.rawValue) }

    /// The default bucket user-saved presets land in (and where presets orphaned by a
    /// deleted custom category go).
    static var userName: String { user.rawValue }

    /// Whether a category name is a fixed built-in (built-ins can't be renamed/deleted).
    static func isBuiltIn(_ name: String) -> Bool { PresetCategory(rawValue: name) != nil }

    /// SF Symbol for any category name: the built-in's own icon, or a generic folder for
    /// a user-created custom category.
    static func icon(for name: String) -> String {
        PresetCategory(rawValue: name)?.iconSystemName ?? "folder"
    }
}

/// A named, shareable effect chain plus metadata.
struct Preset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Free-form category name (a built-in like "Cinematic"/"My Presets" or a user-created
    /// one). A plain `String` so users can add their own categories. Wire-compatible with
    /// the old `PresetCategory` enum, whose raw value was this same display string.
    var category: String
    var icon: String?
    var summary: String
    var author: String
    var tags: [String]
    var chain: EffectChain
    var isBuiltIn: Bool
    var createdAt: Date
    /// The world behaviour bundle (cursor, system-UI, motion — MAOE §5.3). Optional, so all
    /// existing built-in and user-preset JSON decodes unchanged (absent key → nil). Does not
    /// affect preset identity: `matchesPreset` compares chain contents only, never metadata.
    var world: WorldSpec?

    init(
        id: UUID = UUID(),
        name: String,
        category: String,
        icon: String? = nil,
        summary: String = "",
        author: String = "Spectra",
        tags: [String] = [],
        chain: EffectChain,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        world: WorldSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.icon = icon
        self.summary = summary
        self.author = author
        self.tags = tags
        self.chain = chain
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.world = world
    }

    /// The preset's own SF Symbol; falls back to the category icon when unset.
    var displayIcon: String { icon ?? PresetCategory.icon(for: category) }
}
