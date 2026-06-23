import AppKit

extension Notification.Name {
    /// Posted when the user asks to reopen the app (Dock-icon click). The engine
    /// observes this and raises the Studio above the overlay.
    static let spectraReopen = Notification.Name("com.spectra.reopen")
}

/// Owns process-level lifecycle concerns that SwiftUI's scene system does not
/// express well: activation policy and clean teardown of GPU/capture resources.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `SpectraApp` once the engine exists, so termination can run the
    /// engine's teardown (restore the hardware cursor, stop capture/GPU work).
    /// `SwiftUI`'s scene lifecycle has no "app is quitting" hook, so this delegate
    /// is the only place that fires on ⌘Q / Quit.
    weak var engine: SpectraEngine?

    /// Held so the signal sources stay alive for the process lifetime. See
    /// `installTerminationSignalHandlers`.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug visual harness: if SPECTRA_SHADERTEST is set, render presets over test
        // images to PNGs and exit before any window/capture starts. No-op otherwise.
        // Compiled out of release builds entirely (see ShaderTestHarness.swift).
        #if DEBUG
        ShaderTestHarness.runIfRequested()
        #endif
        NSApp.setActivationPolicy(.regular)
        installTerminationSignalHandlers()
    }

    /// Run the engine teardown on a POSIX termination signal. Cocoa does NOT call
    /// `applicationWillTerminate` when the process receives SIGTERM (what `pkill`,
    /// `kill`, and Activity Monitor's "Quit" send) or SIGINT (terminal ⌃C); the
    /// default disposition kills the process outright. Without this, a `pkill -x
    /// Spectra` — exactly what the dev install script does — would strand windows at
    /// reduced opacity / tiled until the next launch's snapshot recovery. We ignore
    /// the default disposition and instead restore synchronously, then exit.
    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.engine?.shutdown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// `NSApp.terminate` does not unwind SwiftUI scenes, so without this the engine's
    /// `shutdown()` never ran on quit — leaving the hardware-cursor hide and the
    /// capture/GPU teardown unbalanced. Delegate callbacks arrive on the main thread.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { engine?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Dock-icon click. Returning true lets AppKit reopen the id'd Studio scene;
    /// the engine then raises it above the overlay (and handles the case where the
    /// window already exists but is buried behind the overlay). This is the reliable
    /// reopen path when "Cover menu bar & Dock" hides the menu-bar item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .spectraReopen, object: nil)
        return true
    }
}
