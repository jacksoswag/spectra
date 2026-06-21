import Foundation

/// Curated grouping for the preset browser. Only the categories the shipped
/// built-ins actually populate are kept; `.experimental` is retained as the
/// tolerant-decode landing spot, and `.user` is the operational home for chains
/// the user saves. `PresetLibrary` only surfaces categories with presets present.
enum PresetCategory: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
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

    /// Tolerant decode: presets authored against a removed category (e.g. an old
    /// "Horror", "Gaming", or "Sci-Fi") still load, landing in Experimental.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PresetCategory(rawValue: raw) ?? .experimental
    }
}

/// A named, shareable effect chain plus metadata.
struct Preset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var category: PresetCategory
    var icon: String?
    var summary: String
    var author: String
    var tags: [String]
    var chain: EffectChain
    var isBuiltIn: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        category: PresetCategory,
        icon: String? = nil,
        summary: String = "",
        author: String = "Spectra",
        tags: [String] = [],
        chain: EffectChain,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
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
    }

    /// The preset's own SF Symbol; falls back to the category icon when unset.
    var displayIcon: String { icon ?? category.iconSystemName }
}
