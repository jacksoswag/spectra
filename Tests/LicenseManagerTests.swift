import XCTest
@testable import Spectra

/// The trial / license state machine. `LicenseManager.derive` is a pure function of
/// the persisted record and the clock, so these run without files or a network.
final class LicenseManagerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFreshTrialHasFullDaysAndIsEntitled() {
        let status = LicenseManager.derive(record: LicenseRecord(trialStart: t0), now: t0)
        XCTAssertEqual(status, .trial(daysRemaining: LicenseConfig.trialDays))
        XCTAssertTrue(status.isEntitled)
    }

    func testTrialCountsDownByWholeDays() {
        let status = LicenseManager.derive(record: LicenseRecord(trialStart: t0),
                                           now: t0.addingTimeInterval(3 * day))
        XCTAssertEqual(status, .trial(daysRemaining: LicenseConfig.trialDays - 3))
    }

    func testTrialExpiresAfterWindow() {
        let after = t0.addingTimeInterval(Double(LicenseConfig.trialDays) * day + 1)
        let status = LicenseManager.derive(record: LicenseRecord(trialStart: t0), now: after)
        XCTAssertEqual(status, .trialExpired)
        XCTAssertFalse(status.isEntitled)
    }

    func testValidLicenseIsEntitled() {
        let rec = LicenseRecord(licenseKey: "SPECTRA-AAAA-BBBB-CCCC", lastValidated: t0, lastValidationOK: true)
        XCTAssertEqual(LicenseManager.derive(record: rec, now: t0), .licensed)
    }

    func testInvalidKeyIsUnlicensed() {
        let rec = LicenseRecord(licenseKey: "bad-key", lastValidationOK: false)
        let status = LicenseManager.derive(record: rec, now: t0)
        XCTAssertEqual(status, .unlicensed)
        XCTAssertFalse(status.isEntitled)
    }

    func testOfflineGraceKeepsEntitlementThenFlagsButNeverBricks() {
        let rec = LicenseRecord(licenseKey: "SPECTRA-AAAA-BBBB-CCCC", lastValidated: t0, lastValidationOK: true)
        let withinGrace = t0.addingTimeInterval(Double(LicenseConfig.offlineGraceDays - 1) * day)
        XCTAssertEqual(LicenseManager.derive(record: rec, now: withinGrace), .licensed)

        let pastGrace = t0.addingTimeInterval(Double(LicenseConfig.offlineGraceDays + 2) * day)
        let status = LicenseManager.derive(record: rec, now: pastGrace)
        XCTAssertEqual(status, .licensedUnverified)
        XCTAssertTrue(status.isEntitled, "A validation-server outage must never brick a paid copy")
    }

    func testStubBackendAcceptsWellFormedKeysOnly() async {
        let backend = StubLicenseBackend()
        let valid = await backend.validate(key: "SPECTRA-AAAA-BBBB-CCCC")
        XCTAssertEqual(valid, .valid)
        let validLower = await backend.validate(key: "spectra-aaaa-bbbb-cccc")  // case-insensitive
        XCTAssertEqual(validLower, .valid)
        let invalid = await backend.validate(key: "nope")
        XCTAssertEqual(invalid, .invalid)
    }
}
