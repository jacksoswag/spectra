import AppKit

/// Bridges the transient menu-bar popover into the capture exceptions while it is open.
///
/// The whole Spectra app is excluded from capture so the opaque overlay can never film
/// itself; the Studio/Settings control windows are then added back as exceptions so they
/// render *through* the effect chain like any other window. The menu-bar popover was never
/// in that exception set, so it was the one Spectra surface that was neither rendered through
/// the shader nor reliably above the overlay — and it vanished whenever the overlay sat above
/// it (e.g. lifted over a full-screen Space). Every *other* app's dropdown shows because it is
/// captured and rendered through; this makes Spectra's own menu behave the same way.
///
/// The popover is a transient SwiftUI `MenuBarExtra(.window)` window whose number changes per
/// open, so it can't be registered once like a control window — it is tracked on its key /
/// resign-key transitions and excepted only while visible.
///
/// (Replaces the earlier `MenuBarPanelElevator`, a dead diagnostic that tried to raise the
/// panel by window level — which never worked, because Space membership, not level, is what
/// puts content above the lifted overlay.)
@MainActor
final class MenuPanelCaptureBridge {
    private var keyObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private weak var trackedPanel: NSWindow?

    /// Whether a window number belongs to one of Spectra's overlays (never except an overlay,
    /// or it would film its own output). Set by the engine.
    var isOverlayWindow: (Int) -> Bool = { _ in false }
    /// Whether a window is one of Spectra's tracked control windows (Studio/Settings), which
    /// are already excepted through their own registration path.
    var isControlWindow: (NSWindow) -> Bool = { _ in false }
    /// Called with the popover window when it opens (becomes key) and `nil` when it closes,
    /// so the engine can add/remove it from the capture exceptions.
    var onPanelVisibilityChanged: (NSWindow?) -> Void = { _ in }

    func start() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow,
                      !self.isOverlayWindow(window.windowNumber),
                      !self.isControlWindow(window) else { return }
                // Any non-overlay, non-control Spectra window that takes key is the popover
                // (or another transient bit of our own UI) — render it through the chain.
                self.trackedPanel = window
                self.onPanelVisibilityChanged(window)
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow,
                      window === self.trackedPanel else { return }
                // Defer the visible check: the popover is still visible at resign-key time if
                // focus only moved to a submenu (keep excepting it then); it is gone once an
                // actual dismissal has ordered it out (stop excepting it).
                DispatchQueue.main.async { [weak self, weak window] in
                    MainActor.assumeIsolated {
                        guard let self, window === self.trackedPanel else { return }
                        if !(window?.isVisible ?? false) {
                            self.trackedPanel = nil
                            self.onPanelVisibilityChanged(nil)
                        }
                    }
                }
            }
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
