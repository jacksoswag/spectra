import XCTest
@testable import Spectra

/// Persistence round-trips for the user-facing document types, plus the uniform
/// layout parity the CPU and GPU both depend on.
final class PersistenceTests: XCTestCase {
    func testBuiltInPresetRoundTrips() throws {
        let preset = try XCTUnwrap(BuiltInPresets.all.first)
        let decoded = try JSONStore.decode(Preset.self, from: JSONStore.encode(preset))
        XCTAssertEqual(decoded.name, preset.name)
        XCTAssertEqual(decoded.category, preset.category)
        XCTAssertEqual(decoded.chain.effects.count, preset.chain.effects.count)
    }

    func testEveryBuiltInPresetEncodesAndDecodes() throws {
        for preset in BuiltInPresets.all {
            let decoded = try JSONStore.decode(Preset.self, from: JSONStore.encode(preset))
            XCTAssertEqual(decoded.chain.effects.count, preset.chain.effects.count, "\(preset.name) lost effects")
        }
    }

    func testSpectraDocumentRoundTrips() throws {
        let preset = try XCTUnwrap(BuiltInPresets.all.first)
        let doc = SpectraDocument.preset(preset)
        let decoded = try JSONStore.decode(SpectraDocument.self, from: JSONStore.encode(doc))
        XCTAssertEqual(decoded.kind, doc.kind)
        XCTAssertEqual(decoded.preset?.name, preset.name)
    }

    func testUniformLayoutParity() {
        // Must match `float params[64]` and the 80-float struct in SpectraCommon.h.
        XCTAssertEqual(SpectraUniforms.paramSlotCount, 64)
        XCTAssertEqual(SpectraUniforms.floatCount, 80)
    }
}
