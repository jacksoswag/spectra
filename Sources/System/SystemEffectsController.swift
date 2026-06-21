import Foundation
import CoreGraphics

/// Resolved parameters for the Window Transparency system effect.
struct TransparencySettings: Equatable, Sendable {
    var activeOpacity: Double
    var normalOpacity: Double
    var blur: Double

    init(activeOpacity: Double, normalOpacity: Double, blur: Double) {
        self.activeOpacity = activeOpacity
        self.normalOpacity = normalOpacity
        self.blur = blur
    }

    init(_ instance: EffectInstance) {
        activeOpacity = instance.value("activeOpacity", default: .scalar(0.85)).scalarValue ?? 0.85
        normalOpacity = instance.value("normalOpacity", default: .scalar(0.90)).scalarValue ?? 0.90
        blur = instance.value("blur", default: .scalar(0)).scalarValue ?? 0
    }

    /// The values the menu-bar Glass toggle applies.
    static let glass = TransparencySettings(activeOpacity: 0.75, normalOpacity: 0.70, blur: 0)
}

/// Resolved parameters for the Window Layout system effect.
struct LayoutSettings: Equatable, Sendable {
    var layout: Int
    var gap: Double
    var padding: Double

    init(_ instance: EffectInstance) {
        layout = instance.value("layout", default: .index(0)).indexValue ?? 0
        gap = instance.value("gap", default: .scalar(8)).scalarValue ?? 8
        padding = instance.value("padding", default: .scalar(8)).scalarValue ?? 8
    }
}

/// Resolved parameters for the Adaptive Tint system effect.
struct TintSettings: Equatable, Sendable {
    var strength: Double
    var smoothing: Double

    init(strength: Double, smoothing: Double) {
        self.strength = strength
        self.smoothing = smoothing
    }

    init(_ instance: EffectInstance) {
        strength = instance.value("strength", default: .scalar(1.0)).scalarValue ?? 1.0
        smoothing = instance.value("smoothing", default: .scalar(0.5)).scalarValue ?? 0.5
    }

    /// The values the menu-bar Glass toggle applies.
    static let glass = TintSettings(strength: 1.0, smoothing: 0.5)
}

/// The desired aggregate state of every system effect. `nil` means that effect is off.
struct SystemEffectsState: Equatable, Sendable {
    var transparency: TransparencySettings?
    var layout: LayoutSettings?
    var tint: TintSettings?

    static let inactive = SystemEffectsState()
}

/// Owns the runtime side of the system effects: the yabai bridge (window
/// transparency + layout) and the adaptive tint overlay. The engine hands it a
/// desired `SystemEffectsState`; this diffs against what is currently applied and
/// activates, updates, or restores each subsystem. Restoring on the off-transition,
/// on master disable, and on quit is what keeps a window from being left dimmed.
@MainActor
final class SystemEffectsController {
    private let yabai = YabaiBridge()
    private let provisioner = YabaiProvisioner()
    let tint = AdaptiveTintOverlay()
    private var lastState = SystemEffectsState.inactive
    private var lastDisplayIDs: [CGDirectDisplayID] = []
    private var retiredGlassAgent = false
    private var clearedStaleOpacity = false
    private var provisioningInFlight = false
    private var lastProvisionStatus: YabaiProvisioner.Status = .unknown

    /// Latest yabai provisioning status, pushed out so the inspector can reflect the
    /// install / admin-prompt / SIP / ready state on the yabai-backed rows.
    var onStatusChanged: ((YabaiProvisioner.Status) -> Void)?
    /// Forwarded from the tint overlay so the engine re-issues the capture filter.
    var onCaptureExceptionsChanged: (() -> Void)? {
        get { tint.onWindowsChanged }
        set { tint.onWindowsChanged = newValue }
    }

    /// Window numbers of the live tint windows, for the capture filter exceptions.
    var tintWindowNumbers: [Int] { tint.windowNumbers }

    init() {
        // Recover a snapshot left by a previous run that didn't exit cleanly, so a
        // crash never strands the user's windows at reduced opacity.
        yabai.restoreFromDiskIfDirty()
    }

    /// Re-probe yabai's state read-only (no install, no prompt) and report it out, for the
    /// inspector. Skipped while active provisioning is mid-flight so it can't clobber a live
    /// "installing"/"authorizing" status.
    func refreshStatus(needsOpacity: Bool) {
        guard !provisioningInFlight else { return }
        provisioner.probe(needsOpacity: needsOpacity) { status in
            MainActor.assumeIsolated {
                self.lastProvisionStatus = status
                self.onStatusChanged?(status)
            }
        }
    }

    /// Make yabai "just work" when a yabai-backed effect is active: install it via Homebrew
    /// if missing, start the service, and (for opacity) load the scripting addition behind
    /// one admin prompt. The config applies self-guard on availability, so they re-run once
    /// provisioning reports ready. Idempotent and prompt-free after the first successful run.
    private func ensureYabai(needsOpacity: Bool) {
        if provisioningInFlight { return }
        if lastProvisionStatus == .opacityReady { return }
        if !needsOpacity, lastProvisionStatus == .ready { return }
        provisioningInFlight = true
        provisioner.provision(needsOpacity: needsOpacity) { status in
            MainActor.assumeIsolated {
                self.lastProvisionStatus = status
                self.onStatusChanged?(status)
                switch status {
                case .ready, .opacityReady:
                    self.provisioningInFlight = false
                    self.reapplyYabaiConfig()
                case .failed, .sipRequired:
                    self.provisioningInFlight = false
                default:
                    break   // installing / starting / authorizing: stay in flight
                }
            }
        }
    }

    /// Re-push the current desired yabai config after provisioning makes the service ready.
    private func reapplyYabaiConfig() {
        if let transparency = lastState.transparency {
            yabai.applyTransparency(active: transparency.activeOpacity,
                                    normal: transparency.normalOpacity, blurRadius: transparency.blur)
        }
        if let layout = lastState.layout {
            yabai.applyLayout(layout: layout.layout, gap: layout.gap, padding: layout.padding)
        }
    }

    /// Reconcile every subsystem to `state`. Idempotent: unchanged effects are left alone.
    func apply(_ state: SystemEffectsState, displayIDs: [CGDirectDisplayID]) {
        lastDisplayIDs = displayIDs

        // The standalone Glass.app (os-mods/adaptive-menubar) drives the same yabai
        // opacity and draws its own desktop tint, so retire its login agent once Spectra
        // takes over either job. This only stops the current session's instance (a
        // reversible `launchctl bootout`); it deletes nothing.
        if !retiredGlassAgent, state.transparency != nil || state.tint != nil {
            retiredGlassAgent = true
            Self.retireGlassAgent()
        }

        // Window transparency (yabai opacity + blur).
        if let next = state.transparency {
            if lastState.transparency != next {
                yabai.applyTransparency(active: next.activeOpacity, normal: next.normalOpacity, blurRadius: next.blur)
            }
        } else if lastState.transparency != nil || !clearedStaleOpacity {
            // Restore on the on->off transition, and once at startup, so window opacity left
            // behind by a prior unclean exit (or an earlier build) is cleared even when there's
            // no snapshot to restore from.
            yabai.restoreTransparency()
        }
        clearedStaleOpacity = true

        // Window layout (yabai tiling).
        if let next = state.layout {
            if lastState.layout != next {
                yabai.applyLayout(layout: next.layout, gap: next.gap, padding: next.padding)
            }
        } else if lastState.layout != nil {
            yabai.restoreLayout()
        }

        // Adaptive tint overlay.
        if let next = state.tint {
            if lastState.tint == nil {
                tint.activate(strength: next.strength, smoothing: next.smoothing, displayIDs: displayIDs)
            } else if lastState.tint != next {
                tint.update(strength: next.strength, smoothing: next.smoothing)
            }
        } else if lastState.tint != nil {
            tint.deactivate()
        }

        // Provision yabai on demand when a yabai-backed effect is active.
        if state.transparency != nil || state.layout != nil {
            ensureYabai(needsOpacity: state.transparency != nil)
        }

        lastState = state
    }

    /// Restore everything to the user's prior state (master disable).
    func deactivateAll() {
        apply(.inactive, displayIDs: lastDisplayIDs)
    }

    /// Quit-time teardown: remove the tint windows and synchronously restore yabai so
    /// the process can exit without leaving windows dimmed or tiled.
    func shutdown() {
        tint.deactivate()
        yabai.shutdownRestore()
        provisioner.stopServiceIfStarted()
        lastState = .inactive
    }

    /// Rebuild tint windows for a changed display set (hot-plug, geometry change).
    func refreshDisplays(_ displayIDs: [CGDirectDisplayID]) {
        lastDisplayIDs = displayIDs
        tint.refreshGeometry(displayIDs: displayIDs)
    }

    /// Stop the standalone Glass.app login agent for this session so it can't fight
    /// Spectra over yabai opacity or double up the desktop tint. Best-effort and
    /// reversible: `bootout` only unloads the running instance, it removes no files.
    private static func retireGlassAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/com.jacksonadams.adaptivemenubar"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
