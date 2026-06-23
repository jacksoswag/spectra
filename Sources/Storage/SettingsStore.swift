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
    /// Adaptive quality: when on, the engine governs `renderScale` automatically to
    /// hold a target frame rate (lowering it under sustained load, raising it back
    /// when there's headroom) instead of the fixed slider. The menu-bar "Auto" toggle.
    var autoQuality: Bool { didSet { persist() } }
    var showCursorInCapture: Bool { didSet { persist() } }
    /// Global cursor override (MAOE §6). When set, it wins over the active world's
    /// `world.cursor`; when nil, the world default (or the system cursor) applies. Persisted
    /// so it survives relaunch.
    var cursorOverride: CursorSpec? { didSet { persist() } }
    /// Legacy "draw a stylized cursor through the chain" toggle, now expressed through
    /// `cursorOverride` (system style at full intensity = the old behaviour). Kept as a
    /// computed accessor so existing call sites and the simple toggle UI keep working.
    var customCursor: Bool {
        get { (cursorOverride?.intensity ?? .none) != .none }
        set { cursorOverride = newValue ? CursorSpec(style: .system, intensity: .full) : nil }
    }
    var frameRatePolicy: FrameRatePolicy { didSet { persist() } }
    var reduceMotion: Bool { didSet { persist() } }
    /// Global on/off for the §15 engine capabilities. Each world still opts in via `WorldSpec`,
    /// so these gate but never force the feature on. Audio + keyboard need their own grants
    /// (Screen Recording for audio; Input Monitoring for keyboard — degrades gracefully).
    var audioReactiveEnabled: Bool { didSet { persist() } }
    var keyboardReactiveEnabled: Bool { didSet { persist() } }
    var focusSpotlightEnabled: Bool { didSet { persist() } }
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
    /// The menu-bar Glass toggle: window transparency + the adaptive desktop tint, driven
    /// directly via `SystemEffectsController` (independent of the main effects switch and the
    /// effect stack). Persisted so it stays where you left it.
    var glassEnabled: Bool { didSet { persist() } }
    /// Per-element Glass controls (the Studio "Glass" tab). Each drives one
    /// `SystemEffectsController` subsystem directly, independent of the main effects
    /// switch and the effect stack — the same standalone path as `glassEnabled`. The two
    /// style fields hold the chosen `MenuBarStyle` / `DockStyle` index (0 = None = off).
    var glassTransparency: Bool { didSet { persist() } }
    var glassTiling: Bool { didSet { persist() } }
    var glassTint: Bool { didSet { persist() } }
    var glassMenuBarStyleIndex: Int { didSet { persist() } }
    var glassDockStyleIndex: Int { didSet { persist() } }
    /// Make the overlay visible to external screen capture (system Screenshot UI /
    /// `screencapture`, third-party recorders) by flipping its `sharingType` from
    /// `.none` to `.readOnly`. On by default so screenshots and recordings include the
    /// effect. Spectra's own capture excludes the overlay by whole-app exclusion, not
    /// `sharingType`, so this is always feedback-safe regardless of the value.
    var showInScreenshots: Bool { didSet { persist() } }
    /// Whether the first-run welcome has been shown. Set once and never reset by
    /// "Reset to Defaults" (it tracks a one-time event, not a preference).
    var hasSeenWelcome: Bool { didSet { persist() } }
    /// Whether the one-time "how to draw / erase" sketch help has been shown. Set once and never
    /// reset by "Reset to Defaults" (it tracks a one-time event, not a preference).
    var hasSeenSketchHelp: Bool { didSet { persist() } }
    /// Global effect intensity (0…1), the master strength of the whole shader.
    /// 100% (the default) is the look the presets ship at; `SpectraEngine` maps this
    /// linearly to a per-effect strength multiplier (1.0 → 1.0×, 0 → 0×) applied at
    /// render time, so changing it never edits the stack.
    var intensity: Double { didSet { persist() } }

    /// Effect descriptor ids the user has starred in the library.
    private(set) var favoriteEffectIDs: Set<String> { didSet { persist() } }

    @ObservationIgnored private var isLoading = false

    /// Bumped when stored settings need a one-time migration on load.
    /// v2: introduced the (now-superseded) Adaptive Quality bool, off by default.
    /// v3: introduced a discrete `renderQuality` rung (native/high/balanced/…).
    /// v4: replaced it with a continuous `renderScale` (plus a since-removed
    ///     `autoCalibrate`, now ignored on load).
    /// v5: introduced a global `intensity` (then default 0.7 = the look the presets ship at).
    /// v6: `intensity` default moved to 1.0 and its render curve became linear (100% =
    ///     authored look, no +30% overdrive past 70%); stored values are remapped so the
    ///     rendered strength is preserved.
    /// v7: replaced the `customCursor` bool with a richer `cursorOverride` (CursorSpec). A
    ///     stored `customCursor == true` migrates to `system`/`full` (preserves "draw the real
    ///     cursor through effects"); `false` migrates to no override (defer to the world).
    private static let currentSchemaVersion = 8

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
        // Optional so older files (which lack the key) decode to nil and adopt the
        // on-by-default below.
        var autoQuality: Bool? = true
        var showCursorInCapture = false
        var customCursor = false   // legacy ≤ v6; migrated to `cursorOverride` at v7
        var cursorOverride: CursorSpec? = nil
        var audioReactiveEnabled: Bool? = false
        var keyboardReactiveEnabled: Bool? = false
        var focusSpotlightEnabled: Bool? = false
        var frameRatePolicy: FrameRatePolicy = .matchDisplay
        var reduceMotion = false
        var menuBarShowsPerformance = true
        // Optional so older settings files (which lack the key) decode to nil and
        // fall back to the default below, rather than failing the whole decode.
        var coverMenuBarAndDock: Bool? = true
        var fuseColorPasses: Bool? = true
        var glassEnabled: Bool? = false
        var glassTransparency: Bool? = false
        var glassTiling: Bool? = false
        var glassTint: Bool? = false
        var glassMenuBarStyleIndex: Int? = 0
        var glassDockStyleIndex: Int? = 0
        var showInScreenshots: Bool? = true
        var hasSeenWelcome: Bool? = false
        var hasSeenSketchHelp: Bool? = false
        // Optional so files written before v5 decode to nil and adopt the 100%
        // default (which reproduces the presets' shipped look). Values from v5 are
        // remapped onto the new linear curve during migration.
        var intensity: Double? = nil
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
            // v6: the Intensity slider's old curve made 70% the authored look and
            // overdrove up to 1.3× past it. The new curve is linear with 100% as the
            // authored look. Remap any stored value so the rendered strength is
            // preserved (old 0.7 → 1.0); anything that overdrove past 1.0× clamps to 100%.
            if let stored = state.intensity {
                state.intensity = Swift.min(1.0, stored / 0.7)
            }
            // v8: the old v7 migration forced a `.system` cursor override for legacy customCursor
            // users. That override wins over every world in resolveCursorSpec(), so it silently
            // shadowed each world's own sprite cursor — the world cursors never showed. A global
            // "force the system cursor everywhere" was never an intentional user choice, so clear
            // it; worlds drive the cursor by default, and the user can still pick a global override
            // explicitly in Settings.
            if let ov = state.cursorOverride, case .system = ov.style {
                state.cursorOverride = nil
            }
            state.schemaVersion = Self.currentSchemaVersion
            migrated = true
        }

        startEnabledOnLaunch = state.startEnabledOnLaunch
        renderScale = Swift.min(RenderScale.max, Swift.max(RenderScale.min, state.renderScale ?? 1.0))
        autoQuality = state.autoQuality ?? true
        showCursorInCapture = state.showCursorInCapture
        cursorOverride = state.cursorOverride
        audioReactiveEnabled = state.audioReactiveEnabled ?? false
        keyboardReactiveEnabled = state.keyboardReactiveEnabled ?? false
        focusSpotlightEnabled = state.focusSpotlightEnabled ?? false
        frameRatePolicy = state.frameRatePolicy
        reduceMotion = state.reduceMotion
        menuBarShowsPerformance = state.menuBarShowsPerformance
        coverMenuBarAndDock = state.coverMenuBarAndDock ?? true
        fuseColorPasses = state.fuseColorPasses ?? true
        glassEnabled = state.glassEnabled ?? false
        glassTransparency = state.glassTransparency ?? false
        glassTiling = state.glassTiling ?? false
        glassTint = state.glassTint ?? false
        glassMenuBarStyleIndex = state.glassMenuBarStyleIndex ?? 0
        glassDockStyleIndex = state.glassDockStyleIndex ?? 0
        showInScreenshots = state.showInScreenshots ?? true
        hasSeenWelcome = state.hasSeenWelcome ?? false
        hasSeenSketchHelp = state.hasSeenSketchHelp ?? false
        intensity = Swift.min(1.0, Swift.max(0.0, state.intensity ?? 1.0))
        favoriteEffectIDs = Set(state.favoriteEffectIDs)

        if migrated { persist() }   // write the migrated values back once
    }

    /// Restore every setting to its shipped default (the Settings "Reset to Defaults"
    /// action). Favourites are preserved — they're user content, not a preference.
    /// Persists once at the end rather than on each field's didSet.
    func resetToDefaults() {
        isLoading = true
        let d = State()
        startEnabledOnLaunch = d.startEnabledOnLaunch
        renderScale = d.renderScale ?? 1.0
        autoQuality = d.autoQuality ?? true
        showCursorInCapture = d.showCursorInCapture
        cursorOverride = d.cursorOverride
        audioReactiveEnabled = d.audioReactiveEnabled ?? false
        keyboardReactiveEnabled = d.keyboardReactiveEnabled ?? false
        focusSpotlightEnabled = d.focusSpotlightEnabled ?? false
        frameRatePolicy = d.frameRatePolicy
        reduceMotion = d.reduceMotion
        menuBarShowsPerformance = d.menuBarShowsPerformance
        coverMenuBarAndDock = d.coverMenuBarAndDock ?? true
        fuseColorPasses = d.fuseColorPasses ?? true
        glassEnabled = d.glassEnabled ?? false
        glassTransparency = d.glassTransparency ?? false
        glassTiling = d.glassTiling ?? false
        glassTint = d.glassTint ?? false
        glassMenuBarStyleIndex = d.glassMenuBarStyleIndex ?? 0
        glassDockStyleIndex = d.glassDockStyleIndex ?? 0
        showInScreenshots = d.showInScreenshots ?? true   // match the shipped default (State + init)
        intensity = d.intensity ?? 1.0
        isLoading = false
        persist()
    }

    func isFavorite(_ id: String) -> Bool { favoriteEffectIDs.contains(id) }

    func toggleFavorite(_ id: String) {
        if favoriteEffectIDs.contains(id) { favoriteEffectIDs.remove(id) }
        else { favoriteEffectIDs.insert(id) }
    }

    /// Last settings-write failure (nil when the last write succeeded), surfaced so a lost write
    /// doesn't silently drop the user's preferences. Mirrors `LicenseManager.persistError`.
    private(set) var persistError: String?

    private func persist() {
        guard !isLoading else { return }
        let state = State(
            startEnabledOnLaunch: startEnabledOnLaunch,
            renderScale: renderScale,
            autoQuality: autoQuality,
            showCursorInCapture: showCursorInCapture,
            cursorOverride: cursorOverride,
            audioReactiveEnabled: audioReactiveEnabled,
            keyboardReactiveEnabled: keyboardReactiveEnabled,
            focusSpotlightEnabled: focusSpotlightEnabled,
            frameRatePolicy: frameRatePolicy,
            reduceMotion: reduceMotion, menuBarShowsPerformance: menuBarShowsPerformance,
            coverMenuBarAndDock: coverMenuBarAndDock,
            fuseColorPasses: fuseColorPasses,
            glassEnabled: glassEnabled,
            glassTransparency: glassTransparency,
            glassTiling: glassTiling,
            glassTint: glassTint,
            glassMenuBarStyleIndex: glassMenuBarStyleIndex,
            glassDockStyleIndex: glassDockStyleIndex,
            showInScreenshots: showInScreenshots,
            hasSeenWelcome: hasSeenWelcome,
            hasSeenSketchHelp: hasSeenSketchHelp,
            intensity: intensity,
            favoriteEffectIDs: favoriteEffectIDs.sorted())
        do {
            try JSONStore.save(state, to: AppPaths.settingsFile)
            persistError = nil
        } catch {
            persistError = error.localizedDescription
            Log.storage.error("Settings write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
