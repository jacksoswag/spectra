import AppKit
import CoreGraphics

/// Thin wrapper over the window-server (SkyLight / CoreGraphics-Services) Space SPIs used
/// to make the overlay appear OVER another app's native-fullscreen window.
///
/// Why this is hard: a native-fullscreen app owns an isolated Space, and macOS guards it —
/// `.transient` is suppressed there, `.canJoinAllSpaces`/`.fullScreenAuxiliary` never extend
/// to it, a high `NSWindow.level` (even `CGShieldingWindowLevel`) does NOT composite over it,
/// and `CGSMoveWindowsToManagedSpace` silently refuses to relocate a foreign window into it.
/// All verified on-device.
///
/// What works (the technique AltTab / Hammerspoon / SkyLightWindow use): create our OWN
/// managed Space, raise ITS absolute level above the fullscreen compositing band, show it,
/// and add the overlay window to it. macOS allows this because the destination Space is one
/// we own — not the fullscreen app's. The overlay then composites over the fullscreen app,
/// and because it is a separate elevated Space (not an all-Spaces pin) it does not merge the
/// user's desktops; removing the window restores normal behavior.
///
/// Every symbol is resolved at runtime via `dlsym` (both modern `SLS` and legacy `CGS`
/// names), so there is no link-time dependency. If anything is missing, the elevation is a
/// no-op and the engine falls back to the AppKit carry (fullscreen just stays unshaded).
@MainActor
final class SpaceManager {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpaceTypeFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    private let mainConnection: MainConnFn?
    private let currentSpace: CurrentSpaceFn?
    private let spaceType: SpaceTypeFn?
    private let spacesForWindows: SpacesForWindowsFn?
    private let spaceCreate: SpaceCreateFn?
    private let setAbsoluteLevel: SetAbsoluteLevelFn?
    private let showSpaces: ShowSpacesFn?
    private let addWindows: AddWindowsFn?

    /// Type returned by `…SpaceGetType` for an ordinary user Space. Anything else
    /// (fullscreen, tiled, system) is treated as needing explicit elevation.
    private static let userSpaceType: Int32 = 0
    /// Absolute level for our created Space: above ScreenLock (300), so above the
    /// native-fullscreen compositing band. (300 would keep it below the lock screen.)
    private static let elevatedAbsoluteLevel: Int32 = 400
    /// Selector for `…SpaceAddWindowsAndRemoveFromSpaces` (add to the target Space and
    /// remove from all others) — the magic constant from the reference implementation.
    private static let addAndRemoveSelector: Int32 = 7

    /// Our created elevated Space (made once, reused for every overlay window).
    private var elevatedSpaceID: UInt64?
    private static let maxProbeLines = 40
    private var probeLines = 0

    init() {
        let rtld = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        func resolve(_ names: [String]) -> UnsafeMutableRawPointer? {
            for name in names { if let sym = dlsym(rtld, name) { return sym } }
            return nil
        }
        mainConnection = resolve(["SLSMainConnectionID", "CGSMainConnectionID", "_CGSDefaultConnection"])
            .map { unsafeBitCast($0, to: MainConnFn.self) }
        currentSpace = resolve(["SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"])
            .map { unsafeBitCast($0, to: CurrentSpaceFn.self) }
        spaceType = resolve(["SLSSpaceGetType", "CGSSpaceGetType"])
            .map { unsafeBitCast($0, to: SpaceTypeFn.self) }
        spacesForWindows = resolve(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"])
            .map { unsafeBitCast($0, to: SpacesForWindowsFn.self) }
        spaceCreate = resolve(["SLSSpaceCreate", "CGSSpaceCreate"])
            .map { unsafeBitCast($0, to: SpaceCreateFn.self) }
        setAbsoluteLevel = resolve(["SLSSpaceSetAbsoluteLevel", "CGSSpaceSetAbsoluteLevel"])
            .map { unsafeBitCast($0, to: SetAbsoluteLevelFn.self) }
        showSpaces = resolve(["SLSShowSpaces", "CGSShowSpaces"])
            .map { unsafeBitCast($0, to: ShowSpacesFn.self) }
        addWindows = resolve(["SLSSpaceAddWindowsAndRemoveFromSpaces", "CGSSpaceAddWindowsAndRemoveFromSpaces"])
            .map { unsafeBitCast($0, to: AddWindowsFn.self) }
        if spaceCreate == nil || addWindows == nil || showSpaces == nil || setAbsoluteLevel == nil {
            Log.render.error("SpaceManager: elevated-Space SPIs unavailable; fullscreen overlay won't be shaded.")
        }
    }

    /// Whether the Space currently shown on `displayID` is something other than an ordinary
    /// user Space (a native-fullscreen app's Space, most importantly), where the overlay must
    /// be lifted into our elevated Space to be visible.
    func activeSpaceNeedsExplicitPlacement(displayID: CGDirectDisplayID) -> Bool {
        guard let mainConnection, let currentSpace, let spaceType,
              let uuid = displayUUID(displayID) else { return false }
        let cid = mainConnection()
        let sid = currentSpace(cid, uuid)
        guard sid != 0 else { return false }
        let type = spaceType(cid, sid)
        probe("space display=\(displayID) sid=\(sid) type=\(type) needsPlacement=\(type != Self.userSpaceType)")
        return type != Self.userSpaceType
    }

    /// Lift the window into our own elevated Space so it composites over the fullscreen app.
    /// Creates the Space on first use and reuses it thereafter.
    func placeWindowAboveFullscreen(_ windowNumber: Int) {
        guard windowNumber > 0, let mainConnection, let addWindows,
              let sid = ensureElevatedSpace() else { return }
        let cid = mainConnection()
        // Re-show in case the Space's show-state was reset by a display/fullscreen transition.
        showSpaces?(cid, [sid] as CFArray)
        addWindows(cid, sid, [windowNumber] as CFArray, Self.addAndRemoveSelector)
        probe("ELEVATE window=\(windowNumber) -> ownSpace=\(sid); onSpaces=\(spaceIDs(forWindow: windowNumber, cid: cid))")
    }

    /// Drop the window back onto the display's current (ordinary) Space, removing it from our
    /// elevated Space so AppKit's normal single-Space follow takes over again.
    func restoreWindowToActiveSpace(_ windowNumber: Int, displayID: CGDirectDisplayID) {
        guard windowNumber > 0, let mainConnection, let addWindows, let currentSpace,
              let uuid = displayUUID(displayID) else { return }
        let cid = mainConnection()
        let userSid = currentSpace(cid, uuid)
        guard userSid != 0 else { return }
        addWindows(cid, userSid, [windowNumber] as CFArray, Self.addAndRemoveSelector)
        probe("RESTORE window=\(windowNumber) -> userSpace=\(userSid); onSpaces=\(spaceIDs(forWindow: windowNumber, cid: cid))")
    }

    private func ensureElevatedSpace() -> UInt64? {
        if let elevatedSpaceID { return elevatedSpaceID }
        guard let mainConnection, let spaceCreate, let setAbsoluteLevel, let showSpaces else { return nil }
        let cid = mainConnection()
        let sid = spaceCreate(cid, 1, 0)
        guard sid != 0 else { Log.render.error("SpaceManager: SLSSpaceCreate returned 0"); return nil }
        _ = setAbsoluteLevel(cid, sid, Self.elevatedAbsoluteLevel)
        showSpaces(cid, [sid] as CFArray)
        elevatedSpaceID = sid
        probe("CREATE elevated space sid=\(sid) level=\(Self.elevatedAbsoluteLevel)")
        return sid
    }

    private func spaceIDs(forWindow windowNumber: Int, cid: Int32) -> [UInt64] {
        guard let spacesForWindows,
              let array = spacesForWindows(cid, 0x7, [windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return array.map { $0.uint64Value }
    }

    private func displayUUID(_ displayID: CGDirectDisplayID) -> CFString? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid)
    }

    private func probe(_ line: String) {
        guard probeLines < Self.maxProbeLines else { return }
        probeLines += 1
        let path = "/tmp/spectra-space-probe.txt"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
