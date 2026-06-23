import Foundation
import AppKit
import ScreenCaptureKit
import Observation

/// Enumerates connected displays and bridges AppKit/ScreenCaptureKit metadata.
/// Also caches the `SCShareableContent` needed to build capture filters and the
/// app's own `SCRunningApplication` (used to exclude Spectra's windows from
/// capture, preventing feedback loops).
@MainActor
@Observable
final class DisplayManager {
    private(set) var displays: [DisplayInfo] = []
    private(set) var permissionAuthorized: Bool = ScreenRecordingPermission.isAuthorized
    private(set) var lastError: String?

    @ObservationIgnored private var scDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    @ObservationIgnored private(set) var selfApplication: SCRunningApplication?

    /// Notified after the display set changes (hot-plug, resolution change).
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }
    }

    /// Match this process inside the shareable content. Prefer the exact process id
    /// (unambiguous); fall back to the bundle id. ScreenCaptureKit display capture
    /// ignores `NSWindow.sharingType = .none`, so this is the *only* thing keeping
    /// Spectra's own overlay out of the capture — if it returns nil the overlay
    /// captures itself and feeds back, re-rendering the whole chain every frame.
    private static func resolveSelf(in content: SCShareableContent) -> SCRunningApplication? {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let byPID = content.applications.first(where: { $0.processID == pid }) { return byPID }
        let bundleID = Bundle.main.bundleIdentifier
        return content.applications.first { $0.bundleIdentifier == bundleID }
    }

    /// The application(s) to exclude from a capture filter — i.e. Spectra itself.
    /// Re-resolves once if bootstrap raced window registration and left it nil, so a
    /// capture never starts without self-exclusion (which would feed back).
    func captureExclusions() async -> [SCRunningApplication] {
        if selfApplication == nil { await refresh() }
        return selfApplication.map { [$0] } ?? []
    }

    /// Fresh `SCWindow`s whose window numbers are in `windowNumbers` — Spectra's own
    /// control windows (Studio/Settings) — so a capture filter can make exceptions to
    /// include them while the rest of the app (crucially the overlay) stays excluded.
    /// Re-fetches shareable content so windows opened since the last refresh are present.
    ///
    /// If a just-registered window hasn't been reported on-screen yet (so not all
    /// numbers resolve), retries once after a short delay — otherwise that window,
    /// sitting below the opaque overlay, would render as a hole until an unrelated
    /// refresh fixes it.
    func shareableWindows(matching windowNumbers: Set<Int>) async -> [SCWindow] {
        guard !windowNumbers.isEmpty else { return [] }
        var matches = await fetchShareableWindows(matching: windowNumbers)
        if matches.count < windowNumbers.count {
            try? await Task.sleep(nanoseconds: 100_000_000)   // ~100ms for the window to register
            let retried = await fetchShareableWindows(matching: windowNumbers)
            if retried.count > matches.count { matches = retried }
        }
        return matches
    }

    private func fetchShareableWindows(matching windowNumbers: Set<Int>) async -> [SCWindow] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        } catch {
            // Screen Recording may have been revoked mid-session. Surface it (lastError +
            // re-checked permission) instead of silently returning no windows — which would
            // leave control windows rendering as holes with no UI signal.
            permissionAuthorized = ScreenRecordingPermission.isAuthorized
            lastError = error.localizedDescription
            Log.capture.error("Shareable-windows fetch failed (Screen Recording revoked?): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func scDisplay(for id: CGDirectDisplayID) -> SCDisplay? { scDisplays[id] }

    func display(for id: CGDirectDisplayID) -> DisplayInfo? { displays.first { $0.id == id } }

    var mainDisplay: DisplayInfo? { displays.first { $0.isMain } ?? displays.first }

    /// Refresh the display list. Displays are enumerated from AppKit (no
    /// permission needed) so the Studio is usable for browsing and wallpaper
    /// preview before access is granted. ScreenCaptureKit content is fetched
    /// separately to map capture sources and record authorization; capture only
    /// runs once that succeeds.
    func refresh() async {
        let mainID = CGMainDisplayID()
        displays = NSScreen.screens
            .compactMap { screen -> DisplayInfo? in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                else { return nil }
                return build(from: screen, id: id, isMain: id == mainID)
            }
            .sorted { ($0.isMain ? 0 : 1, $0.frame.minX) < ($1.isMain ? 0 : 1, $1.frame.minX) }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            permissionAuthorized = true
            lastError = nil
            selfApplication = Self.resolveSelf(in: content)
            var map: [CGDirectDisplayID: SCDisplay] = [:]
            for display in content.displays { map[display.displayID] = display }
            scDisplays = map
        } catch {
            permissionAuthorized = ScreenRecordingPermission.isAuthorized
            lastError = error.localizedDescription
        }

        onChange?()
    }

    private func build(from screen: NSScreen, id: CGDirectDisplayID, isMain: Bool) -> DisplayInfo {
        let scale = screen.backingScaleFactor
        let frame = screen.frame
        let pixelWidth = Int((frame.width * scale).rounded())
        let pixelHeight = Int((frame.height * scale).rounded())
        let refresh = Double(screen.maximumFramesPerSecond)
        let edrHeadroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        return DisplayInfo(
            id: id, name: screen.localizedName, frame: frame,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            scale: scale, refreshRate: max(refresh, 60), isMain: isMain,
            maxEDRHeadroom: edrHeadroom)
    }
}
