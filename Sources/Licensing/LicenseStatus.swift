import Foundation

/// The public licensing state the UI reads and the engine gates on. Computed from
/// the persisted record and the clock; never set directly.
enum LicenseStatus: Equatable, Sendable {
    /// In the free trial, with whole days left (>= 1).
    case trial(daysRemaining: Int)
    /// Trial elapsed and no valid license entered.
    case trialExpired
    /// A valid license is active.
    case licensed
    /// Licensed, but the validation server couldn't be reached to re-verify within
    /// the grace window. Still fully entitled; the UI nudges to reconnect.
    case licensedUnverified
    /// A key was entered but found invalid (e.g. refunded/revoked), with no trial left.
    case unlicensed

    /// Whether full features are unlocked. A server outage never flips this off
    /// (that is the whole point of the offline grace).
    var isEntitled: Bool {
        switch self {
        case .trial, .licensed, .licensedUnverified: true
        case .trialExpired, .unlicensed: false
        }
    }

    /// Whether to show a buy/enter-key call to action.
    var wantsPurchasePrompt: Bool {
        switch self {
        case .trial, .trialExpired, .unlicensed: true
        case .licensed, .licensedUnverified: false
        }
    }
}
