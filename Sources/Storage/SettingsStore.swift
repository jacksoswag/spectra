import Foundation
import Observation

/// Frame-rate target policy.
enum FrameRatePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case matchDisplay, cap120, cap60, cap30
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .matchDisplay: "Match Display"
        case .cap120: "120 Hz"
        case .cap60: "60 Hz"
        case .cap30: "30 Hz"
        }
    }
    func fps(forDisplayRefresh refresh: Double) -> Int {
        switch self {
        case .matchDisplay: max(60, Int(refresh.rounded()))
        case .cap120: min(120, max(60, Int(refresh.rounded())))
        case .cap60: 60
        case .cap30: 30
        }
    }
}

/// Resolution at which the effect chain is rendered, decoupled from the display
/// resolution. The chain renders into smaller textures and is upscaled at the
/// final present. Because a heavy chain is memory-bandwidth bound (cost scales
/// with pixel count), lowering this is the dominant performance lever: 0.5× scale
/// is a quarter of the pixels and roughly a quarter of the cost. Low-frequency
/// effects (blur, bloom, grade, CRT, VHS) upscale with little visible loss.
///
/// `SettingsStore.renderScale` is the user-facing value: a fixed, continuous
/// fraction of native (`min`…1.0) set by the Quality slider. The chain always
/// renders at exactly this scale.
enum RenderScale {
    /// Don't render below this fraction of native, however heavy the chain. Also the
    /// floor of the Quality slider (25%).
    static let min = 0.25
    static let max = 1.0

    /// A short label like "85%" / "Native" for a scale value.
    static func label(_ scale: Double) -> String {
        scale >= 0.999 ? "Native" : "\(Int((scale * 100).rounded()))%"
    }
}

/// Persisted user settings. Observable for the UI; autosaves on change.
@MainActor
@Observable
final class SettingsStore {
    var startEnabledOnLaunch: Bool { didSet { persist() } }
    /// Effect-chain render scale, a fixed fraction of native (`RenderScale.min`…1.0):
    /// the single performance lever that actually moves a bandwidth-bound native-res
    /// chain. The chain renders at this scale and the present pass upscales to fit.
    var renderScale: Double { didSet { persist() } }
    var showCursorInCapture: Bool { didSet { persist() } }
    /// Draw a stylized cursor (run through the effect chain) instead of the system
    /// cursor; hides the hardware cursor while active.
    var customCursor: Bool { didSet { persist() } }
    var frameRatePolicy: FrameRatePolicy { didSet { persist() } }
    var reduceMotion: Bool { didSet { persist() } }
    var menuBarShowsPerformance: Bool { didSet { persist() } }
    /// Raise the overlay above the menu bar, status items, and Dock so effects
    /// (warp, grade, bloom…) cover the entire screen rather than stopping at the
    /// desktop. On by default. The overlay stays click-through and a global panic
    /// hotkey can disable it, so the covered menu bar/Dock remain reachable.
    var coverMenuBarAndDock: Bool { didSet { persist() } }
    /// Collapse consecutive pointwise colour effects into one GPU pass (identical
    /// output, fewer full-resolution read/writes). On by default; an escape hatch in
    /// case a fused result ever looks different from the separate passes.
    var fuseColorPasses: Bool { didSet { persist() } }

    /// Effect descriptor ids the user has starred in the library.
    private(set) var favoriteEffectIDs: Set<String> { didSet { persist() } }

    @ObservationIgnored private var isLoading = false

    /// Bumped when stored settings need a one-time migration on load.
    /// v2: introduced the (now-superseded) Adaptive Quality bool, off by default.
    /// v3: introduced a discrete `renderQuality` rung (native/high/balanced/…).
    /// v4: replaced it with a continuous `renderScale` (plus a since-removed
    ///     `autoCalibrate`, now ignored on load).
    private static let currentSchemaVersion = 4

    private struct State: Codable {
        var startEnabledOnLaunch = false
        // Continuous chain render scale. Optional so older files (which lack the key)
        // decode to nil and get the default / migration below. A legacy `autoCalibrate`
        // key in older files is simply ignored on decode.
        var renderScale: Double? = nil
        // Legacy (schema ≤ 3): a discrete render-quality rung, persisted as its raw
        // string ("native"/"high"/"balanced"/"performance"/"auto"). Migrated to
        // `renderScale`. Decoded as a plain String so an unknown value can't fail
        // the whole load.
        var renderQuality: String? = nil
        var showCursorInCapture = false
        var customCursor = false
        var frameRatePolicy: FrameRatePolicy = .matchDisplay
        var reduceMotion = false
        var menuBarShowsPerformance = true
        // Optional so older settings files (which lack the key) decode to nil and
        // fall back to the default below, rather than failing the whole decode.
        var coverMenuBarAndDock: Bool? = true
        var fuseColorPasses: Bool? = true
        var favoriteEffectIDs: [String] = []
        // Optional so settings files written before versioning (which lack the key)
        // decode to nil and trigger the migration; new installs default to current.
        var schemaVersion: Int? = SettingsStore.currentSchemaVersion
    }

    init() {
        let loaded = JSONStore.load(State.self, from: AppPaths.settingsFile)
        var state = loaded ?? State()

        // One-time migration to v4: adopt a continuous renderScale, carrying over a
        // legacy discrete rung. A later deliberate change sticks. (The old "auto" rung
        // maps to Native; auto-calibration has since been removed.)
        var migrated = false
        if (state.schemaVersion ?? 1) < Self.currentSchemaVersion {
            if state.renderScale == nil {
                switch state.renderQuality {
                case "high":        state.renderScale = 0.85
                case "balanced":    state.renderScale = 0.70
                case "performance": state.renderScale = 0.50
                default:            state.renderScale = 1.0   // "native"/"auto"/absent → Native
                }
            }
            state.schemaVersion = Self.currentSchemaVersion
            migrated = true
        }

        startEnabledOnLaunch = state.startEnabledOnLaunch
        renderScale = Swift.min(RenderScale.max, Swift.max(RenderScale.min, state.renderScale ?? 1.0))
        showCursorInCapture = state.showCursorInCapture
        customCursor = state.customCursor
        frameRatePolicy = state.frameRatePolicy
        reduceMotion = state.reduceMotion
        menuBarShowsPerformance = state.menuBarShowsPerformance
        coverMenuBarAndDock = state.coverMenuBarAndDock ?? true
        fuseColorPasses = state.fuseColorPasses ?? true
        favoriteEffectIDs = Set(state.favoriteEffectIDs)

        if migrated { persist() }   // write the migrated values back once
    }

    func isFavorite(_ id: String) -> Bool { favoriteEffectIDs.contains(id) }

    func toggleFavorite(_ id: String) {
        if favoriteEffectIDs.contains(id) { favoriteEffectIDs.remove(id) }
        else { favoriteEffectIDs.insert(id) }
    }

    private func persist() {
        guard !isLoading else { return }
        let state = State(
            startEnabledOnLaunch: startEnabledOnLaunch,
            renderScale: renderScale,
            showCursorInCapture: showCursorInCapture,
            customCursor: customCursor,
            frameRatePolicy: frameRatePolicy,
            reduceMotion: reduceMotion, menuBarShowsPerformance: menuBarShowsPerformance,
            coverMenuBarAndDock: coverMenuBarAndDock,
            fuseColorPasses: fuseColorPasses,
            favoriteEffectIDs: favoriteEffectIDs.sorted())
        try? JSONStore.save(state, to: AppPaths.settingsFile)
    }
}
