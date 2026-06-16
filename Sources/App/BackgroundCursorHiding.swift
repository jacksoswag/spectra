import CoreGraphics
import Foundation

/// Lets `CGDisplayHideCursor` take effect even when Spectra is **not** the
/// frontmost application.
///
/// By default macOS only honors a cursor-hide request from the active app. That
/// is fatal for Spectra's stylized cursor: the overlay is click-through and never
/// becomes key, so whenever the synthetic cursor is being drawn the user is, by
/// definition, working in some *other* app — and the real hardware cursor stays
/// visible on top of the drawn one (the "double cursor" symptom).
///
/// Setting the window-server connection's private `SetsCursorInBackground`
/// property to true makes a subsequent `CGDisplayHideCursor` stick globally,
/// regardless of which app is frontmost. The matching `CGDisplayShowCursor`
/// restores it (the engine balances hide/show, and shows it again on disable and
/// teardown). The symbols are resolved at runtime via `dlsym` so there is no
/// link-time dependency on the private SkyLight/CoreGraphics API; if they are ever
/// unavailable, cursor hiding simply falls back to the old foreground-only
/// behavior instead of failing to launch.
enum BackgroundCursorHiding {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// Resolved once, the first time `enable()` is called. The property only needs
    /// to be set a single time per process.
    private static let didEnable: Bool = {
        // RTLD_DEFAULT searches every image already loaded into the process;
        // AppKit pulls in SkyLight, which exports these symbols.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let connectionSym = dlsym(rtldDefault, "CGSMainConnectionID")
            ?? dlsym(rtldDefault, "_CGSDefaultConnection")
        guard let connectionSym,
              let setPropertySym = dlsym(rtldDefault, "CGSSetConnectionProperty") else {
            Log.render.error("Background cursor hiding unavailable: CGS symbols not found")
            return false
        }
        let mainConnection = unsafeBitCast(connectionSym, to: MainConnectionFn.self)
        let setProperty = unsafeBitCast(setPropertySym, to: SetPropertyFn.self)
        let cid = mainConnection()
        let key = "SetsCursorInBackground" as CFString
        _ = setProperty(cid, cid, key, kCFBooleanTrue)
        return true
    }()

    /// Idempotent. Call before the first `CGDisplayHideCursor`. Returns whether the
    /// private property was set — false means the CGS symbols were unavailable and
    /// the hide will only hold while Spectra is frontmost (the old fallback).
    @discardableResult
    static func enable() -> Bool { didEnable }
}
