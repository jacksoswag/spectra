import Foundation

/// Static configuration for licensing. Centralised so the platform choice and the
/// real checkout URL plug in here without touching any call site. `LicenseManager`
/// selects a backend via `LicenseBackendKind`.
///
/// Payment platform: Lemon Squeezy (Merchant of Record), decided. The licensing layer
/// stays stubbed until the store exists; flip `backend` to `.lemonSqueezy` once there
/// is a Lemon Squeezy store + product issuing license keys, and set `purchaseURL` to
/// that product's checkout URL. Validation needs no secret API key (Lemon Squeezy's
/// `/v1/licenses/validate` is keyed by the license key itself).
enum LicenseConfig {
    /// How long a previously-validated license keeps working while the validation
    /// server is unreachable, so a transient outage never drops a paid copy back to
    /// the free tier. Past this window it keeps working but flags it couldn't re-verify.
    static let offlineGraceDays = 7

    /// Decided price. Shown in the purchase UI.
    static let price = "$9.99"

    /// Where customers buy and manage their license.
    /// TODO: set to the Lemon Squeezy product checkout URL once the store exists.
    static let purchaseURL = URL(string: "https://spectra.app/buy")!

    /// Which backend validates keys. `.stub` accepts well-formed test keys offline;
    /// switch to `.lemonSqueezy` when real keys exist (no other code changes needed).
    static let backend: LicenseBackendKind = .stub
}

enum LicenseBackendKind {
    case stub
    case lemonSqueezy

    func makeBackend() -> LicenseBackend {
        switch self {
        case .stub: StubLicenseBackend()
        case .lemonSqueezy: LemonSqueezyBackend()
        }
    }
}
