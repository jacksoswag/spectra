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

    /// Where customers buy and manage their license: the Lemon Squeezy product checkout.
    static let purchaseURL = URL(string: "https://spect-crow.lemonsqueezy.com/checkout/buy/e9a63740-558f-4cea-adf2-bf94134d3bec")!

    /// Which backend validates keys. Debug builds use `.stub`, which accepts well-formed
    /// test keys offline so the activation flow can be exercised without a store. Release
    /// builds always resolve `.lemonSqueezy` so a stub can never ship and bypass licensing.
    #if DEBUG
    static let backend: LicenseBackendKind = .stub
    #else
    static let backend: LicenseBackendKind = .lemonSqueezy
    #endif
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
