import Foundation
import CoreGraphics
import AppKit

/// Screen-recording authorization state. Capture cannot begin until this is
/// authorized. The first call to `request()` surfaces the system prompt;
/// thereafter the user must grant access in System Settings.
enum ScreenRecordingPermission {
    /// Current authorization without prompting.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Request access, surfacing the system prompt if undetermined. Returns the
    /// resulting authorization. Safe to call repeatedly.
    @discardableResult
    static func request() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Open the Screen Recording pane in System Settings.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
