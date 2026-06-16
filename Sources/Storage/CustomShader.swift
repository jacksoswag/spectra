import Foundation

/// A user-authored or imported Metal effect: its source, entry point, and the
/// parameters it exposes. Compiled at runtime by `ShaderImporter` /
/// `ShaderCompiler` into an `MTLLibrary` and surfaced as an `EffectDescriptor`.
struct CustomShader: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var fragmentFunction: String
    var source: String
    var parameters: [EffectParameter]
    var isAnimated: Bool
    var tags: [String]
    var createdAt: Date

    init(
        id: String = "custom.\(UUID().uuidString.prefix(8))",
        name: String,
        subtitle: String = "Custom effect",
        fragmentFunction: String,
        source: String,
        parameters: [EffectParameter] = [],
        isAnimated: Bool = false,
        tags: [String] = ["custom"],
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.fragmentFunction = fragmentFunction
        self.source = source
        self.parameters = parameters
        self.isAnimated = isAnimated
        self.tags = tags
        self.createdAt = createdAt
    }

    /// Build the descriptor that represents this shader in the library.
    func makeDescriptor() -> EffectDescriptor {
        EffectDescriptor(
            id: id, name: name, category: .custom, subtitle: subtitle,
            icon: "wand.and.stars", function: fragmentFunction,
            parameters: parameters, tags: tags, isCustom: true, isAnimated: isAnimated)
    }
}

/// Versioned, exportable container for `.spectra` files (and JSON exports).
///
/// `version` lets the format evolve: readers accept any version up to
/// `currentVersion` and tolerate missing newer fields, so older documents keep
/// importing and newer ones degrade gracefully on older builds.
struct SpectraDocument: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case preset, shader, composed }

    var version: Int
    var kind: Kind
    var preset: Preset?
    var shader: CustomShader?
    var composed: ComposedEffect?
    /// Provenance metadata, carried for sharing and forward-compatibility.
    var app: String
    var appVersion: String
    var platform: String
    /// Effect descriptor ids this document references, so an importer can detect
    /// missing dependencies before applying it.
    var dependencies: [String]
    var exportedAt: Date

    static let currentVersion = 2

    private static func envelope(kind: Kind, preset: Preset? = nil,
                                 shader: CustomShader? = nil, composed: ComposedEffect? = nil) -> SpectraDocument {
        var dependencies: [String] = []
        if let preset { dependencies = Array(Set(preset.chain.effects.map(\.descriptorID))).sorted() }
        if let composed { dependencies = Array(Set(composed.stages.map(\.descriptorID))).sorted() }
        return SpectraDocument(
            version: currentVersion, kind: kind, preset: preset, shader: shader, composed: composed,
            app: "Spectra", appVersion: "1.0", platform: "macOS",
            dependencies: dependencies, exportedAt: Date())
    }

    static func preset(_ preset: Preset) -> SpectraDocument { envelope(kind: .preset, preset: preset) }
    static func shader(_ shader: CustomShader) -> SpectraDocument { envelope(kind: .shader, shader: shader) }
    static func composed(_ composed: ComposedEffect) -> SpectraDocument { envelope(kind: .composed, composed: composed) }

    private enum CodingKeys: String, CodingKey {
        case version, kind, preset, shader, composed, app, appVersion, platform, dependencies, exportedAt
    }

    /// Tolerant decode so v1 documents (no provenance fields, no composed case)
    /// still load on this build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        kind = try c.decode(Kind.self, forKey: .kind)
        preset = try? c.decode(Preset.self, forKey: .preset)
        shader = try? c.decode(CustomShader.self, forKey: .shader)
        composed = try? c.decode(ComposedEffect.self, forKey: .composed)
        app = (try? c.decode(String.self, forKey: .app)) ?? "Spectra"
        appVersion = (try? c.decode(String.self, forKey: .appVersion)) ?? "1.0"
        platform = (try? c.decode(String.self, forKey: .platform)) ?? "macOS"
        dependencies = (try? c.decode([String].self, forKey: .dependencies)) ?? []
        exportedAt = (try? c.decode(Date.self, forKey: .exportedAt)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    init(version: Int, kind: Kind, preset: Preset?, shader: CustomShader?, composed: ComposedEffect?,
         app: String, appVersion: String, platform: String, dependencies: [String], exportedAt: Date) {
        self.version = version; self.kind = kind; self.preset = preset; self.shader = shader
        self.composed = composed; self.app = app; self.appVersion = appVersion
        self.platform = platform; self.dependencies = dependencies; self.exportedAt = exportedAt
    }
}
