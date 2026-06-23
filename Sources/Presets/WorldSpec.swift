import Foundation

/// Per-theme menu-bar treatment (MAOE §9). `none` leaves the menu bar untouched.
enum MenuBarStyle: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case softShadow   // Golden Hour soft directional shadow
    case caption      // Noir silent-film caption strip
    case reflective   // Frutiger clear reflective bar
    case pastel       // Fuji matte pastel

    init(rawIndex: Int) { self = Self.allCases[safe: rawIndex] ?? .none }
    /// Index handed to the in-shader menu-bar pass (matches `fx_chrome_menuBar`'s style branch).
    var shaderIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var displayName: String {
        switch self {
        case .none: "None"
        case .softShadow: "Soft Shadow"
        case .caption: "Caption"
        case .reflective: "Reflective"
        case .pastel: "Pastel"
        }
    }
}

/// Per-theme Dock treatment (MAOE §9). `none` leaves the Dock untouched.
enum DockStyle: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case groundedShadow  // Golden Hour grounded ambient shadow
    case stageFrame      // stage-boundary frame
    case neonOutline     // Matrix / Cyberpunk neon outline
    case mattePastel     // Fuji matte pastel (no glass)
    case reflective      // Frutiger very reflective

    init(rawIndex: Int) { self = Self.allCases[safe: rawIndex] ?? .none }
    /// Index handed to the in-shader Dock pass (matches `fx_chrome_dock`'s style branch).
    var shaderIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var displayName: String {
        switch self {
        case .none: "None"
        case .groundedShadow: "Grounded Shadow"
        case .stageFrame: "Stage Frame"
        case .neonOutline: "Neon Outline"
        case .mattePastel: "Matte Pastel"
        case .reflective: "Reflective"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A world's default system-UI treatment (MAOE §9). Applied at lower priority than explicit
/// user stack rows, so user edits win.
struct SystemUIDefaults: Codable, Sendable, Hashable {
    var menuBar: MenuBarStyle?
    var dock: DockStyle?
    var light: LightModel?

    init(menuBar: MenuBarStyle? = nil, dock: DockStyle? = nil, light: LightModel? = nil) {
        self.menuBar = menuBar
        self.dock = dock
        self.light = light
    }
}

/// A world's motion envelope (MAOE §10). The engine prefers event-driven effects over
/// continuous ones and wires `reduceMotion` against this.
struct MotionBudget: Codable, Sendable, Hashable {
    /// Advisory ceiling (1…3) on simultaneous continuous effects.
    var continuousMax: Int?
    /// 0…1, maps to `CursorIntensity`.
    var cursorIntensity: Float?
    /// Optional per-world governor target GPU time (ms).
    var targetGPUms: Double?

    init(continuousMax: Int? = nil, cursorIntensity: Float? = nil, targetGPUms: Double? = nil) {
        self.continuousMax = continuousMax
        self.cursorIntensity = cursorIntensity
        self.targetGPUms = targetGPUms
    }
}

/// A preset's behaviour bundle (MAOE §5.3): the facets that turn a tuned shader chain into a
/// coherent *world* — its cursor, system-UI defaults, and motion budget. Optional on `Preset`
/// so every existing built-in and user-preset JSON decodes unchanged (absent key → nil).
/// Interaction effects ride as ordinary chain members, not here, so a soft-locked world (§8)
/// carries them atomically with the chain.
struct WorldSpec: Codable, Sendable, Hashable {
    var cursor: CursorSpec?
    var systemUI: SystemUIDefaults?
    var motion: MotionBudget?
    /// Per-world opt-in for the §15 engine capabilities (each also gated on a global Settings
    /// toggle, so a world never forces them on). `focusDim` is 0…1 — how strongly background
    /// windows dim when the focus spotlight is enabled.
    var audioReactive: Bool
    var keyboardReactive: Bool
    var focusDim: Float

    init(cursor: CursorSpec? = nil, systemUI: SystemUIDefaults? = nil, motion: MotionBudget? = nil,
         audioReactive: Bool = false, keyboardReactive: Bool = false, focusDim: Float = 0) {
        self.cursor = cursor
        self.systemUI = systemUI
        self.motion = motion
        self.audioReactive = audioReactive
        self.keyboardReactive = keyboardReactive
        self.focusDim = focusDim
    }
}
