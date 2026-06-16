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
        // Hide the visible overlays and drop their buffered frames the instant a Space
        // change is detected. The overlay is opaque and click-through; left up, it can be
        // force-fronted onto the new Space (via `carryToActiveSpace`) still showing a stale
        // pre-transition frame — the "frozen Mission Control" ghost, where the menu bar and
        // Dock appear dead because they're buried under the frozen image. An animated chain
        // makes it worse: its idle redraw keeps re-presenting `lastFrame` even with no fresh
        // capture during the swipe. While hidden the display link keeps rendering fresh
        // captures into the off-screen layer, so when `followActiveSpace` re-shows them after
        // the swipe settles they are already current (no stale flash) and nothing visible can
        // snap the in-flight swipe back onto the overlay's Space. They stay in
        // `visibleDisplayIDs`, so the debounced carry below (and the tick safety net) bring
        // them back on the now-active Space.
        for id in visibleDisplayIDs {
            overlays[id]?.hide()
            renderers[id]?.discardBufferedFrames()
        }
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
        for id in visibleDisplayIDs { overlays[id]?.carryToActiveSpace() }
        // The swipe has settled: let the control windows follow to the now-active Space
        // again (migrating now can't reverse a completed gesture), and wake capture so a
        // fresh frame lands on the new Space — re-showing the overlay re-dirties it, but
        // re-issuing the content filter guarantees ScreenCaptureKit emits one.
        for window in controlWindowsProvider() {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        onActiveSpaceSettled()
    }

    /// Notification-independent safety net. `activeSpaceDidChange` doesn't reliably
    /// fire for full-screen-app Space transitions, so a periodic caller (the engine
    /// tick) re-checks and carries any overlay that has fallen off the active Space.
    /// A no-op when every overlay is already on the active Space, and suppressed while
    /// a Space transition is still settling so it can't force-front mid-swipe.
    func ensureOverlaysOnActiveSpace() {
        guard CACurrentMediaTime() > spaceSettleDeadline else { return }
        for id in visibleDisplayIDs {
            guard let overlay = overlays[id], !overlay.isOnActiveSpace else { continue }
            overlay.carryToActiveSpace()
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
