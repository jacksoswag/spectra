import Foundation

/// The result of validating a key against the licensing backend.
enum LicenseValidation: Sendable {
    case valid
    case invalid
    /// The server couldn't be reached. Distinct from `.invalid` so a transient
    /// outage falls into the offline grace path instead of revoking entitlement.
    case unreachable
}

/// Abstraction over the licensing server. Phase 2 swaps in a Lemon Squeezy / Polar
/// implementation; nothing else in the app changes because call sites depend only
/// on this protocol (and `LicenseConfig.backend` selects the concrete type).
protocol LicenseBackend: Sendable {
    func validate(key: String) async -> LicenseValidation
}

/// Offline stub used until Phase 2 connects the real Merchant-of-Record. It accepts
/// well-formed keys of the form `SPECTRA-XXXX-XXXX-XXXX` so the whole trial and
/// activation flow can be exercised end to end without a network or an account. The
/// real backend will verify the key against the store's API.
struct StubLicenseBackend: LicenseBackend {
    func validate(key: String) async -> LicenseValidation {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pattern = #"^SPECTRA(-[A-Z0-9]{4}){3}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil ? .valid : .invalid
    }
}
