import Foundation
@preconcurrency import Metal

/// Measured GPU cost of one effect in the active chain.
struct EffectCost: Identifiable, Sendable {
    let id: String
    let name: String
    let category: EffectCategory
    let passCount: Int
    let gpuMilliseconds: Double
}

/// A static summary of the resolved render pipeline (no GPU work).
struct PipelineSummary: Sendable {
    let effectCount: Int
    let passCount: Int
    let width: Int
    let height: Int
    /// Estimated working-set VRAM for one ping-pong pair at this resolution, MB.
    let intermediateMegabytes: Double
}

/// On-demand profiler that attributes real GPU time to each effect by encoding it
/// in isolation over a synthetic test frame and reading the command buffer's GPU
/// timestamps. Runs only when the user asks (not per frame), so it adds no cost
/// to live rendering, and produces accurate per-effect measurements.
@MainActor
final class ChainProfiler {
    private let context: MetalContext
    private let shaders: ShaderLibrary
    private let pool: TexturePool
    private let chainRenderer: EffectChainRenderer

    init(context: MetalContext, shaders: ShaderLibrary) {
        self.context = context
        self.shaders = shaders
        self.pool = TexturePool(device: context.device)
        self.chainRenderer = EffectChainRenderer(context: context, shaders: shaders, pool: pool)
    }

    /// Profile each effect in the chain, returning costs sorted most-expensive
    /// first. `iterations` measurements per effect are averaged after a warmup.
    func profile(_ chain: [ResolvedEffect], width: Int, height: Int, iterations: Int = 5) -> [EffectCost] {
        let w = min(max(width, 256), 1920)
        let h = min(max(height, 256), 1200)
        guard let input = makeTestTexture(width: w, height: h) else { return [] }

        var costs: [EffectCost] = []
        for effect in chain {
            let single = [effect]
            _ = measure(single, input: input)   // warmup (pipeline + caches)
            var total = 0.0
            for _ in 0..<max(iterations, 1) { total += measure(single, input: input) }
            let avg = total / Double(max(iterations, 1))
            costs.append(EffectCost(
                id: effect.descriptor.id, name: effect.descriptor.name,
                category: effect.descriptor.category, passCount: effect.descriptor.passes.count,
                gpuMilliseconds: avg))
        }
        return costs.sorted { $0.gpuMilliseconds > $1.gpuMilliseconds }
    }

    /// One isolated GPU pass over the test texture; returns its GPU time in ms.
    private func measure(_ chain: [ResolvedEffect], input: MTLTexture) -> Double {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return 0 }
        let frame = FrameContext(time: 1.0, frameIndex: 1)
        let result = chainRenderer.encode(into: commandBuffer, input: input, chain: chain, frame: frame, history: input)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        pool.release(result.transientTextures)
        return max(0, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0)
    }

    func summary(_ chain: [ResolvedEffect], width: Int, height: Int) -> PipelineSummary {
        let passes = chain.reduce(0) { $0 + $1.descriptor.passes.count }
        // rgba16Float = 8 bytes/px, two ping-pong targets.
        let mb = Double(width * height * 8 * 2) / (1024 * 1024)
        return PipelineSummary(
            effectCount: chain.count, passCount: passes,
            width: width, height: height, intermediateMegabytes: mb)
    }

    private func makeTestTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i + 0] = UInt8((x * 255) / max(width - 1, 1))
                bytes[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                bytes[i + 2] = UInt8(((x + y) * 127) / max(width + height - 2, 1))
                bytes[i + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }
}
