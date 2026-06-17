import Foundation
import AppKit
import Metal

/// Owns the per-display overlay windows and their renderers, and the shared
/// shader library. Lifecycle (window creation/teardown, geometry) runs on the
/// main actor; the returned `DisplayRenderer` instances are thread-safe and are
/// driven directly from the capture queue for minimal latency.
@MainActor
final class RenderEngine {
    let context: MetalContext
    let shaders: ShaderLibrary

    private var renderers: [CGDirectDisplayID: DisplayRenderer] = [:]
    private var overlays: [CGDirectDisplayID: OverlayWindow] = [:]
    /// Displays whose overlay is currently meant to be visible. The overlay is
    /// re-ordered onto the active Space when the user switches Spaces, so the shader
    /// follows them across desktops and onto full-screen apps.
    private var visibleDisplayIDs: Set<CGDirectDisplayID> = []
    /// Whether overlays should sit above the menu bar/Dock (covering them). Applied
    /// to every overlay, and to overlays created later via `activate`.
    private var coversMenuBarAndDock = false
    private var spaceObserver: NSObjectProtocol?
    /// While a Space transition (Mission Control swipe) is still settling we must NOT
    /// carry the overlay: `carryToActiveSpace` toggles `.canJoinAllSpaces` and force-
    /// fronts the opaque overlay, and doing that mid-swipe makes WindowServer resolve
    /// the in-flight swipe back onto the overlay's Space — the "snaps me back" bug.
    /// Set on every Space change; both carry paths wait until it passes.
    private var spaceSettleDeadline: CFTimeInterval = 0
    /// Bumped on every Space change so a carry scheduled for an earlier change is
    /// superseded — only the last change in a rapid multi-Space swipe actually carries.
    private var spaceCarryGeneration = 0

    /// Spectra's tracked control windows (Studio/Settings), supplied by the engine.
    /// They carry `.moveToActiveSpace` and are key/main-capable, so — unlike the overlay
    /// (which forces `canBecomeKey/Main = false`) — leaving that flag set during a Space
    /// swipe makes WindowServer force-migrate them mid-gesture and snap the swipe back to
    /// their Space. So the flag is stripped while a transition is in flight and restored
    /// once it settles (`activeSpaceDidChange` / `followActiveSpace`).
    var controlWindowsProvider: () -> [NSWindow] = { [] }
    /// Called once a Space transition has settled, so the engine can re-issue the capture
    /// filter and wake ScreenCaptureKit (a hidden overlay can't self-dirty the new Space).
    var onActiveSpaceSettled: () -> Void = {}

    init(context: MetalContext) {
        self.context = context
        self.shaders = ShaderLibrary(context: context)
        // Follow the user across Spaces. When the active Space changes, pull the
        // visible overlays onto it (each is a single-Space window, so ordering it
        // front moves it to the now-active Space) — this gives "shader on every
        // Space / full-screen app" without the desktop-merging that
        // `.canJoinAllSpaces` causes. The carry is debounced until the swipe settles
        // (see `activeSpaceDidChange`) so it never fronts the overlay mid-transition.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceDidChange() }
        }
    }

    deinit {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    /// A Space change fired. The notification can arrive while the swipe animation is
    /// still in flight; carrying the overlay then snaps the user back (see
    /// `spaceSettleDeadline`). So we hold the timer safety-net off for a beat and defer
    /// the carry itself, superseding it if another change arrives first (debounce). The
    /// overlay still follows the user — just once they've actually landed on a Space.
    private func activeSpaceDidChange() {
        spaceSettleDeadline = CACurrentMediaTime() + 0.7
        spaceCarryGeneration += 1
        let generation = spaceCarryGeneration
        // Make the overlay TRANSPARENT (not hidden) for the duration of the swipe, and
        // reveal it again once the swipe settles (`ensureOverlaysOnActiveSpace`). During a
        // swipe the opaque overlay slides out with the outgoing Space while it keeps
        // rendering the live capture — which IS the swipe animation — so its content slides
        // too, doubling the motion ("a duplicate next Space moving twice as fast"). The
        // post-settle `followActiveSpace` carry also momentarily joins all Spaces, which
        // mid-swipe literally shows the overlay on every Space at once. Both vanish if the
        // overlay is invisible until the swipe is done.
        //
        // We use alpha, NOT orderOut: the render clock is screen-tied (`NSScreen.displayLink`)
        // so alpha leaves it ticking, whereas orderOut detaches the layer (the old freeze).
        // Alpha also can't strand the window the way a missed re-show (orderFront) could.
        for id in visibleDisplayIDs { overlays[id]?.alphaValue = 0 }
        // Strip the migrate flag from the control windows for the duration of the swipe,
        // so WindowServer can't pull a key-capable .normal window onto the in-flight Space
        // and reverse the gesture (the snap-back). Restored once settled, below.
        for window in controlWindowsProvider() {
            window.collectionBehavior.remove(.moveToActiveSpace)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.spaceCarryGeneration else { return }
                self.followActiveSpace()
            }
        }
    }

    /// Carry every visible overlay onto the now-active Space. `orderFront` alone on
    /// a `.transient` window can land it on the *outgoing* Space ("shader only works
    /// on one Space"); `carryToActiveSpace` momentarily joins all Spaces to land it
    /// reliably, then reverts. Cheap and idempotent when already on the active Space.
    /// Only called once a Space transition has settled (see `activeSpaceDidChange`).
    private func followActiveSpace() {
        for id in visibleDisplayIDs { carryAndRebuild(id) }
        // The swipe has settled: let the control windows follow to the now-active Space
        // again (migrating now can't reverse a completed gesture), and wake capture so a
        // fresh frame lands on the new Space — re-showing the overlay re-dirties it, but
        // re-issuing the content filter guarantees ScreenCaptureKit emits one.
        for window in controlWindowsProvider() {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        onActiveSpaceSettled()
    }

    /// Consecutive ticks each overlay has been occluded, so the safety-net carry fires only
    /// after SUSTAINED occlusion, not on a transient `occlusionState` flap (see
    /// `ensureOverlaysOnActiveSpace`).
    private var overlayOccludedTicks: [CGDirectDisplayID: Int] = [:]

    /// Notification-independent safety net (the engine tick), run once a Space swipe has
    /// settled (`now > spaceSettleDeadline`, so never mid-swipe). It does two things:
    ///
    /// 1. Reveal — restore `alphaValue` to 1 after `activeSpaceDidChange` made the overlay
    ///    transparent for the swipe. Time-based, so a transparent overlay is never stranded.
    /// 2. Follow — carry the FOCUSED display's overlay onto the active Space, but ONLY after
    ///    it has been occluded for several consecutive ticks (~1.5s of SUSTAINED occlusion),
    ///    and exactly once. This is essential: the overlay's `occlusionState` FLAPS
    ///    (spurious visible→occluded→visible even on a static single display), and any carry
    ///    triggered by a flap re-runs `carryToActiveSpace` + the `CAMetalDisplayLink` rebuild,
    ///    each of which forces a window-server recomposite that spikes GPU time/latency to
    ///    ~80ms (and flashes the overlay across Spaces — the "two Spaces" doubling). A real
    ///    Space change stays occluded until carried, so it clears the debounce; a flap
    ///    recovers within a tick and never does. (Gesture Space changes are already carried
    ///    immediately by the `activeSpaceDidChange` notification → `followActiveSpace`; this
    ///    debounced path is only the backup for transitions the notification misses, e.g.
    ///    yabai.) Only the focused display can have switched Space; others must not be carried.
    func ensureOverlaysOnActiveSpace() {
        guard CACurrentMediaTime() > spaceSettleDeadline else { return }
        let mainID = NSScreen.main.flatMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        for id in visibleDisplayIDs {
            guard let overlay = overlays[id] else { continue }
            if overlay.occlusionState.contains(.visible) {
                if overlay.alphaValue != 1 { overlay.alphaValue = 1 }   // reveal after the swipe
                overlayOccludedTicks[id] = 0
            } else {
                let ticks = (overlayOccludedTicks[id] ?? 0) + 1
                overlayOccludedTicks[id] = ticks
                if id == mainID, ticks == 3 {   // fire exactly once, after ~1.5s sustained
                    carryAndRebuild(id)
                }
            }
        }
    }

    /// Carry an overlay onto the active Space and rebuild its render clock. The carry
    /// re-orders the window, which permanently stops the window-tied `CAMetalDisplayLink`;
    /// the rebuild is queued AFTER `carryToActiveSpace`'s deferred revert (main-queue FIFO),
    /// so the revert's own `orderFront` can't re-kill the fresh link, and the overlay
    /// resumes painting on the new Space instead of freezing.
    private func carryAndRebuild(_ id: CGDirectDisplayID) {
        overlays[id]?.carryToActiveSpace()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.renderers[id]?.rebuildDisplayLink() }
        }
    }

    func renderer(for displayID: CGDirectDisplayID) -> DisplayRenderer? {
        renderers[displayID]
    }

    var activeDisplayIDs: [CGDirectDisplayID] { Array(renderers.keys) }

    /// Window numbers of the live overlay windows. Two uses: the cursor enforcer
    /// hit-tests against them (rendered cursor over the overlay vs. hardware cursor over
    /// the menu bar/dropdowns above it), and they guard capture-filter exceptions — an
    /// overlay must never be excepted into the capture or it would film its own output.
    var overlayWindowNumbers: Set<Int> { Set(overlays.values.map { $0.windowNumber }) }

    /// Create (or return the existing) renderer + overlay for a display.
    @discardableResult
    func activate(_ display: DisplayInfo) -> DisplayRenderer {
        if let existing = renderers[display.id] {
            updateGeometry(display)
            return existing
        }
        let overlay = OverlayWindow(
            displayID: display.id, frame: display.frame, scale: display.scale, device: context.device)
        overlay.setEDR(enabled: display.supportsEDR)
        overlay.setCoversMenuBarAndDock(coversMenuBarAndDock)
        let renderer = DisplayRenderer(
            displayID: display.id, overlay: overlay, context: context, shaders: shaders)
        overlays[display.id] = overlay
        renderers[display.id] = renderer
        // First time a display goes live: warm the pipelines every overlay uses
        // regardless of chain, so the first frame doesn't compile them on the render
        // queue. The chain's effect pipelines are warmed separately in `updateChain`,
        // which `updatePipelines` calls right after this via `rebuildResolvedChain`.
        prewarmFixedPipelines()
        return renderer
    }

    func deactivate(_ displayID: CGDirectDisplayID) {
        renderers[displayID]?.teardown()   // stop the display link, then free pooled textures
        renderers[displayID] = nil
        overlays[displayID]?.hide()
        overlays[displayID] = nil
        visibleDisplayIDs.remove(displayID)
    }

    /// Raise/lower every overlay relative to the menu bar and Dock. Stored so a
    /// display activated later picks up the same choice.
    func setCoversMenuBarAndDock(_ covers: Bool) {
        coversMenuBarAndDock = covers
        for overlay in overlays.values { overlay.setCoversMenuBarAndDock(covers) }
    }

    /// Push the global intensity multiplier to every active renderer. Stored so a
    /// display activated later (via `activate`) can be brought up to the same value
    /// by the engine's reconcile.
    func setIntensityScale(_ scale: Float) {
        for renderer in renderers.values { renderer.setIntensityScale(scale) }
    }

    func setOverlayVisible(_ visible: Bool, displayID: CGDirectDisplayID) {
        guard let overlay = overlays[displayID] else { return }
        if visible {
            visibleDisplayIDs.insert(displayID)
            overlay.show()
        } else {
            visibleDisplayIDs.remove(displayID)
            overlay.hide()
        }
    }

    func updateGeometry(_ display: DisplayInfo) {
        overlays[display.id]?.update(frame: display.frame, scale: display.scale)
        overlays[display.id]?.setEDR(enabled: display.supportsEDR)
    }

    func updateChain(_ resolved: [ResolvedEffect], displayID: CGDirectDisplayID) {
        prewarmChain(resolved)
        renderers[displayID]?.updateChain(resolved)
    }

    /// Warm exactly the effect pipelines a resolved chain will render: each built-in
    /// pass's fragment function. The fused colour pass (`fx_color_fused`) is included
    /// automatically, since fusion replaces a run with `ColorFusion.descriptor`, whose
    /// pass appears here like any other. Called on every chain push, so a newly-added
    /// effect compiles here instead of hitching on its first render. Custom-library
    /// effects are skipped (keyed by library, compiled at import); the shader cache
    /// makes repeat calls free, and only the chain's handful of effects are touched —
    /// never the ~150 built-in pipelines.
    private func prewarmChain(_ resolved: [ResolvedEffect]) {
        var functions: [String] = []
        for effect in resolved where effect.customLibrary == nil {
            functions.append(contentsOf: effect.descriptor.passes.map(\.fragmentFunction))
        }
        guard !functions.isEmpty else { return }
        shaders.prewarm(functions: functions, pixelFormat: MetalContext.workingPixelFormat)
    }

    /// Warm the pipelines every overlay uses no matter which effects are in the chain:
    /// the cursor compositor, and the predither/present output. Called once when a
    /// display's renderer is created. A handful of pipelines — nowhere near the full
    /// built-in set — so launch stays fast.
    private func prewarmFixedPipelines() {
        shaders.prewarm(functions: ["fx_cursor_composite"], pixelFormat: MetalContext.workingPixelFormat)
        // present_fragment doubles as the predither (working format) and the final
        // present; the overlay drawable is rgba16Float (EDR) or bgra8Unorm (SDR), and
        // the live preview is bgra8Unorm — warm both. passthrough is used for readback.
        shaders.prewarm(functions: ["present_fragment", "passthrough_fragment"], pixelFormat: MetalContext.workingPixelFormat)
        shaders.prewarm(functions: ["present_fragment", "passthrough_fragment"], pixelFormat: .bgra8Unorm)
    }

    func shutdown() {
        for id in Array(renderers.keys) { deactivate(id) }
    }
}
