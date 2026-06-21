import XCTest
@testable import Spectra

/// The free/licensed tier state machine. `LicenseManager.derive` is a pure function
/// of the persisted record and the clock, so these run without files or a network.
final class LicenseManagerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoKeyIsFreeTier() {
        let status = LicenseManager.derive(record: LicenseRecord(), now: t0)
        XCTAssertEqual(status, .free)
        XCTAssertFalse(status.isLicensed)
        XCTAssertTrue(status.wantsUpgradePrompt)
    }

    func testValidLicenseIsLicensed() {
        let rec = LicenseRecord(licenseKey: "SPECTRA-AAAA-BBBB-CCCC", lastValidated: t0, lastValidationOK: true)
        let status = LicenseManager.derive(record: rec, now: t0)
        XCTAssertEqual(status, .licensed)
        XCTAssertTrue(status.isLicensed)
    }

    func testInvalidKeyFallsBackToFree() {
        let rec = LicenseRecord(licenseKey: "bad-key", lastValidationOK: false)
        XCTAssertEqual(LicenseManager.derive(record: rec, now: t0), .free)
    }

    func testOfflineGraceKeepsAccessThenFlagsButNeverLocks() {
        let rec = LicenseRecord(licenseKey: "SPECTRA-AAAA-BBBB-CCCC", lastValidated: t0, lastValidationOK: true)
        let withinGrace = t0.addingTimeInterval(Double(LicenseConfig.offlineGraceDays - 1) * day)
        XCTAssertEqual(LicenseManager.derive(record: rec, now: withinGrace), .licensed)

        let pastGrace = t0.addingTimeInterval(Double(LicenseConfig.offlineGraceDays + 2) * day)
        let status = LicenseManager.derive(record: rec, now: pastGrace)
        XCTAssertEqual(status, .licensedUnverified)
        XCTAssertTrue(status.isLicensed, "A validation-server outage must never drop a paid copy to the free tier")
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
