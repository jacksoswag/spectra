import XCTest
import Metal
@testable import Spectra

/// The chain resolver expands the editable chain into render-ready effects and drops
/// disabled ones. Needs a Metal device for the aux-texture factory, so it skips on a
/// headless host without one. The resolver and registry are main-actor types.
@MainActor
final class ChainResolverTests: XCTestCase {
    private func makeResolver() throws -> (ChainResolver, EffectRegistry) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available (headless run)")
        }
        let registry = EffectRegistry()
        let resolver = ChainResolver(registry: registry, composedStore: nil,
                                     auxFactory: AuxTextureFactory(device: device))
        return (resolver, registry)
    }

    func testResolverDropsDisabledEffects() throws {
        let (resolver, registry) = try makeResolver()
        let descriptor = try XCTUnwrap(registry.descriptors.first { !$0.isSystemEffect })

        let enabled = EffectInstance(descriptor: descriptor)
        var disabled = EffectInstance(descriptor: descriptor)
        disabled.isEnabled = false

        let withoutDisabled = resolver.resolve(EffectChain(effects: [enabled]))
        let withDisabled = resolver.resolve(EffectChain(effects: [enabled, disabled]))

        XCTAssertFalse(withoutDisabled.isEmpty, "an enabled effect should resolve")
        XCTAssertEqual(withDisabled.count, withoutDisabled.count, "a disabled effect must not contribute")
    }

    func testResolverDropsUnknownDescriptors() throws {
        let (resolver, _) = try makeResolver()
        let unknown = EffectInstance(descriptorID: "definitely.not.a.real.effect")
        XCTAssertTrue(resolver.resolve(EffectChain(effects: [unknown])).isEmpty)
    }
}
