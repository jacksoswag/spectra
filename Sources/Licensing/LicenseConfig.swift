import Foundation

/// Static configuration for licensing. Centralised so the Phase 2 platform choice
/// (Lemon Squeezy vs Polar) and the real purchase URL plug in here without touching
/// any call site. Nothing in this file commits to a backend; `LicenseManager` selects
/// one via `LicenseBackendKind`.
enum LicenseConfig {
    /// How long a previously-validated license keeps working while the validation
    /// server is unreachable, so a transient outage never drops a paid copy back to
    /// the free tier. Past this window it keeps working but flags it couldn't re-verify.
    static let offlineGraceDays = 7

    /// Decided price. Shown in the trial/purchase UI.
    static let price = "$9.99"

    /// Where customers buy and manage their license.
    /// TODO(Phase 2): replace with the real Merchant-of-Record checkout URL.
    static let purchaseURL = URL(string: "https://spectra.app/buy")!

    /// Which backend validates keys. Stub until Phase 2 wires the real store.
    static let backend: LicenseBackendKind = .stub
}

enum LicenseBackendKind {
    case stub
    // case lemonSqueezy(storeID: String, productID: String)   // Phase 2
    // case polar(organizationID: String, productID: String)   // Phase 2

    func makeBackend() -> LicenseBackend {
        switch self {
        case .stub: StubLicenseBackend()
        }
    }
}
