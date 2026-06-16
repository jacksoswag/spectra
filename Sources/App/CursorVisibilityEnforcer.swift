import AppKit
import CoreGraphics
import QuartzCore

/// Keeps the hardware cursor hidden while the stylized cursor is drawn — except over
/// the menu bar and its dropdowns, where the rendered cursor can't reach (those float
/// above the overlay) and so the real hardware cursor is shown instead. Everything
/// else, Spectra's own Studio/Settings included, sits below the overlay and gets the
/// rendered cursor.
///
/// The discriminator is a hit-test: on each motion, the topmost on-screen window under
/// the pointer is found via `CGWindowList` (purely geometric, so the click-through
/// overlay still counts). If it's an overlay → hide the hardware cursor (rendered
/// cursor shows); if it's anything above the overlay (a menu/dropdown) → show the
/// hardware cursor. Crucially, over a menu we show *once* and do not toggle — toggling
/// while a menu/popover tracks fights its own cursor handling and can leave the cursor
/// stuck on dismiss.
///
/// Two monitors are needed: a global one for motion over *other* apps, and a local one
/// for motion over Spectra's own key windows (Studio/Settings, the menu panel) — which
/// the global monitor doesn't see and which would otherwise re-show the hardware cursor
/// and double it over the rendered one.
///
/// The counted hide is tracked by `cgHidden` and kept in {0, 1}: applied at most once,
/// removed at most once, and the over-overlay re-assert is a balanced show+hide pair,
/// so a single show always restores the cursor and it can never get stuck invisible.
@MainActor
final class CursorVisibilityEnforcer {
    private var engaged = false
    private var cgHidden = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Throttle the `CGWindowList` query to ~60/s; reuse the last decision in between so
    /// fast motion doesn't spam a synchronous window-server round-trip per event.
    private var lastHitTestTime: Double = 0
    private var lastPointerOverOverlay = true
    private static let hitTestInterval = 1.0 / 60.0

    /// Whether a window number belongs to one of Spectra's overlays. Set by the engine.
    /// Until it is, "over the overlay" is assumed so the rendered-cursor case holds.
    var isOverlayWindow: ((Int) -> Bool)?

    /// Pointer motions an app uses to re-assert its own cursor. Drags are included so
    /// the hide also holds while a button is held down.
    private static let motionMask: NSEvent.EventTypeMask =
        [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    /// Drive the engaged state. Idempotent.
    func setHidden(_ shouldHide: Bool) {
        shouldHide ? engage() : disengage()
    }

    private func engage() {
        if engaged { reevaluate(); return }
        engaged = true
        let backgroundHideHolds = BackgroundCursorHiding.enable()
        reevaluate()   // hide or show based on where the pointer is now
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.motionMask) { [weak self] event in
            MainActor.assumeIsolated { self?.onMotion() }
            return event
        }
        // Re-asserting over *other* apps only helps when the hide can stick in the
        // background; without that private property it can't hold there anyway.
        guard backgroundHideHolds else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.motionMask) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMotion() }
        }
    }

    private func disengage() {
        guard engaged else { return }
        engaged = false
        for monitor in [globalMonitor, localMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMonitor = nil
        localMonitor = nil
        applyShow()
    }

    private func onMotion() {
        guard engaged else { return }
        if pointerIsOverOverlay() {
            applyHide()
            reassert()   // fight the foreground app's re-show on this same motion
        } else {
            applyShow()  // menu bar / open dropdown: show the real cursor, no toggling
        }
    }

    /// Apply the current location's desired state without the motion re-assert.
    private func reevaluate() {
        guard engaged else { return }
        pointerIsOverOverlay() ? applyHide() : applyShow()
    }

    private func applyHide() {
        guard !cgHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        cgHidden = true
    }

    private func applyShow() {
        guard cgHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        cgHidden = false
    }

    /// Re-hide after another app re-showed the cursor on motion over the overlay. The
    /// show+hide pair keeps the counted hide pinned at one (1 → 0 → 1).
    private func reassert() {
        guard cgHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        CGDisplayHideCursor(CGMainDisplayID())
    }

    /// Whether the topmost on-screen window under the pointer is one of Spectra's
    /// overlays. `CGWindowList` is geometric (reports the visually-frontmost window
    /// regardless of the overlay being click-through). Throttled.
    private func pointerIsOverOverlay() -> Bool {
        guard let isOverlayWindow else { return true }
        let now = CACurrentMediaTime()
        if now - lastHitTestTime < Self.hitTestInterval { return lastPointerOverOverlay }
        lastHitTestTime = now
        // `CGEvent.location` is already in the top-left-origin space `kCGWindowBounds` uses.
        guard let point = CGEvent(source: nil)?.location,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return lastPointerOverOverlay }
        for window in windows {   // front-to-back: first containing window is topmost
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.contains(point) else { continue }
            guard let number = window[kCGWindowNumber as String] as? Int else { continue }
            lastPointerOverOverlay = isOverlayWindow(number)
            return lastPointerOverOverlay
        }
        lastPointerOverOverlay = false   // nothing under the pointer — show the real cursor
        return false
    }
}
