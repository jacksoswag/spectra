import Foundation

/// The licensing tier the UI reads and the app gates on. Computed from the
/// persisted record and the clock; never set directly.
///
/// There is no time-limited trial. The free tier is permanent and gated: it can
/// apply the cinematic presets (with the global intensity and quality controls) but
/// not edit, build, or reach the rest of the library. A license unlocks everything.
enum LicenseStatus: Equatable, Sendable {
    /// Gated free tier: cinematic presets only, no editing.
    case free
    /// A valid license is active: full access.
    case licensed
    /// Licensed, but the validation server couldn't be reached to re-verify within
    /// the grace window. Still fully unlocked; the UI nudges to reconnect. A server
    /// outage never drops a paid copy back to the free tier.
    case licensedUnverified

    /// Whether the paid features (editing, the full library, the composer, the
    /// non-cinematic presets, Glass) are unlocked.
    var isLicensed: Bool {
        switch self {
        case .licensed, .licensedUnverified: true
        case .free: false
        }
    }

    /// Whether to show an upgrade / buy call to action.
    var wantsUpgradePrompt: Bool { !isLicensed }
}
