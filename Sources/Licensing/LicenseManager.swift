import Foundation
import Observation

/// On-disk license record. Plain JSON (no HWID, no obfuscation) — at this price,
/// plain license keys are the right tradeoff (see the ship plan's piracy note).
struct LicenseRecord: Codable, Equatable, Sendable {
    var licenseKey: String? = nil
    /// Last SUCCESSFUL online validation, for the offline-grace window.
    var lastValidated: Date? = nil
    /// Whether the stored key validated as genuine on its last check.
    var lastValidationOK: Bool = false
}

/// The self-contained licensing layer: a permanent gated free tier (cinematic presets
/// only) plus license activation with an offline grace window so a validation-server
/// outage never drops a paid copy back to the free tier. The concrete backend is
/// selected by `LicenseConfig.backend` and stubbed until Phase 2, so call sites never
/// change.
@MainActor
@Observable
final class LicenseManager {
    private(set) var status: LicenseStatus

    /// Set when an entitlement gate blocked an action (trial expired / unlicensed),
    /// so the UI can present the purchase prompt. The UI clears it on dismiss.
    var gatePrompted = false

    /// Set when the on-disk license write fails (disk full / bad permissions), so the UI can
    /// warn that an activation may not survive a relaunch. Cleared on the next successful write.
    private(set) var persistError: String?

    @ObservationIgnored private var record: LicenseRecord
    @ObservationIgnored private let backend: LicenseBackend
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = { Date() },
         backend: LicenseBackend = LicenseConfig.backend.makeBackend()) {
        self.now = now
        self.backend = backend
        let loaded = JSONStore.load(LicenseRecord.self, from: AppPaths.licenseFile) ?? LicenseRecord()
        self.record = loaded
        self.status = Self.developerUnlock ? .licensed : Self.derive(record: loaded, now: now())
    }

    var isLicensed: Bool { status.isLicensed }
    var licenseKey: String? { record.licenseKey }

    /// Owner/developer unlock: a hidden sentinel file forces the licensed tier on this
    /// Mac without the purchase flow (see AppPaths.developerUnlockFile). Compiled in for
    /// DEBUG only — a release build always returns false, so the sentinel can't be used
    /// to bypass licensing on a shipped copy. Delete the file to test the gated free tier.
    static var developerUnlock: Bool {
        #if DEBUG
        FileManager.default.fileExists(atPath: AppPaths.developerUnlockFile.path)
        #else
        false
        #endif
    }

    /// Pure status derivation from a record + a clock. Kept static, nonisolated, and
    /// side-effect free so it is trivially unit-testable (free vs licensed, grace).
    nonisolated static func derive(record: LicenseRecord, now: Date) -> LicenseStatus {
        guard let key = record.licenseKey, !key.isEmpty, record.lastValidationOK else { return .free }
        // No recorded validation timestamp: unlocked but flagged for re-verification rather than
        // claiming a fully-verified license (a key was stored but a success was never timestamped).
        guard let last = record.lastValidated else { return .licensedUnverified }
        let graceEnd = last.addingTimeInterval(Double(LicenseConfig.offlineGraceDays) * 86_400)
        return now > graceEnd ? .licensedUnverified : .licensed   // past grace: unlocked, flag re-verify
    }

    /// Recompute `status` from the record and clock (no network). The developer-unlock
    /// sentinel forces the licensed tier.
    func recompute() {
        status = Self.developerUnlock ? .licensed : Self.derive(record: record, now: now())
    }

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

    /// Write the record to disk, surfacing failures rather than swallowing them: a lost write
    /// means a just-activated key silently vanishes on next launch, so the UI is told.
    private func persist() {
        do {
            try JSONStore.save(record, to: AppPaths.licenseFile)
            // Owner-only perms: the file holds the license key. Best-effort; a chmod failure
            // shouldn't fail the write itself.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.licenseFile.path)
            persistError = nil
        } catch {
            persistError = error.localizedDescription
            Log.storage.error("License write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
