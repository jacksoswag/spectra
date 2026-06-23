import AppKit

/// Relaunches Spectra in a fresh process. macOS often won't deliver capture frames
/// to a running app after Screen Recording is toggled in System Settings (as opposed
/// to granted via the in-app prompt), so the permission UI offers a relaunch to make
/// the new grant take effect.
enum AppRelaunch {
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            // The new instance is launching; quit this one once it's on its way.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
