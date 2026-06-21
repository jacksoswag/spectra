import Foundation
import AppKit
import Metal
import Observation
import QuartzCore
import ScreenCaptureKit

/// The application's central coordinator. Owns every subsystem (capture, render,
/// effects, presets, performance, storage, editor) and wires them together,
/// delegating real work rather than implementing it. The single object the UI
/// observes and drives.
@MainActor
@Observable
final class SpectraEngine {
    // Subsystems (dependency-injected throughout the UI).
    let context: MetalContext
    let renderEngine: RenderEngine
    let displayManager: DisplayManager
    let registry: EffectRegistry
    let presets: PresetLibrary
    let settings: SettingsStore
    let performance: PerformanceMonitor
    let compiler: ShaderCompiler
    let customShaders: CustomShaderStore
    let composedEffects: ComposedEffectStore
    let importer: ShaderImporter
    let thumbnailRenderer: ThumbnailRenderer
    let chainProfiler: ChainProfiler
    let wallpaper: WallpaperProvider

    // Observable state. A single `isEnabled` flag is the one source of truth for
    // "are effects running" — there is no separate pause or per-display gate. The
    // green/red transport button, the menu-bar item, and the ⌘⇧E command all toggle
    // exactly this. (The old per-display enable silently overrode the master switch:
    // a display left disabled made "turn on" appear to do nothing.)
    private(set) var isEnabled = false
    private(set) var permissionAuthorized = false
    var selectedDisplayID: CGDirectDisplayID? { didSet { updatePipelines(); saveState() } }
    private(set) var displays: [DisplayInfo] = []
    private(set) var startupError: String?

    @ObservationIgnored private var resolver: ChainResolver
    @ObservationIgnored private var stacks: [CGDirectDisplayID: EffectStack] = [:]
    /// Render-ready chain per display, resolved once on change (not per frame) and
    /// shared by the overlay and the live preview.
    @ObservationIgnored private var resolvedChains: [CGDirectDisplayID: [ResolvedEffect]] = [:]
    @ObservationIgnored private var sessions: [CGDirectDisplayID: CaptureSession] = [:]
    @ObservationIgnored private var appliedScale: [CGDirectDisplayID: Double] = [:]

    // Post-Space-switch capture-stall watchdog. A Space carry can leave the SCStream silently
    // emitting only non-`.complete` frames (or none) without ever calling `didStopWithError`,
    // so `handleSessionStopped` never restarts it and the overlay freezes on a stale frame
    // until the user toggles the effect off/on. Once a Space transition settles the captured
    // content has definitely changed, so a healthy stream MUST deliver a fresh frame within the
    // grace period; if a display's frame count hasn't advanced by then, its stream stalled and
    // is restarted. Scoped to the post-switch window so a genuinely static desktop (which
    // legitimately delivers no frames) is never restarted. `deadline == 0` means disarmed.
    @ObservationIgnored private var captureStallBaseline: [CGDirectDisplayID: UInt64] = [:]
    @ObservationIgnored private var captureStallDeadline: CFTimeInterval = 0
    private static let captureStallGracePeriod: CFTimeInterval = 1.5

    // Hard-freeze failsafe. The window-tied render clock (CAMetalDisplayLink) can stop delivering
    // callbacks after a Space carry/elevation; the overlay then freezes on a stale frame while
    // capture keeps delivering fresh ones. Because the overlay is opaque at shielding level it
    // covers the ENTIRE screen, so a freeze traps the user behind a dead image with no visible
    // way out (the owner had to restart the machine). This detects the exact signature — capture
    // frame count advancing while the present count stays flat — and recreates the overlay (the
    // same teardown+rebuild that toggling the effect does, which the owner confirmed unfreezes
    // it), so a freeze self-heals instead of trapping the screen. If it recurs several times in a
    // short window it disables the overlay outright rather than thrash a recreate loop.
    @ObservationIgnored private var lastCaptureCount: [CGDirectDisplayID: UInt64] = [:]
    @ObservationIgnored private var lastPresentCount: [CGDirectDisplayID: UInt64] = [:]
    @ObservationIgnored private var presentStuckSince: [CGDirectDisplayID: CFTimeInterval] = [:]
    @ObservationIgnored private var freezeRecoveries: [CGDirectDisplayID: [CFTimeInterval]] = [:]
    /// Seconds of "capture advancing, nothing presented" before the overlay is judged frozen.
    private static let hardFreezeSeconds: CFTimeInterval = 2.0

    // Adaptive quality governor (the menu-bar "Auto" toggle). When `settings.autoQuality`
    // is on, the engine owns the render scale via `autoScale` instead of the fixed Quality
    // slider. It targets GPU TIME, not fps: render scale only moves GPU cost (it's a
    // pixel-count lever), so reacting to GPU time keeps the loop honest. fps can fall for
    // reasons render scale can't touch — an erratic display-link callback rate, the window
    // server throttling the overlay on battery — and keying on fps made the governor ratchet
    // quality down chasing a drop that wasn't GPU-bound. So it lowers only when smoothed GPU
    // time sustains over the frame budget, raises when there's real GPU headroom, and holds
    // in between. State is touched only on the main-actor tick.
    /// Observed (not `@ObservationIgnored`) so the menu-bar Quality bar tracks the
    /// governor live as it adjusts; reads go through `effectiveRenderScale`.
    private var autoScale = 1.0
    /// Exponential moving average of GPU ms, so a single spike/dip doesn't whip the scale.
    @ObservationIgnored private var smoothedGPUMilliseconds: Double = 0
    /// `CACurrentMediaTime()` when GPU time first sustained over budget this episode (0 = no).
    @ObservationIgnored private var autoUnderSince: Double = 0
    /// `CACurrentMediaTime()` when GPU time first showed sustained headroom (0 = no).
    @ObservationIgnored private var autoAboveSince: Double = 0
    /// `CACurrentMediaTime()` of the last scale change, so a reconfigure + stats reset can
    /// settle before the next decision.
    @ObservationIgnored private var lastAutoAdjust: Double = 0

    /// Frame rate the governor protects. The GPU thresholds below are derived from it.
    private static let autoTargetFPS = 54.0
    /// GPU ms above which a frame can't hold the target (budget minus headroom for the
    /// present + CPU encode): start lowering. ≈ 1000/54 − 2.5 ≈ 16 ms.
    private static let autoGPULowerMs = 16.0
    /// GPU ms below which there's clear headroom to spend on resolution: start raising.
    /// A wide dead band [raise, lower] keeps the scale from hunting.
    private static let autoGPURaiseMs = 12.0
    /// Sustained seconds over budget before the first quality cut.
    private static let autoUnderGrace = 5.0
    /// Quiet period after any change (covers the capture reconfigure + stats rebuild).
    private static let autoAdjustCooldown = 2.5
    /// Sustained seconds of GPU headroom before each step back up.
    private static let autoRaiseHold = 10.0
    /// Additive step when raising — small, so recovering can't bounce back over budget.
    private static let autoRaiseStep = 0.05
    /// EMA weight for new GPU samples (tick is 0.5s, so ≈1.5s time constant).
    private static let autoGPUSmoothing = 0.3
    @ObservationIgnored private let startHostTime = CACurrentMediaTime()
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var gpuFaultCounts: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored private var folderWatcher: FolderWatcher?
    @ObservationIgnored private var importedFileDates: [URL: Date] = [:]
    /// Process-wide panic switch. When the overlay covers the menu bar/Dock the
    /// status item is hidden, so this is the guaranteed way to turn it off.
    @ObservationIgnored private var globalPanicHotKey: GlobalHotKey?
    @ObservationIgnored private var globalToggleHotKey: GlobalHotKey?

    /// Global color grading via the scanout transfer LUT. A display whose chain is
    /// made up ENTIRELY of per-channel color effects is rendered here — above the
    /// whole Space system, with no capture or overlay — instead of through the
    /// overlay engine. `gradeDisplays` is the set currently routed this way; it gates
    /// `wantsOverlay` so those displays don't ALSO run the overlay (double-grading).
    @ObservationIgnored private lazy var displayGrade = DisplayGrade()
    @ObservationIgnored private lazy var gradeExtractor =
        GradeLUTExtractor(context: context, shaders: renderEngine.shaders)
    @ObservationIgnored private var gradeDisplays: Set<CGDirectDisplayID> = []

    /// Drives the system effects — window transparency and layout (via yabai) and the
    /// adaptive tint overlay. Reconciled from the union of every display's stack
    /// whenever a chain changes or the master switch flips, and restored on disable/quit.
    @ObservationIgnored private lazy var systemEffects = SystemEffectsController()
    /// Latest yabai provisioning status, surfaced to the inspector so the yabai-backed
    /// system-effect rows can reflect install / admin-prompt / SIP / ready state.
    private(set) var systemEffectsStatus: YabaiProvisioner.Status = .unknown

    /// Effects whose transfer is per-channel separable — exactly reproducible by a
    /// scanout LUT (verified against their `colorproc_*` math). Cross-channel ops
    /// (saturation, vibrance, highlights/shadows/whites/blacks, temperature/tint's
    /// luma-preservation, sepia, color balance, hue, channel mixer, gradient map, 3D
    /// LUT) are deliberately absent: a gray-ramp evaluation can't capture them, so
    /// they stay on the overlay.
    private static let globalGradeEffectIDs: Set<String> = [
        "color.brightness", "color.contrast", "color.exposure", "color.gamma",
        "color.blackPoint", "color.whitePoint", "color.invert", "color.posterize",
        "color.solarize", "color.levels",
    ]

    /// Spectra's own control windows (the Studio and Settings), tracked once they
    /// appear (see `ControlWindowConfigurator`) so their `SCWindow`s can be excepted
    /// from the capture exclusion and rendered through the effect chain. Held weakly so
    /// closed windows drop out automatically.
    @ObservationIgnored private let controlWindows = NSHashTable<NSWindow>.weakObjects()
    /// The Studio window specifically, so the menu/Dock reopen paths can surface it
    /// even when SwiftUI brings back the existing singleton without re-running the
    /// registration hook.
    @ObservationIgnored private weak var studioWindow: NSWindow?

    /// Surfaced to the UI when Spectra auto-disables a faulting custom effect.
    private(set) var lastRecoveryMessage: String?

    /// The most relevant transient status for the UI banner: a launch/capture
    /// failure takes priority over an auto-recovery notice.
    var statusMessage: String? { startupError ?? lastRecoveryMessage }

    /// Dismiss the status banner (clears both the launch error and the recovery notice).
    func dismissStatusMessage() {
        startupError = nil
        lastRecoveryMessage = nil
    }

    /// Name of the preset last applied per display, cleared once that display's
    /// stack is edited by hand. Each display tracks its own preset.
    private(set) var activePresetByDisplay: [CGDirectDisplayID: String] = [:]
    @ObservationIgnored private var isApplyingPreset = false

    /// The active preset name for the currently targeted display (menu bar).
    var activePresetName: String? { selectedDisplayID.flatMap { activePresetName(for: $0) } }

    /// The active preset name for a specific display — derived from what the live
    /// stack actually contains, not from a stored label. The name shows only while
    /// the stack still matches that preset; editing the stack (or starting empty)
    /// clears it to nil. This is what makes the menu reflect the *current* preset
    /// instead of a stale persisted one (e.g. "CRT Monitor" lingering on launch).
    func activePresetName(for displayID: CGDirectDisplayID) -> String? {
        guard let chain = stacks[displayID]?.chain() else { return nil }
        return presets.matchingPreset(for: chain)?.name
    }

    var shaderLibrary: ShaderLibrary { renderEngine.shaders }

    init() throws {
        context = try MetalContext()
        registry = EffectRegistry()
        renderEngine = RenderEngine(context: context)
        displayManager = DisplayManager()
        settings = SettingsStore()
        presets = PresetLibrary()
        performance = PerformanceMonitor()
        compiler = ShaderCompiler(context: context)
        customShaders = CustomShaderStore(context: context, compiler: compiler, registry: registry)
        composedEffects = ComposedEffectStore(registry: registry)
        importer = ShaderImporter(compiler: compiler)
        thumbnailRenderer = ThumbnailRenderer(context: context, shaders: renderEngine.shaders)
        chainProfiler = ChainProfiler(context: context, shaders: renderEngine.shaders)
        wallpaper = WallpaperProvider(device: context.device)
        resolver = ChainResolver(
            registry: registry, composedStore: composedEffects,
            auxFactory: AuxTextureFactory(device: context.device))
        resolver.fuseColorPasses = settings.fuseColorPasses

        performance.device = context.device
    }

    /// Toggle pointwise colour-pass fusion. Re-resolves every chain so the change
    /// takes effect immediately.
    func setFuseColorPasses(_ on: Bool) {
        settings.fuseColorPasses = on
        resolver.fuseColorPasses = on
        for id in stacks.keys { rebuildResolvedChain(for: id) }
    }

    /// The capture/render scale for a display: the governor's value when Auto is on,
    /// otherwise the user's fixed Quality slider value.
    private func captureScale(for display: DisplayInfo) -> Double {
        settings.autoQuality ? autoScale : settings.renderScale
    }

    /// The render scale currently in effect, for display in the UI — the governor's live
    /// value while Auto is on, otherwise the user's Quality slider. `@ObservationIgnored`
    /// `autoScale` isn't observed, so the menu-bar tick (which re-reads this each refresh)
    /// is what keeps the shown value current while Auto adjusts.
    var effectiveRenderScale: Double { settings.autoQuality ? autoScale : settings.renderScale }

    // MARK: - Lifecycle

    @ObservationIgnored private var didBootstrap = false

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        // Let the cursor enforcer tell the overlay (rendered cursor) apart from the menu
        // bar / dropdowns above it, so the real cursor shows over the latter only.
        cursorEnforcer.isOverlayWindow = { [weak self] number in
            self?.renderEngine.overlayWindowNumbers.contains(number) ?? false
        }
        // Except the menu-bar popover into the capture while it's open, so the dropdown
        // renders through the chain instead of being painted over by the opaque overlay (it's
        // our own window, excluded with the rest of the app, and — unlike Studio/Settings —
        // never registered as a control window). Mirrors the cursor enforcer's discriminators.
        menuPanelCaptureBridge.isOverlayWindow = { [weak self] number in
            self?.renderEngine.overlayWindowNumbers.contains(number) ?? false
        }
        menuPanelCaptureBridge.isControlWindow = { [weak self] window in
            self?.controlWindows.contains(window) ?? false
        }
        menuPanelCaptureBridge.onPanelVisibilityChanged = { [weak self] window in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuPanelWindow = window
                self.refreshCaptureExceptions()   // start/stop rendering it through the chain
            }
        }
        menuPanelCaptureBridge.start()
        // Let the render engine neutralize the control windows' Space-migrate flag during
        // a Space swipe (they'd otherwise snap the gesture back) and wake capture once it
        // settles.
        renderEngine.controlWindowsProvider = { [weak self] in
            self?.controlWindows.allObjects ?? []
        }
        renderEngine.onActiveSpaceSettled = { [weak self] in
            self?.refreshCaptureExceptions()
            self?.armCaptureStallWatchdog()   // catch a stream that silently stalled on the carry
        }
        // SwiftUI's ColorPicker opens the shared NSColorPanel, which is born at a normal window
        // level — behind the elevated overlay, so clicking a colour swatch looks like nothing
        // happens. When it becomes key, register it like a control window so it's lifted crisp
        // ABOVE the overlay (and follows Space switches). Every colour parameter shares this one
        // panel, so this fixes all of them at once.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let panel = note.object as? NSColorPanel else { return }
            MainActor.assumeIsolated { self?.registerControlWindow(panel) }
        }
        AppPaths.ensureDirectories()
        displayGrade.clearStaleGradeAtLaunch()   // reset any scanout LUT a prior crash left installed
        permissionAuthorized = ScreenRecordingPermission.isAuthorized
        await displayManager.refresh()
        permissionAuthorized = displayManager.permissionAuthorized
        displays = displayManager.displays

        let wasEnabled = loadState()
        if selectedDisplayID == nil || displays.first(where: { $0.id == selectedDisplayID }) == nil {
            selectedDisplayID = displayManager.mainDisplay?.id
        }
        displayManager.onChange = { [weak self] in self?.handleDisplaysChanged() }

        // Restore the last master on/off state (quit-with-effects-on returns enabled),
        // or honour the always-start-enabled preference. Either way only auto-starts
        // when Screen Recording is already granted.
        if (settings.startEnabledOnLaunch || wasEnabled) && permissionAuthorized {
            isEnabled = true
        }
        autoScale = settings.renderScale   // governor starts from the saved quality if Auto is on
        // System effects: forward the adaptive-tint windows into the capture-exception
        // path and surface yabai availability to the inspector. `updatePipelines` below
        // reconciles the actual state, so these hooks must be set first.
        systemEffects.onCaptureExceptionsChanged = { [weak self] in self?.refreshCaptureExceptions() }
        systemEffects.onStatusChanged = { [weak self] status in self?.systemEffectsStatus = status }
        systemEffects.refreshStatus(needsOpacity: true)
        updatePipelines()
        startRefreshTimer()
        startFolderWatch()
        registerGlobalPanicHotKey()
        registerGlobalToggleHotKey()
        // A Dock-icon reopen raises the Studio above the overlay (it's a SwiftUI
        // singleton window that reopening surfaces without re-registering).
        NotificationCenter.default.addObserver(
            forName: .spectraReopen, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontStudioWindow() }
        }
    }

    /// Register ⌃⌥⌘S as a global "turn the overlay off" panic switch. It works even
    /// when Spectra is not frontmost and when the overlay covers the menu-bar item,
    /// which is what makes "Cover menu bar & Dock" safe to ship on by default. It
    /// only ever *disables* (never toggles), so mashing it cannot re-arm a screen
    /// you just escaped from.
    private func registerGlobalPanicHotKey() {
        guard globalPanicHotKey == nil else { return }
        globalPanicHotKey = GlobalHotKey.panicSwitch { [weak self] in
            MainActor.assumeIsolated { self?.disable() }
        }
        if globalPanicHotKey == nil {
            Log.render.error("Could not register the global panic hotkey (\(GlobalHotKey.panicSwitchLabel, privacy: .public)); the chord may be taken.")
        }
    }

    /// Register ⌥⌘P as a global pause/unpause chord, so effects can be toggled without
    /// Spectra being frontmost. Unlike the panic switch it toggles both ways.
    private func registerGlobalToggleHotKey() {
        guard globalToggleHotKey == nil else { return }
        globalToggleHotKey = GlobalHotKey.toggle { [weak self] in
            MainActor.assumeIsolated { self?.toggleEnabled() }
        }
        if globalToggleHotKey == nil {
            Log.render.error("Could not register the global pause hotkey (\(GlobalHotKey.toggleLabel, privacy: .public)); the chord may be taken.")
        }
    }

    func shutdown() {
        refreshTimer?.invalidate()
        folderWatcher?.stop()
        globalPanicHotKey = nil   // unregisters the Carbon hotkey
        globalToggleHotKey = nil  // unregisters the Carbon hotkey
        displayGrade.clearAll()   // restore every display's colour profile (scanout LUT)
        systemEffects.shutdown()  // restore window opacity/tiling synchronously + remove the tint
        cursorEnforcer.setHidden(false)   // restores the cursor + removes the motion monitor
        for session in sessions.values { Task { await session.stop() } }
        renderEngine.shutdown()
    }

    func requestPermission() async {
        _ = ScreenRecordingPermission.request()
        await displayManager.refresh()
        permissionAuthorized = displayManager.permissionAuthorized
        displays = displayManager.displays
        updatePipelines()
    }

    func refreshDisplays() async {
        await displayManager.refresh()
        permissionAuthorized = displayManager.permissionAuthorized
        displays = displayManager.displays
        if displays.first(where: { $0.id == selectedDisplayID }) == nil {
            selectedDisplayID = displayManager.mainDisplay?.id
        }
        updatePipelines()
    }

    // MARK: - Master controls

    func enable() {
        if !permissionAuthorized {
            Task {
                await requestPermission()
                if permissionAuthorized { isEnabled = true; updatePipelines(); saveState() }
            }
            return
        }
        isEnabled = true
        updatePipelines()
        saveState()
    }

    func disable() {
        isEnabled = false
        updatePipelines()
        saveState()
    }

    func toggleEnabled() { isEnabled ? disable() : enable() }

    /// The capture + render frame rate for a display: the user's Frame Rate policy,
    /// but capped at 60. The opaque overlay's own present re-dirties the captured
    /// scene, so capturing/rendering faster than 60 just feeds the
    /// compositor→capture→render loop (sustained GPU load, no visible gain for these
    /// procedural effects). The user can still choose a lower cap.
    private func overlayFPS(forDisplayRefresh refresh: Double) -> Int {
        min(settings.frameRatePolicy.fps(forDisplayRefresh: refresh), 60)
    }

    /// Apply a new frame-rate policy live: cap the render rate on every active
    /// renderer (so animated effects stop running at the full display refresh) and
    /// reconfigure running capture sessions to match.
    func setFrameRatePolicy(_ policy: FrameRatePolicy) {
        settings.frameRatePolicy = policy
        for display in displays {
            let fps = overlayFPS(forDisplayRefresh: display.refreshRate)
            renderEngine.renderer(for: display.id)?.setPreferredFrameRate(fps)
            guard let session = sessions[display.id] else { continue }
            let scale = appliedScale[display.id] ?? 1.0
            let width = max(2, Int(Double(display.pixelWidth) * scale))
            let height = max(2, Int(Double(display.pixelHeight) * scale))
            Task { await session.reconfigure(pixelWidth: width, pixelHeight: height, fps: fps) }
        }
    }

    /// Toggle whether the hardware cursor is included in the capture, applying the
    /// change live to every running session. Routed through `applyCursorState()` so
    /// the setting is overridden whenever the custom cursor is effectively active
    /// (user opt-in *or* a warp chain): in that case the cursor is composited into the
    /// frame and must stay out of the capture regardless of this toggle.
    func setShowCursorInCapture(_ shows: Bool) {
        settings.showCursorInCapture = shows
        applyCursorState()
    }

    /// Descriptor IDs whose shader geometrically DISPLACES pixels (warps/curvature),
    /// detected by their use of spectra_compositeFull* in Metal (the codebase's marker
    /// for geometric effects). When any of these is active, the captured cursor warps,
    /// so we must hide the unwarped hardware cursor and composite the live cursor
    /// through the chain instead. Update this set if new geometric shaders are added.
    private static let geometricEffectIDs: Set<String> = [
        // Distortion.metal — every fx_distort_* returns spectra_compositeFullRGBA.
        "distortion.warp", "distortion.bulge", "distortion.pinch",
        "distortion.fishEye", "distortion.barrel", "distortion.chromatic",
        "distortion.heat", "distortion.wave", "distortion.ripple",
        "distortion.swirl", "distortion.shockwave", "distortion.perspective",
        // Retro.metal — only the curvature-bearing CRT shaders composite "full"
        // (fx_crt_crt, fx_crt_crtAdvanced, fx_crt_curvature). The flat retro looks
        // (scanlines, masks, NTSC/PAL, bloom, phosphor) use plain composite and do
        // not move pixels, so they are deliberately excluded.
        "retro.crt", "retro.crtAdvanced", "retro.curvature",
        // VHS.metal — the band/line-displacing tape artifacts composite "full"
        // (fx_vhs_tracking, _wrinkle, _headSwitch, _jitter, _roll, _damage,
        // _audioTracking). Pure color/noise VHS effects (chromaDrift, dropouts,
        // noiseBands, generationLoss, colorSmear) do not displace and are excluded.
        "vhs.tracking", "vhs.wrinkle", "vhs.headSwitch", "vhs.jitter",
        "vhs.roll", "vhs.damage", "vhs.audioTracking",
    ]

    /// Whether a display's live stack contains any ENABLED effect that geometrically
    /// warps pixels. Read from `stack(for:).effects` (not the resolved chain) so it
    /// reflects per-effect enable/disable the instant the user toggles it.
    private func chainWarpsGeometry(_ displayID: CGDirectDisplayID) -> Bool {
        stack(for: displayID).effects.contains {
            $0.isEnabled && Self.geometricEffectIDs.contains($0.descriptorID)
        }
    }

    /// Whether the custom-cursor pipeline (composite the live cursor through the chain
    /// + hide the hardware cursor) should be engaged. True when the user opted in via
    /// the setting, OR — even with the setting off — when any active overlay is running
    /// a warp effect: those warp the captured cursor, so leaving the unwarped hardware
    /// cursor on top produces the confusing double-cursor the user reported.
    private func effectiveCustomCursorActive() -> Bool {
        settings.customCursor
            || displays.contains { wantsOverlay($0.id) && chainWarpsGeometry($0.id) }
    }

    /// Toggle the stylized cursor: draw the cursor into the frame so it runs through
    /// the effect chain, and hide the hardware cursor. When on, the system cursor is
    /// also kept out of the capture so it isn't drawn twice.
    func setCustomCursor(_ on: Bool) {
        settings.customCursor = on
        applyCursorState()
    }

    /// Owns the hardware-cursor hide: a balanced `CGDisplayHideCursor`/`ShowCursor`
    /// pair plus a global motion monitor that re-asserts the hide so it holds across
    /// pointer movement, not only after a keystroke.
    @ObservationIgnored private let cursorEnforcer = CursorVisibilityEnforcer()

    /// Excepts the `MenuBarExtra(.window)` popover into the capture while it is open, so the
    /// dropdown renders through the chain like the Studio/Settings windows (and like every
    /// other app's dropdown) instead of being painted over by the opaque overlay.
    @ObservationIgnored private let menuPanelCaptureBridge = MenuPanelCaptureBridge()
    /// The menu-bar popover while it is open, excepted into the capture like a control window.
    /// Weak: it is a transient window owned by AppKit/SwiftUI, tracked only while visible.
    @ObservationIgnored private weak var menuPanelWindow: NSWindow?

    /// Push the effective custom-cursor state to every renderer, session, and the
    /// hardware cursor in one place. The effective state folds in the setting *and*
    /// auto-engagement for warp chains, so adding/removing a CRT/distortion effect
    /// (or toggling the setting) routes through here and stays consistent.
    private func applyCursorState() {
        let effective = effectiveCustomCursorActive()
        // One shared cursor sampler feeds every display's renderer (it reads AppKit on the main
        // thread and publishes a snapshot the off-main link thread reads), so engage it once.
        renderEngine.setCustomCursorEnabled(effective)
        // When the live cursor is composited into the frame it must be kept out of the
        // capture, or it is drawn twice; otherwise honour the user's capture setting.
        let effectiveShowsCursor = settings.showCursorInCapture && !effective
        let sessions = self.sessions.values
        Task { for session in sessions { await session.setShowsCursor(effectiveShowsCursor) } }
        updateCursorVisibility(effective: effective)
    }

    /// Hide the hardware cursor exactly while the stylized cursor is actively being
    /// drawn onto an overlay; show it again otherwise. The enforcer keeps the hide
    /// stuck while Spectra is in the background and re-asserts it on pointer motion,
    /// so the real cursor can't reappear doubled over the drawn one when the user
    /// works in (or moves the pointer into) another app.
    /// `effective` is the resolved custom-cursor state (setting OR warp auto-engage).
    private func updateCursorVisibility(effective: Bool) {
        let shouldHide = effective && permissionAuthorized && isEnabled
            && displays.contains { wantsOverlay($0.id) }
        cursorEnforcer.setHidden(shouldHide)
    }

    // MARK: - Control windows

    /// Called by a control window's view bridge once the window exists (the Studio
    /// and the Settings panes). Tracks it weakly, lets it cross Spaces, applies the
    /// correct level, and — if an overlay is already up — raises and keys it so it
    /// isn't born behind the overlay.
    func registerControlWindow(_ window: NSWindow) {
        if !controlWindows.contains(window) { controlWindows.add(window) }
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        // Lift it into the overlay's elevated Space one level ABOVE the overlay, and leave it out
        // of the capture (controlWindowSCWindows drops it), so it renders directly above the
        // shaded desktop without the capture round-trip.
        renderEngine.raiseControlWindowAboveOverlay(window)
        if window.identifier?.rawValue.contains("studio") ?? false { studioWindow = window }
        refreshCaptureExceptions()   // the control windows are excluded from capture
        guard displays.contains(where: { wantsOverlay($0.id) }) else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window, window.isVisible else { return }   // don't resurrect a closing window
            window.makeKeyAndOrderFront(nil)
            // makeKeyAndOrderFront can reset the level/Space, so re-assert crisp placement.
            self?.renderEngine.raiseControlWindowAboveOverlay(window)
        }
    }

    /// Surface the Studio and key it. The Studio is a SwiftUI singleton `Window`, so
    /// reopening it surfaces the existing instance *without* re-running
    /// `registerControlWindow`; the menu / Dock / reopen paths call this directly. It
    /// stays at its normal level (below the overlay) and is brought forward there, then
    /// re-added to the capture so it renders through the chain.
    func frontStudioWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.studioWindow, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            // Crisp mode: re-assert the Studio above the overlay (no-op in through-shader).
            self.renderEngine.raiseControlWindowAboveOverlay(window)
            self.refreshCaptureExceptions()
        }
    }

    /// Toggle whether effects cover the menu bar and Dock. Applies the new overlay
    /// level live; control windows sit below the overlay and need no re-pegging.
    func setCoverMenuBarAndDock(_ on: Bool) {
        settings.coverMenuBarAndDock = on
        renderEngine.setCoversMenuBarAndDock(on)
    }

    /// Toggle whether the overlay is visible to external screen capture (the system
    /// Screenshot UI / recorders). Off by default; flips every overlay's `sharingType`.
    func setShowInScreenshots(_ on: Bool) {
        settings.showInScreenshots = on
        renderEngine.setOverlaysVisibleToScreenshots(on)
    }

    /// Re-probe yabai status read-only (the inspector calls this when a yabai-backed system
    /// effect is shown, so install / SIP / ready state updates live without side effects).
    func refreshSystemEffectsStatus(needsOpacity: Bool) {
        systemEffects.refreshStatus(needsOpacity: needsOpacity)
    }

    // MARK: - Stacks

    func stack(for displayID: CGDirectDisplayID) -> EffectStack {
        if let existing = stacks[displayID] { return existing }
        let stack = EffectStack()
        stack.onChange = { [weak self] chain in self?.pushChain(chain, to: displayID) }
        stacks[displayID] = stack
        return stack
    }

    var activeStack: EffectStack? {
        guard let id = selectedDisplayID else { return nil }
        return stack(for: id)
    }

    private func pushChain(_ chain: EffectChain, to displayID: CGDirectDisplayID) {
        let resolved = resolver.resolve(chain)
        resolvedChains[displayID] = resolved
        renderEngine.updateChain(resolved, displayID: displayID)
        if !isApplyingPreset { activePresetByDisplay[displayID] = nil }
        // A warp effect may have been added/removed/toggled in this chain, which flips
        // whether the captured cursor warps — reconcile the cursor pipeline live.
        applyCursorState()
        // Keep global-grade routing current with the edited chain. If the display
        // crossed the grade↔overlay boundary (e.g. the last spatial effect was removed,
        // or a spatial effect was added to a colour-only stack), reconcile the whole
        // pipeline so the overlay+capture spin down or up accordingly; otherwise the
        // grade reconcile alone refreshes the LUT for live parameter edits.
        let wasGrade = gradeDisplays.contains(displayID)
        let wasOverlayActive = renderEngine.renderer(for: displayID)?.isActive ?? false
        reconcileGlobalGrade()
        // Re-reconcile the whole pipeline when this display crosses the grade boundary OR the
        // overlay boundary — e.g. the last pixel effect was removed leaving only system effects,
        // so capture + overlay should spin down (or vice versa).
        if gradeDisplays.contains(displayID) != wasGrade || wantsOverlay(displayID) != wasOverlayActive {
            updatePipelines()
        }
        // A system effect (transparency/layout/tint) may have been toggled or tuned in
        // this chain — drive yabai and the tint overlay to match.
        reconcileSystemEffects()
        saveState()
    }

    /// Re-resolve and re-push every active display's chain. Used after a custom
    /// shader is recompiled (live reload) so the GPU picks up the new library.
    func reresolveChains() {
        for id in renderEngine.activeDisplayIDs {
            rebuildResolvedChain(for: id)
        }
    }

    // MARK: - Library ↔ stack

    /// Whether the active display's stack contains at least one instance of this effect.
    func isInActiveStack(_ descriptorID: String) -> Bool {
        activeStack?.effects.contains { $0.descriptorID == descriptorID } ?? false
    }

    /// Toggle an effect's presence in the active stack: add one instance if none
    /// are present, remove all of its instances if any are.
    func toggleInActiveStack(_ descriptor: EffectDescriptor) {
        guard let stack = activeStack else { return }
        let existing = stack.effects.filter { $0.descriptorID == descriptor.id }
        if existing.isEmpty {
            stack.add(descriptor)
        } else {
            existing.forEach { stack.remove($0.id) }
        }
    }

    func addToActiveStack(_ descriptor: EffectDescriptor) {
        activeStack?.add(descriptor)
    }

    /// Delete a custom library effect (imported shader or composed effect) from
    /// the library and from every display's stack.
    func deleteCustomShader(_ id: String) {
        for stack in stacks.values {
            stack.effects.filter { $0.descriptorID == id }.forEach { stack.remove($0.id) }
        }
        if composedEffects.effect(for: id) != nil {
            composedEffects.remove(id)
        } else {
            customShaders.remove(id)
        }
        reresolveChains()
    }

    /// Save a composed effect to the library and refresh any live chains using it.
    func saveComposedEffect(_ effect: ComposedEffect) {
        composedEffects.upsert(effect)
        reresolveChains()
    }

    /// Resolve an arbitrary chain (used for the composer's live preview).
    func resolve(_ chain: EffectChain) -> [ResolvedEffect] { resolver.resolve(chain) }

    // MARK: - Profiling

    /// Measure real per-effect GPU cost of the active display's chain, on demand.
    func profileActiveChain() -> [EffectCost] {
        guard let id = selectedDisplayID,
              let display = displays.first(where: { $0.id == id }) else { return [] }
        return chainProfiler.profile(resolvedChain(for: id),
                                     width: display.pixelWidth, height: display.pixelHeight)
    }

    /// A static summary of the active pipeline (pass count, resolution, VRAM).
    func activePipelineSummary() -> PipelineSummary {
        let chain = selectedDisplayID.map { resolvedChain(for: $0) } ?? []
        let display = displays.first { $0.id == selectedDisplayID }
        return chainProfiler.summary(chain,
                                     width: display?.pixelWidth ?? 1920, height: display?.pixelHeight ?? 1080)
    }

    /// Reveal the shader/preset library folder in Finder.
    func openLibraryFolder() {
        AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.shadersDirectory)
    }

    // MARK: - Folder watching (drop-in shader import + hot reload)

    private func startFolderWatch() {
        AppPaths.ensureDirectories()
        scanShaderFolder()
        let watcher = FolderWatcher(url: AppPaths.shadersDirectory) { [weak self] in
            Task { @MainActor in self?.scanShaderFolder() }
        }
        watcher.start()
        folderWatcher = watcher
    }

    /// Import raw shader files (`.metal`, `.shader`) and packaged effects
    /// (`.spectra`) the user has dropped into the library folder. Files are keyed
    /// by modification date so an edited file re-imports (hot reload) and an
    /// unchanged one is skipped. `.json` is ignored here — that is the store's own
    /// on-disk format, managed separately.
    private func scanShaderFolder() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: AppPaths.shadersDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let watched: Set<String> = ["metal", "shader", "spectra"]
        for file in files where watched.contains(file.pathExtension.lowercased()) {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, importedFileDates[file] == mtime { continue }
            importedFileDates[file] = mtime
            importFromFolder(file)
        }
    }

    private func importFromFolder(_ url: URL) {
        do {
            switch try importer.importFile(at: url) {
            case .shader(var shader, _):
                shader.id = Self.stableID(for: url) ?? shader.id
                customShaders.upsert(shader)
            case .preset(let preset):
                // Dedupe: the same .spectra file produces the same Preset UUID on
                // every decode. Skip registration if that ID is already in the user
                // library, so re-importing on every launch (importedFileDates is
                // in-memory and resets on restart) never creates duplicate entries.
                guard !presets.user.contains(where: { $0.id == preset.id }) else { break }
                presets.add(preset)
            case .composed(let composed):
                composedEffects.upsert(composed)
            }
            reresolveChains()
            Log.editor.info("Imported dropped file \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.editor.error("Failed to import \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// A deterministic id derived from a file name, so re-dropping or editing the
    /// same file updates the existing library entry instead of duplicating it.
    private static func stableID(for url: URL) -> String? {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return base.isEmpty ? nil : "imported.\(base)"
    }

    // MARK: - Presets

    func apply(_ preset: Preset, to displayID: CGDirectDisplayID? = nil) {
        let target = displayID ?? selectedDisplayID
        guard let target else { return }
        isApplyingPreset = true
        stack(for: target).load(preset.chain)
        isApplyingPreset = false
        activePresetByDisplay[target] = preset.name
        presets.markRecent(preset)
    }

    @discardableResult
    func saveCurrentAsPreset(name: String, category: PresetCategory = .user,
                             summary: String = "", tags: [String] = []) -> Preset? {
        guard let stack = activeStack else { return nil }
        return presets.save(name: name, chain: stack.chain(), category: category, summary: summary, tags: tags)
    }

    // MARK: - Import / export

    enum ImportOutcome { case preset(Preset), shader(CustomShader), composed(ComposedEffect) }

    func importFile(at url: URL) throws -> ImportOutcome {
        switch try importer.importFile(at: url) {
        case .preset(let preset):
            presets.add(preset)
            return .preset(preset)
        case .shader(let shader, _):
            customShaders.upsert(shader)
            return .shader(shader)
        case .composed(let composed):
            composedEffects.upsert(composed)
            reresolveChains()
            return .composed(composed)
        }
    }

    // MARK: - Preview data

    /// Source texture for the Studio preview: the display's wallpaper, processed
    /// through the chain. Using the wallpaper (not a live capture) avoids the
    /// Studio window mirroring into its own preview.
    func previewInputTexture(for displayID: CGDirectDisplayID) -> MTLTexture? {
        wallpaper.texture(for: displayID)
    }

    /// The cached render-ready chain for a display. Resolved once when the chain
    /// changes — not re-resolved every frame — so the preview and overlay share one
    /// immutable snapshot. Re-resolving per frame churned aux textures and read the
    /// effect stack while a preset apply was mutating it.
    func resolvedChain(for displayID: CGDirectDisplayID) -> [ResolvedEffect] {
        if let cached = resolvedChains[displayID] { return cached }
        return rebuildResolvedChain(for: displayID)
    }

    @discardableResult
    private func rebuildResolvedChain(for displayID: CGDirectDisplayID) -> [ResolvedEffect] {
        let resolved = resolver.resolve(stack(for: displayID).chain())
        resolvedChains[displayID] = resolved
        renderEngine.updateChain(resolved, displayID: displayID)
        // Rebuilding a chain can change whether it warps (e.g. a custom effect was
        // disabled by fault recovery, or a preset/import swapped the stack), so keep
        // the cursor pipeline in sync. Cheap, and a no-op when nothing warps.
        applyCursorState()
        return resolved
    }

    func currentTime() -> Float { Float(CACurrentMediaTime() - startHostTime) }

    // MARK: - Pipeline reconciliation

    private func wantsOverlay(_ displayID: CGDirectDisplayID) -> Bool {
        // A display routed to the global grade is rendered by the scanout LUT, not the
        // overlay — running both would double-apply the grade on the current Space.
        // A stack of only system effects (or empty) has no pixel passes, so it needs no
        // capture or overlay at all: it runs at full quality and the display's refresh.
        isEnabled && permissionAuthorized && !gradeDisplays.contains(displayID)
            && hasRenderableEffects(displayID)
    }

    /// Whether a display's stack has any effectively-enabled effect that actually renders a
    /// pixel pass. System effects (transparency/layout/tint) drive controllers, not the GPU,
    /// so a stack made up only of them (the new Liquid Glass) skips capture and the overlay
    /// entirely — zero render cost, no frame-rate hit.
    private func hasRenderableEffects(_ displayID: CGDirectDisplayID) -> Bool {
        let chain = stack(for: displayID).chain()
        return chain.effects.contains {
            chain.isEffectivelyEnabled($0) && registry.descriptor($0.descriptorID)?.controllerKind == nil
        }
    }

    /// Whether a display's live stack is made up ENTIRELY of per-channel color
    /// effects, i.e. reproducible by a scanout transfer LUT. Read from the raw stack
    /// (descriptor ids), not the resolved chain, so colour-pass fusion — which would
    /// collapse the run into one synthetic descriptor — doesn't hide the membership.
    private func chainIsGlobalGrade(_ displayID: CGDirectDisplayID) -> Bool {
        let chain = stack(for: displayID).chain()
        // System effects carry no pixels; they never block a colour-only chain from the
        // scanout LUT, so exclude them from the membership test.
        let enabled = chain.effects.filter {
            chain.isEffectivelyEnabled($0) && registry.descriptor($0.descriptorID)?.controllerKind == nil
        }
        guard !enabled.isEmpty else { return false }
        return enabled.allSatisfy { Self.globalGradeEffectIDs.contains($0.descriptorID) }
    }

    /// Route per-channel color chains to the global scanout LUT and keep
    /// `gradeDisplays` in sync. Independent of capture permission — a pure colour
    /// grade needs no screen capture. Called at the top of `updatePipelines` and
    /// whenever a chain changes.
    private func reconcileGlobalGrade() {
        var next: Set<CGDirectDisplayID> = []
        for display in displays {
            let id = display.id
            guard isEnabled && chainIsGlobalGrade(id) else {
                displayGrade.clear(for: id)
                continue
            }
            let resolved = resolvedChains[id] ?? resolver.resolve(stack(for: id).chain())
            resolvedChains[id] = resolved
            if let lut = gradeExtractor.extract(
                chain: resolved, intensityScale: Self.intensityScale(forSetting: settings.intensity)) {
                displayGrade.setLUT(lut, for: id)
                next.insert(id)
            } else {
                displayGrade.clear(for: id)
            }
        }
        gradeDisplays = next
    }

    // MARK: - System effects

    /// Reconcile the system effects (window transparency/layout via yabai, the adaptive
    /// tint overlay) with the current chains. Gated on the master switch: when Spectra is
    /// off the desired state is `.inactive`, so window opacity, tiling, and the tint are
    /// all restored. Idempotent and cheap — safe to call on every chain edit and pipeline
    /// reconcile.
    private func reconcileSystemEffects() {
        systemEffects.apply(desiredSystemState(), displayIDs: orderedSystemDisplayIDs())
    }

    /// The menu-bar Glass toggle: window transparency + the adaptive tint, applied directly
    /// (no preset, and no need to Start the main effects pipeline).
    func setGlassEnabled(_ on: Bool) {
        settings.glassEnabled = on
        reconcileSystemEffects()
    }

    /// The desired aggregate system-effect state. Two sources, deduplicated (first wins):
    /// per-effect rows in a display's stack (only while the main pipeline is enabled), and
    /// the standalone menu-bar Glass toggle (transparency + tint, independent of the master
    /// switch). The selected display is considered first so its parameters win for the single
    /// global yabai configuration.
    private func desiredSystemState() -> SystemEffectsState {
        var state = SystemEffectsState()
        if isEnabled {
            for id in orderedSystemDisplayIDs() {
                let chain = stack(for: id).chain()
                for instance in chain.effects {
                    guard chain.isEffectivelyEnabled(instance),
                          let kind = registry.descriptor(instance.descriptorID)?.controllerKind else { continue }
                    switch kind {
                    case .windowTransparency:
                        if state.transparency == nil { state.transparency = TransparencySettings(instance) }
                    case .windowLayout:
                        if state.layout == nil { state.layout = LayoutSettings(instance) }
                    case .adaptiveTint:
                        if state.tint == nil { state.tint = TintSettings(instance) }
                    }
                }
            }
        }
        if settings.glassEnabled {
            if state.transparency == nil { state.transparency = .glass }
            if state.tint == nil { state.tint = .glass }
        }
        return state
    }

    /// Display ids with the selected display first, so its system-effect parameters take
    /// precedence for the single global yabai configuration and the tint window order.
    private func orderedSystemDisplayIDs() -> [CGDirectDisplayID] {
        var ids = displays.map(\.id)
        if let selected = selectedDisplayID, let index = ids.firstIndex(of: selected) {
            ids.remove(at: index)
            ids.insert(selected, at: 0)
        }
        return ids
    }

    private func wantsCapture(_ displayID: CGDirectDisplayID) -> Bool {
        // Capture only when the overlay is actually rendering. The Studio preview
        // runs on the wallpaper, so it never needs a live capture — this also means
        // no screen capture (and no recursion) while Spectra is off.
        guard permissionAuthorized else { return false }
        return wantsOverlay(displayID)
    }

    /// Reconcile capture sessions and overlay renderers with the desired state.
    private func updatePipelines() {
        // Global colour grading is reconciled first and independently: it needs no
        // capture permission, and it must update `gradeDisplays` before `wantsOverlay`
        // is consulted below so graded displays skip the overlay/capture path.
        reconcileGlobalGrade()
        // Reconcile system effects up front so the master switch (and display changes)
        // restore window opacity/tiling/tint even when the capture path is unavailable.
        reconcileSystemEffects()
        guard permissionAuthorized else {
            for (id, session) in sessions { Task { await session.stop() }; sessions[id] = nil }
            for id in renderEngine.activeDisplayIDs { renderEngine.deactivate(id) }
            // No overlay can be active here, so the effective custom-cursor state is
            // false — this restores the hardware cursor if it was hidden.
            updateCursorVisibility(effective: false)
            return
        }

        for display in displays {
            let id = display.id
            let capture = wantsCapture(id)
            let overlay = wantsOverlay(id)

            // Capture session lifecycle.
            if capture && sessions[id] == nil {
                startCapture(for: display)
            } else if !capture, let session = sessions[id] {
                sessions[id] = nil
                Task { await session.stop() }
            }

            // Overlay renderer lifecycle.
            if overlay {
                let renderer = renderEngine.activate(display)
                renderer.isActive = true
                // Per-renderer custom-cursor state is set authoritatively below by the
                // final applyCursorState() pass, once all chains have been rebuilt and
                // the effective (setting OR warp auto-engage) state is known.
                renderer.setPreferredFrameRate(overlayFPS(forDisplayRefresh: display.refreshRate))
                let perf = performance
                renderer.sampleHandler = { sample in perf.ingest(sample, displayID: id) }
                renderer.faultHandler = { [weak self] error in
                    Task { @MainActor in self?.handleGPUFault(displayID: id, error: error) }
                }
                rebuildResolvedChain(for: id)
                renderEngine.setOverlayVisible(true, displayID: id)
            } else if renderEngine.renderer(for: id) != nil {
                renderEngine.setOverlayVisible(false, displayID: id)
                renderEngine.renderer(for: id)?.isActive = false
            }

            // Route captured frames to the overlay renderer (if active). The
            // handler only stores the frame; the renderer's display link presents
            // it, so this never blocks the capture queue on a drawable.
            let renderer = overlay ? renderEngine.renderer(for: id) : nil
            sessions[id]?.frameHandler = { [weak renderer] frame in
                renderer?.submit(frame)
            }
        }

        // Tear down renderers for displays no longer present.
        for id in renderEngine.activeDisplayIDs where !displays.contains(where: { $0.id == id }) {
            renderEngine.deactivate(id)
            resolvedChains[id] = nil
        }

        renderEngine.setCoversMenuBarAndDock(settings.coverMenuBarAndDock)
        renderEngine.setOverlaysVisibleToScreenshots(settings.showInScreenshots)
        renderEngine.setIntensityScale(Self.intensityScale(forSetting: settings.intensity))
        // Authoritative cursor pass: now that every renderer is (de)activated and every
        // chain rebuilt, push the effective custom-cursor state (setting OR warp
        // auto-engage) to all renderers, sessions, and the hardware cursor at once.
        applyCursorState()
        refreshCaptureExceptions()
    }

    private func startCapture(for display: DisplayInfo) {
        guard let scDisplay = displayManager.scDisplay(for: display.id) else { return }
        let fps = overlayFPS(forDisplayRefresh: display.refreshRate)
        // Render at the chosen quality scale; the chain runs at this resolution and
        // the present pass upscales to the native drawable.
        let scale = captureScale(for: display)
        let width = max(2, Int(Double(display.pixelWidth) * scale))
        let height = max(2, Int(Double(display.pixelHeight) * scale))

        let session = CaptureSession(
            displayID: display.id, pixelWidth: width, pixelHeight: height, fps: fps,
            showsCursor: settings.showCursorInCapture, context: context)
        session.stopHandler = { [weak self] error in self?.handleSessionStopped(display.id, error) }
        sessions[display.id] = session
        appliedScale[display.id] = scale

        Task {
            // Exclude the whole app at capture time so the opaque overlay never captures
            // itself and feeds back — then except the control windows so the Studio and
            // Settings render through the chain like any other window.
            let apps = await displayManager.captureExclusions()
            guard !apps.isEmpty else {
                // No self-exclusion resolved: starting would capture the overlay and feed
                // back. Drop the session so a later reconcile retries once self resolves.
                Log.capture.error("No self-exclusion for \(display.id); skipping capture to avoid feedback")
                sessions[display.id] = nil
                return
            }
            let exceptions = await controlWindowSCWindows()
            do {
                try await session.start(scDisplay: scDisplay, excluding: apps, excepting: exceptions)
                startupError = nil   // a display started cleanly; clear any prior failure banner
            } catch {
                Log.capture.error("Failed to start capture for \(display.id): \(error.localizedDescription)")
                startupError = "Couldn't start screen capture. \(error.localizedDescription)"
            }
        }
    }

    /// The `SCWindow`s for Spectra's control windows (Studio/Settings) so the capture
    /// filter can include them. The overlay window numbers are subtracted as a
    /// belt-and-suspenders guard: the overlay must never be captured, or it feeds back.
    private func controlWindowSCWindows() async -> [SCWindow] {
        let overlayNumbers = renderEngine.overlayWindowNumbers
        var numbers = Set<Int>()
        // The Studio/Settings windows are deliberately NOT excepted: they render crisp directly
        // above the overlay, so the capture stays on the cheaper path and the controls aren't a
        // capture round-trip behind.
        // The menu-bar popover, while open, is always excepted so it renders through the chain
        // rather than being hidden behind the overlay (its window number changes per open, so it
        // is tracked live by `MenuPanelCaptureBridge`, not registered like a control window).
        if let menuPanelWindow { numbers.insert(menuPanelWindow.windowNumber) }
        // Except the adaptive-tint windows so they're captured below the real windows and
        // graded with the scene. They are desktop-level and contain no captured content,
        // so excepting them can't feed back the way the overlay would.
        for number in systemEffects.tintWindowNumbers { numbers.insert(number) }
        numbers.subtract(overlayNumbers)
        return await displayManager.shareableWindows(matching: numbers)
    }

    /// Re-resolve the control-window exceptions and push them to every running capture
    /// session, so a Studio/Settings window opened (or re-fronted) after capture began
    /// starts rendering through the chain. The overlay stays excluded throughout.
    private func refreshCaptureExceptions() {
        guard !sessions.isEmpty else { return }
        Task {
            let apps = await displayManager.captureExclusions()
            let exceptions = await controlWindowSCWindows()
            for (id, session) in sessions {
                guard let scDisplay = displayManager.scDisplay(for: id) else { continue }
                await session.updateFilter(scDisplay: scDisplay, excluding: apps, excepting: exceptions)
            }
        }
    }

    private func handleSessionStopped(_ displayID: CGDirectDisplayID, _ error: Error?) {
        sessions[displayID] = nil
        // A stop *with an error* can mean Screen Recording was revoked mid-session.
        // Re-check the grant before blindly restarting: if it's gone, reflect it (the
        // permission banner reappears) and tear the pipeline down so the overlay can't
        // freeze on its last frame while the OS keeps refusing a fresh stream.
        guard error != nil else { updatePipelines(); return }
        Task {
            await displayManager.refresh()
            permissionAuthorized = displayManager.permissionAuthorized
            displays = displayManager.displays
            if !permissionAuthorized {
                startupError = "Screen Recording access was turned off. Re-enable it in System Settings to keep rendering effects."
            }
            updatePipelines()
        }
    }

    /// Snapshot each capturing display's frame count and arm the post-Space-switch stall check
    /// (see `captureStallBaseline`). Called once a Space transition has settled, right after the
    /// capture filter is re-issued (which itself nudges a healthy stream to emit a fresh frame).
    private func armCaptureStallWatchdog() {
        guard !sessions.isEmpty else { return }
        captureStallBaseline.removeAll(keepingCapacity: true)
        for id in sessions.keys {
            captureStallBaseline[id] = renderEngine.renderer(for: id)?.capturedFrameCount ?? 0
        }
        captureStallDeadline = CACurrentMediaTime() + Self.captureStallGracePeriod
        Log.capture.debug("Armed capture-stall watchdog for \(self.captureStallBaseline.count, privacy: .public) display(s)")
    }

    /// Engine-tick check armed by `armCaptureStallWatchdog`: once the grace period has elapsed,
    /// restart any display whose capture delivered no new frame since the Space switch — its
    /// SCStream stalled silently (no `didStopWithError`, so the normal restart never fired).
    /// Mirrors `handleSessionStopped`'s recovery — drop the dead session, then `updatePipelines`
    /// starts a fresh one and re-wires frame delivery — which the overlay's still-live renderer
    /// immediately resumes painting from. One-shot per arm.
    private func detectStalledCapture() {
        guard captureStallDeadline > 0, CACurrentMediaTime() > captureStallDeadline else { return }
        let baselines = captureStallBaseline
        captureStallDeadline = 0
        captureStallBaseline.removeAll(keepingCapacity: true)
        var stalled = false
        for (id, baseline) in baselines {
            guard let session = sessions[id], wantsCapture(id) else { continue }
            let current = renderEngine.renderer(for: id)?.capturedFrameCount ?? baseline
            guard current == baseline else { continue }   // a fresh frame arrived → stream healthy
            Log.capture.error("Capture stalled after Space switch on display \(id, privacy: .public); restarting stream")
            sessions[id] = nil
            Task { await session.stop() }
            stalled = true
        }
        if stalled { updatePipelines() }   // re-create the dead session(s) and re-wire frame delivery
    }

    /// Hard-freeze failsafe (see the state declarations above). Per visible display, compare this
    /// tick's capture and present counters with last tick's: if capture is still advancing but
    /// nothing was presented for `hardFreezeSeconds`, the render clock has died and the overlay is
    /// frozen on a stale frame — recover it. A static desktop (no capture frames) never trips this
    /// because capture isn't advancing either.
    private func detectAndRecoverHardFreeze() {
        let now = CACurrentMediaTime()
        for id in renderEngine.activeDisplayIDs {
            guard wantsOverlay(id), let renderer = renderEngine.renderer(for: id), renderer.isActive else {
                presentStuckSince[id] = nil
                lastCaptureCount[id] = nil
                lastPresentCount[id] = nil
                continue
            }
            let snap = renderer.renderHealthSnapshot()
            let prevFrames = lastCaptureCount[id]
            let prevPres = lastPresentCount[id]
            lastCaptureCount[id] = snap.frames
            lastPresentCount[id] = snap.presents
            guard let prevFrames, let prevPres else { continue }   // need a baseline tick first
            if snap.frames > prevFrames && snap.presents == prevPres {
                let since = presentStuckSince[id] ?? now
                presentStuckSince[id] = since
                if now - since >= Self.hardFreezeSeconds {
                    presentStuckSince[id] = nil
                    recoverFrozenOverlay(id, now: now)
                }
            } else {
                presentStuckSince[id] = nil
            }
        }
    }

    /// Recreate a frozen display's overlay (the toggle-the-effect recovery the owner relies on),
    /// or disable the overlay if freezes keep recurring so it can't trap the screen behind a
    /// recreate loop.
    private func recoverFrozenOverlay(_ id: CGDirectDisplayID, now: CFTimeInterval) {
        var recent = (freezeRecoveries[id] ?? []).filter { now - $0 < 30 }
        recent.append(now)
        freezeRecoveries[id] = recent
        lastCaptureCount[id] = nil   // recreated overlay re-measures from a clean baseline
        lastPresentCount[id] = nil
        if recent.count > 3 {
            Log.render.error("Overlay on display \(id, privacy: .public) froze repeatedly; disabling so it can't trap the screen.")
            lastRecoveryMessage = "Effects turned off automatically after the overlay kept freezing. Re-enable when ready."
            disable()
            return
        }
        Log.render.error("Hard render freeze on display \(id, privacy: .public); recreating overlay (auto-recover).")
        renderEngine.deactivate(id)
        updatePipelines()   // recreates the overlay + renderer + display link and re-wires capture
    }

    /// Recover from a GPU fault. Built-in shaders are validated and compiled at
    /// launch, so a repeated fault almost always comes from an imported/authored
    /// custom effect. After a few consecutive faults on a display, disable that
    /// display's custom effects and re-resolve so the pipeline recovers instead of
    /// faulting every frame.
    private func handleGPUFault(displayID: CGDirectDisplayID, error: Error?) {
        let count = (gpuFaultCounts[displayID] ?? 0) + 1
        gpuFaultCounts[displayID] = count
        guard count >= 3 else { return }
        gpuFaultCounts[displayID] = 0

        let stack = self.stack(for: displayID)
        let customInstances = stack.effects.filter {
            registry.descriptor($0.descriptorID)?.isCustom ?? false
        }
        guard !customInstances.isEmpty else { return }
        for instance in customInstances where instance.isEnabled {
            stack.setEnabled(false, on: instance.id)
        }
        lastRecoveryMessage = "Disabled \(customInstances.count) custom effect(s) on a display after repeated GPU errors."
        Log.render.error("Auto-recovered display \(displayID): disabled faulting custom effects.")
    }

    private func handleDisplaysChanged() {
        displays = displayManager.displays
        wallpaper.refresh()
        if displays.first(where: { $0.id == selectedDisplayID }) == nil {
            selectedDisplayID = displayManager.mainDisplay?.id
        }
        for display in displays { renderEngine.updateGeometry(display) }
        systemEffects.refreshDisplays(orderedSystemDisplayIDs())
        updatePipelines()
    }

    // MARK: - Periodic refresh

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func tick() {
        performance.refresh()
        renderEngine.restartStalledDisplayLinks()     // rebuild any clock that died on a carry (fixes the freeze)
        renderEngine.ensureOverlaysOnActiveSpace()   // follow the user across Spaces (focused-display, occlusion-gated)
        detectStalledCapture()                       // restart a capture stream that silently stalled on a Space switch
        detectAndRecoverHardFreeze()                 // failsafe: auto-recover a frozen overlay so it can't trap the screen
        governAutoQuality()                          // adaptive quality (the "Auto" toggle), no-op unless enabled
        // Render scale is applied on every path that changes it (setRenderScale) or
        // creates a session (startCapture), so no per-tick reconcile is needed.
    }

    /// Reconfigure one display's capture session to `scale` (a fraction of native)
    /// if it isn't already there, and reset its stats so timing re-measures clean.
    private func applyScale(_ scale: Double, to display: DisplayInfo) {
        guard sessions[display.id] != nil,
              abs((appliedScale[display.id] ?? 1.0) - scale) > 0.001 else { return }
        appliedScale[display.id] = scale
        let width = max(2, Int(Double(display.pixelWidth) * scale))
        let height = max(2, Int(Double(display.pixelHeight) * scale))
        let fps = overlayFPS(forDisplayRefresh: display.refreshRate)
        renderEngine.renderer(for: display.id)?.purge()   // free stale-resolution pool textures
        performance.resetStats(for: display.id)
        Task { await sessions[display.id]?.reconfigure(pixelWidth: width, pixelHeight: height, fps: fps) }
    }

    /// Set the render scale live (the Quality slider). Applied to every session at
    /// exactly this fixed fraction of native.
    func setRenderScale(_ scale: Double) {
        let clamped = min(RenderScale.max, max(RenderScale.min, scale))
        settings.renderScale = clamped
        // A manual quality change hands control back from the governor: adjusting the
        // slider turns Auto off and pins the chosen scale. (setAutoQuality(false) applies
        // settings.renderScale — now `clamped` — to every display, so don't apply twice.)
        if settings.autoQuality {
            setAutoQuality(false)
        } else {
            for display in displays { applyScale(clamped, to: display) }
        }
    }

    /// Toggle the adaptive quality governor (the menu-bar "Auto" switch). Turning it on
    /// hands render-scale control to `governAutoQuality`, starting from the current
    /// quality; turning it off restores the fixed Quality slider value.
    func setAutoQuality(_ on: Bool) {
        guard settings.autoQuality != on else { return }
        settings.autoQuality = on
        autoUnderSince = 0
        autoAboveSince = 0
        smoothedGPUMilliseconds = 0
        lastAutoAdjust = CACurrentMediaTime()
        if on {
            autoScale = settings.renderScale   // start where the slider left off; adjust from here
        } else {
            for display in displays { applyScale(settings.renderScale, to: display) }
        }
    }

    /// Adaptive quality control loop, run on the engine tick. Tracks a smoothed GPU
    /// time and: lowers the render scale (in proportional steps) once GPU time sustains
    /// over `autoGPULowerMs` for `autoUnderGrace`; raises it one small step at a time
    /// once GPU time sits under `autoGPURaiseMs` for `autoRaiseHold`; holds in the dead
    /// band between. Targeting GPU time (not fps) means a low-fps spell that render scale
    /// can't fix — an erratic display-link rate, the OS throttling the overlay on battery —
    /// no longer drags quality down, because GPU time stays low through it. Each change
    /// resets the per-display stats, so a cooldown lets the new resolution re-measure.
    private func governAutoQuality() {
        guard settings.autoQuality, isEnabled, !displays.isEmpty else { return }
        let now = CACurrentMediaTime()
        let gpu = performance.combined.gpuMilliseconds
        guard gpu > 0 else { return }   // stats just reset; wait for fresh samples
        smoothedGPUMilliseconds = smoothedGPUMilliseconds == 0
            ? gpu
            : smoothedGPUMilliseconds + Self.autoGPUSmoothing * (gpu - smoothedGPUMilliseconds)

        guard now - lastAutoAdjust >= Self.autoAdjustCooldown else { return }
        let g = smoothedGPUMilliseconds

        if g > Self.autoGPULowerMs {
            autoAboveSince = 0
            if autoUnderSince == 0 { autoUnderSince = now }
            guard now - autoUnderSince >= Self.autoUnderGrace, autoScale > RenderScale.min else { return }
            // Proportional cut: bigger the further over budget, so a hard overload
            // recovers in a few steps while a slight overrun only nudges.
            let over = (g - Self.autoGPULowerMs) / Self.autoGPULowerMs
            let step = min(0.10, max(0.03, over * 0.4))
            autoScale = max(RenderScale.min, autoScale - step)
            for display in displays { applyScale(autoScale, to: display) }
            lastAutoAdjust = now
        } else if g < Self.autoGPURaiseMs {
            autoUnderSince = 0
            guard autoScale < RenderScale.max else { return }
            if autoAboveSince == 0 { autoAboveSince = now }
            guard now - autoAboveSince >= Self.autoRaiseHold else { return }
            autoScale = min(RenderScale.max, autoScale + Self.autoRaiseStep)
            for display in displays { applyScale(autoScale, to: display) }
            lastAutoAdjust = now
            autoAboveSince = now              // require another full hold before raising again
        } else {
            autoUnderSince = 0               // in the dead band: stable, reset both timers
            autoAboveSince = 0
        }
    }

    /// Set the global intensity live (the Intensity slider). Pushed to every renderer
    /// as a per-effect strength multiplier — it never edits the stack, so it doesn't
    /// disturb the active-preset match or trigger a chain re-resolve.
    func setIntensity(_ value: Double) {
        let clamped = min(1.0, max(0.0, value))
        settings.intensity = clamped
        renderEngine.setIntensityScale(Self.intensityScale(forSetting: clamped))
        // Globally-graded displays bake intensity into their LUT, so refresh it too.
        if !gradeDisplays.isEmpty { reconcileGlobalGrade() }
    }

    /// Map the 0…1 Intensity setting to a per-effect strength multiplier. 100% renders
    /// every effect at its authored strength (the look the presets ship at); the slider
    /// only fades effects down toward off, reaching 0× at 0%. The mapping is linear, so
    /// there's no breakpoint or overdrive — 100% is the ceiling, not a midpoint.
    static func intensityScale(forSetting value: Double) -> Float {
        Float(min(1.0, max(0.0, value)))
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var masterEnabled: Bool
        var selectedDisplayID: UInt32?
        var chains: [String: EffectChain]
        var activePresets: [String: String]?
    }

    private func saveState() {
        var chains: [String: EffectChain] = [:]
        for (id, stack) in stacks { chains[String(id)] = stack.chain() }
        var presetMap: [String: String] = [:]
        for (id, name) in activePresetByDisplay { presetMap[String(id)] = name }
        let state = PersistedState(
            masterEnabled: isEnabled,
            selectedDisplayID: selectedDisplayID,
            chains: chains,
            activePresets: presetMap)
        try? JSONStore.save(state, to: AppPaths.stateFile)
    }

    /// Returns the persisted master on/off state so the caller can restore it on launch
    /// (false when there is no saved state yet).
    @discardableResult
    private func loadState() -> Bool {
        guard let state = JSONStore.load(PersistedState.self, from: AppPaths.stateFile) else { return false }
        if let raw = state.selectedDisplayID { selectedDisplayID = raw }
        for (key, chain) in state.chains {
            guard let id = UInt32(key) else { continue }
            let stack = self.stack(for: id)
            stack.load(chain)
        }
        for (key, name) in state.activePresets ?? [:] {
            if let id = UInt32(key) { activePresetByDisplay[id] = name }
        }
        return state.masterEnabled
    }
}
