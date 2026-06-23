import Foundation

/// Validates license keys against Lemon Squeezy's public license API. The
/// `/v1/licenses/validate` endpoint is keyed by the license key itself, so this needs
/// no store secret or API key. A network failure returns `.unreachable`, which the
/// offline-grace path treats as "keep the current entitlement".
///
/// Not active until `LicenseConfig.backend` is switched to `.lemonSqueezy` (which
/// needs a real Lemon Squeezy store issuing keys). The app is not sandboxed, so it
/// makes outbound requests without a network entitlement.
struct LemonSqueezyBackend: LicenseBackend {
    private static let endpoint = URL(string: "https://api.lemonsqueezy.com/v1/licenses/validate")!

    func validate(key: String) async -> LicenseValidation {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        request.httpBody = Data("license_key=\(encoded)".utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            // The response carries `"valid": true|false`; trust that over the status code
            // (Lemon Squeezy returns 400 for an unknown key, which is a definite invalid).
            struct Response: Decodable { let valid: Bool }
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                // Body present but not the shape we expect (API drift): treat as unreachable so a
                // valid key falls into offline grace instead of being revoked as invalid.
                return .unreachable
            }
            return response.valid ? .valid : .invalid
        } catch {
            return .unreachable   // network/timeout — fall into offline grace
        }
    }
}
