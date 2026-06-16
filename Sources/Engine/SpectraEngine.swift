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
    @ObservationIgnored private let startHostTime = CACurrentMediaTime()
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var gpuFaultCounts: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored private var folderWatcher: FolderWatcher?
    @ObservationIgnored private var importedFileDates: [URL: Date] = [:]
    /// Process-wide panic switch. When the overlay covers the menu bar/Dock the
    /// status item is hidden, so this is the guaranteed way to turn it off.
    @ObservationIgnored private var globalPanicHotKey: GlobalHotKey?

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

    /// The capture/render scale for a display: the user's fixed Quality slider value.
    private func captureScale(for display: DisplayInfo) -> Double {
        settings.renderScale
    }

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
        // Let the render engine neutralize the control windows' Space-migrate flag during
        // a Space swipe (they'd otherwise snap the gesture back) and wake capture once it
        // settles.
        renderEngine.controlWindowsProvider = { [weak self] in
            self?.controlWindows.allObjects ?? []
        }
        renderEngine.onActiveSpaceSettled = { [weak self] in
            self?.refreshCaptureExceptions()
        }
        AppPaths.ensureDirectories()
        permissionAuthorized = ScreenRecordingPermission.isAuthorized
        await displayManager.refresh()
        permissionAuthorized = displayManager.permissionAuthorized
        displays = displayManager.displays

        loadState()
        if selectedDisplayID == nil || displays.first(where: { $0.id == selectedDisplayID }) == nil {
            selectedDisplayID = displayManager.mainDisplay?.id
        }
        displayManager.onChange = { [weak self] in self?.handleDisplaysChanged() }

        if settings.startEnabledOnLaunch && permissionAuthorized {
            isEnabled = true
        }
        updatePipelines()
        startRefreshTimer()
        startFolderWatch()
        registerGlobalPanicHotKey()
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

    func shutdown() {
        refreshTimer?.invalidate()
        folderWatcher?.stop()
        globalPanicHotKey = nil   // unregisters the Carbon hotkey
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

    /// Push the effective custom-cursor state to every renderer, session, and the
    /// hardware cursor in one place. The effective state folds in the setting *and*
    /// auto-engagement for warp chains, so adding/removing a CRT/distortion effect
    /// (or toggling the setting) routes through here and stays consistent.
    private func applyCursorState() {
        let effective = effectiveCustomCursorActive()
        for id in renderEngine.activeDisplayIDs {
            renderEngine.renderer(for: id)?.setCustomCursorEnabled(effective)
        }
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
        // Keep control windows on the user's current Space (and able to float over a
        // full-screen Space the overlay covers) so they sit on the Space the overlay is
        // capturing. They are ordinary windows now — left at their normal level, *below*
        // the overlay, so they're captured and rendered through the effect chain like
        // anything else rather than raised above it.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        if window.identifier?.rawValue.contains("studio") ?? false { studioWindow = window }
        refreshCaptureExceptions()   // start rendering this window through the chain
        guard displays.contains(where: { wantsOverlay($0.id) }) else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }   // don't resurrect a closing window
            window.makeKeyAndOrderFront(nil)
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
            self.refreshCaptureExceptions()
        }
    }

    /// Toggle whether effects cover the menu bar and Dock. Applies the new overlay
    /// level live; control windows sit below the overlay and need no re-pegging.
    func setCoverMenuBarAndDock(_ on: Bool) {
        settings.coverMenuBarAndDock = on
        renderEngine.setCoversMenuBarAndDock(on)
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

    func latestTexture(for displayID: CGDirectDisplayID) -> MTLTexture? {
        sessions[displayID]?.latestTexture()
    }

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
        isEnabled && permissionAuthorized
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
            } catch {
                Log.capture.error("Failed to start capture for \(display.id): \(error.localizedDescription)")
            }
        }
    }

    /// The `SCWindow`s for Spectra's control windows (Studio/Settings) so the capture
    /// filter can include them. The overlay window numbers are subtracted as a
    /// belt-and-suspenders guard: the overlay must never be captured, or it feeds back.
    private func controlWindowSCWindows() async -> [SCWindow] {
        let overlayNumbers = renderEngine.overlayWindowNumbers
        let numbers = Set(controlWindows.allObjects.map { $0.windowNumber })
            .subtracting(overlayNumbers)
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
        updatePipelines()
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
        renderEngine.ensureOverlaysOnActiveSpace()   // follow the user across Spaces (focused-display, occlusion-gated)
        // Every session sits at exactly the slider value (a no-op when already there).
        for display in displays { applyScale(settings.renderScale, to: display) }
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
        for display in displays { applyScale(clamped, to: display) }
    }

    /// Set the global intensity live (the Intensity slider). Pushed to every renderer
    /// as a per-effect strength multiplier — it never edits the stack, so it doesn't
    /// disturb the active-preset match or trigger a chain re-resolve.
    func setIntensity(_ value: Double) {
        let clamped = min(1.0, max(0.0, value))
        settings.intensity = clamped
        renderEngine.setIntensityScale(Self.intensityScale(forSetting: clamped))
    }

    /// Map the 0…1 Intensity setting to a per-effect strength multiplier. The shipped
    /// presets are tuned to read as "current" at the 0.7 default, so 0.7 maps to 1.0×
    /// (identity); 1.0 maps to 1.3× (+30%, as specified); and the bottom of the range
    /// fades proportionally to 0× so the slider also dials effects down toward off.
    static func intensityScale(forSetting value: Double) -> Float {
        let c = min(1.0, max(0.0, value))
        let scale = c <= 0.7 ? c / 0.7 : 1.0 + (c - 0.7)
        return Float(scale)
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

    private func loadState() {
        guard let state = JSONStore.load(PersistedState.self, from: AppPaths.stateFile) else { return }
        if let raw = state.selectedDisplayID { selectedDisplayID = raw }
        for (key, chain) in state.chains {
            guard let id = UInt32(key) else { continue }
            let stack = self.stack(for: id)
            stack.load(chain)
        }
        for (key, name) in state.activePresets ?? [:] {
            if let id = UInt32(key) { activePresetByDisplay[id] = name }
        }
    }
}
