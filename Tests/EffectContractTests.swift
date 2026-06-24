import XCTest
@testable import Spectra

/// The data-driven effect contract: descriptor ids are unique, parameters fit the
/// fixed GPU uniform layout, and non-system effects carry at least one GPU pass.
final class EffectContractTests: XCTestCase {
    private let all = BuiltInEffects.all()

    func testEffectIDsAreUnique() {
        let ids = all.map(\.id)
        let dupes = Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys
        XCTAssertTrue(dupes.isEmpty, "Duplicate effect ids: \(Array(dupes))")
    }

    func testParameterSlotsFitUniformLayout() {
        for descriptor in all {
            let slots = descriptor.parameters.reduce(0) { $0 + $1.componentCount }
            XCTAssertLessThanOrEqual(
                slots, SpectraUniforms.paramSlotCount,
                "\(descriptor.id) needs \(slots) param slots > the \(SpectraUniforms.paramSlotCount)-slot uniform array")
        }
    }

    func testNonSystemEffectsHaveAPass() {
        for descriptor in all where !descriptor.isSystemEffect {
            XCTAssertFalse(descriptor.passes.isEmpty, "\(descriptor.id) has no GPU pass")
        }
    }

    func testSystemEffectsHaveNoPasses() {
        for descriptor in all where descriptor.isSystemEffect {
            XCTAssertTrue(descriptor.passes.isEmpty, "\(descriptor.id) is a controller effect and must carry no GPU passes")
        }
    }

    func testEffectCountIsPinned() {
        // The number pinned in README / ARCHITECTURE / the UI. Update all together.
        // 209 total = 203 non-system (GPU-pass) effects + 6 system controllers.
        XCTAssertEqual(all.count, 209)
    }
}
