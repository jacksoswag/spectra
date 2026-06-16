import AppKit
import Observation

/// Surfaces the real macOS system accessibility display settings. macOS applies
/// these to the whole screen, so they're genuine accessibility — unlike a shader
/// that only touches Spectra's overlay. macOS exposes a public way to *read* some
/// of these states (and notifies on change) but no public way to *toggle* them
/// from code, so each feature deep-links to the exact System Settings pane.
@MainActor
@Observable
final class SystemAccessibility {
    /// A system accessibility feature surfaced in Settings.
    struct Feature: Identifiable {
        let id: String
        let name: String
        let detail: String
        let icon: String
        /// Current on/off state when macOS exposes a public reader; nil otherwise.
        var isOn: Bool?
        /// System Settings URL that opens the pane where this is toggled.
        let settingsURL: String
    }

    private(set) var features: [Feature] = []
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        refresh()
        // macOS posts this whenever any accessibility display option changes, so the
        // shown states stay live while the user flips them in System Settings.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Re-read the publicly readable accessibility states from `NSWorkspace`.
    func refresh() {
        let ws = NSWorkspace.shared
        // Top-level panes open reliably across macOS versions; the user lands on the
        // right pane and flips the toggle there.
        let accessibility = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
        let displays = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        features = [
            Feature(id: "increaseContrast", name: "Increase Contrast",
                    detail: "Boost contrast system-wide for legibility.",
                    icon: "circle.lefthalf.filled",
                    isOn: ws.accessibilityDisplayShouldIncreaseContrast, settingsURL: accessibility),
            Feature(id: "invertColors", name: "Invert Colors",
                    detail: "Reverse the display's colors.",
                    icon: "circle.righthalf.filled",
                    isOn: ws.accessibilityDisplayShouldInvertColors, settingsURL: accessibility),
            Feature(id: "reduceMotion", name: "Reduce Motion",
                    detail: "Minimize on-screen animation.",
                    icon: "figure.walk.motion",
                    isOn: ws.accessibilityDisplayShouldReduceMotion, settingsURL: accessibility),
            Feature(id: "reduceTransparency", name: "Reduce Transparency",
                    detail: "Make window backgrounds more opaque.",
                    icon: "square.on.square",
                    isOn: ws.accessibilityDisplayShouldReduceTransparency, settingsURL: accessibility),
            Feature(id: "colorFilters", name: "Color Filters / Grayscale",
                    detail: "Grayscale and color-blindness filters.",
                    icon: "camera.filters",
                    isOn: nil, settingsURL: accessibility),
            Feature(id: "nightShift", name: "Night Shift",
                    detail: "Warm the display for evening comfort.",
                    icon: "moon.stars",
                    isOn: nil, settingsURL: displays),
        ]
    }

    /// Open the System Settings pane for a feature, falling back to the Accessibility
    /// root if the URL can't be opened on this macOS version.
    func open(_ feature: Feature) {
        let fallback = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!
        guard let url = URL(string: feature.settingsURL) else {
            NSWorkspace.shared.open(fallback); return
        }
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.open(fallback) }
    }
}
