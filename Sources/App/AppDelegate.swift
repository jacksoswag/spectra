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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // TEMP build-verification marker: writes which build is actually running to a file,
        // so we can confirm the launched binary contains the latest source (os_log was not
        // surfacing; a file is unambiguous). Remove once the build pipeline is trusted.
        let marker = "FS-OWNSPACE build launched=\(Date())"
        try? marker.write(toFile: "/tmp/spectra-build-check.txt", atomically: true, encoding: .utf8)
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
