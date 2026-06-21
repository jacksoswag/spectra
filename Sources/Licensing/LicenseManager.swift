import Foundation
import Observation

/// On-disk license record. Plain JSON (no HWID, no obfuscation) — at this price,
/// plain license keys are the right tradeoff (see the ship plan's piracy note).
struct LicenseRecord: Codable, Equatable, Sendable {
    var trialStart: Date?
    var licenseKey: String?
    /// Last SUCCESSFUL online validation, for the offline-grace window.
    var lastValidated: Date?
    /// Whether the stored key validated as genuine on its last check.
    var lastValidationOK: Bool = false
}

/// The self-contained licensing layer: a 14-day no-account full trial, offline
/// validation with a grace window so a server outage never bricks a paid copy, and
/// a clean interface the app gates on. The concrete backend is selected by
/// `LicenseConfig.backend` and stubbed until Phase 2, so call sites never change.
@MainActor
@Observable
final class LicenseManager {
    private(set) var status: LicenseStatus

    /// Set when an entitlement gate blocked an action (trial expired / unlicensed),
    /// so the UI can present the purchase prompt. The UI clears it on dismiss.
    var gatePrompted = false

    @ObservationIgnored private var record: LicenseRecord
    @ObservationIgnored private let backend: LicenseBackend
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = { Date() },
         backend: LicenseBackend = LicenseConfig.backend.makeBackend()) {
        self.now = now
        self.backend = backend
        var loaded = JSONStore.load(LicenseRecord.self, from: AppPaths.licenseFile) ?? LicenseRecord()
        // Start the trial clock on the first ever launch.
        if loaded.trialStart == nil, loaded.licenseKey == nil {
            loaded.trialStart = now()
            try? JSONStore.save(loaded, to: AppPaths.licenseFile)
        }
        self.record = loaded
        self.status = Self.derive(record: loaded, now: now())
    }

    var isEntitled: Bool { status.isEntitled }
    var licenseKey: String? { record.licenseKey }
    var trialDaysRemaining: Int {
        if case let .trial(days) = status { return days }
        return 0
    }

    /// Pure status derivation from a record + a clock. Kept static and side-effect
    /// free so it is trivially unit-testable (trial countdown, expiry, grace).
    static func derive(record: LicenseRecord, now: Date) -> LicenseStatus {
        if let key = record.licenseKey, !key.isEmpty {
            guard record.lastValidationOK else { return .unlicensed }
            if let last = record.lastValidated {
                let graceEnd = last.addingTimeInterval(Double(LicenseConfig.offlineGraceDays) * 86_400)
                if now > graceEnd { return .licensedUnverified }   // entitled, but flag re-verify
            }
            return .licensed
        }
        let start = record.trialStart ?? now
        let daysUsed = Int(now.timeIntervalSince(start) / 86_400)
        let remaining = LicenseConfig.trialDays - daysUsed
        return remaining > 0 ? .trial(daysRemaining: remaining) : .trialExpired
    }

    /// Recompute `status` from the record and clock (no network).
    func recompute() { status = Self.derive(record: record, now: now()) }

    /// Validate and store a license key. Returns whether it was accepted.
    @discardableResult
    func activate(key: String) async -> Bool {
        switch await backend.validate(key: key) {
        case .valid:
            record.licenseKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            record.lastValidated = now()
            record.lastValidationOK = true
            persist(); recompute(); gatePrompted = false
            return true
        case .invalid:
            record.licenseKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            record.lastValidationOK = false
            persist(); recompute()
            return false
        case .unreachable:
            return false   // don't store a key we couldn't verify
        }
    }

    /// Re-verify the stored key online (e.g. on launch). An unreachable server never
    /// downgrades entitlement; that is the offline grace.
    func refresh() async {
        guard let key = record.licenseKey, !key.isEmpty else { recompute(); return }
        switch await backend.validate(key: key) {
        case .valid:
            record.lastValidated = now(); record.lastValidationOK = true; persist()
        case .invalid:
            record.lastValidationOK = false; persist()
        case .unreachable:
            break
        }
        recompute()
    }

    /// Remove the stored license (returns to trial/expired per the clock).
    func deactivate() {
        record.licenseKey = nil
        record.lastValidated = nil
        record.lastValidationOK = false
        persist(); recompute()
    }

    /// Called by the entitlement gate when a blocked action is attempted.
    func promptGate() { gatePrompted = true }

    private func persist() { try? JSONStore.save(record, to: AppPaths.licenseFile) }
}
