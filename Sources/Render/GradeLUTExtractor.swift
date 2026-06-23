import Foundation
import CoreGraphics
import Metal

/// Turns a per-channel color chain into a 256-entry display transfer LUT by
/// rendering the *actual* resolved chain on a gray ramp through the same
/// `EffectChainRenderer` the overlay uses.
///
/// Because it reuses the real render path, the resulting LUT matches the engine's
/// look exactly — no CPU re-implementation of the shader math, no drift, and it
/// picks up universal strength/opacity/blend and the master intensity for free.
///
/// Valid ONLY for per-channel-separable effects (the caller gates this): for those,
/// a gray input fully characterises each channel's transfer, so the table reproduces
/// the effect on arbitrary colors. Cross-channel ops (saturation, hue, matrices, and
/// temperature/tint's luma-preservation term) are NOT separable and must not be
/// routed here — a gray ramp would not capture their color behaviour.
@MainActor
final class GradeLUTExtractor {
    private let context: MetalContext
    private let pool: TexturePool
    private let chainRenderer: EffectChainRenderer

    /// Ramp width = LUT resolution. Several rows are averaged to cancel the
    /// renderer's predither noise (zero-mean), so the table comes out smooth.
    private let width = 256
    private let rows = 8

    private var rampTexture: MTLTexture?
    private var readbackTexture: MTLTexture?

    init(context: MetalContext, shaders: ShaderLibrary) {
        self.context = context
        self.pool = TexturePool(device: context.device)
        self.chainRenderer = EffectChainRenderer(context: context, shaders: shaders, pool: pool)
    }

    /// Render `chain` on a gray ramp and read back its per-channel transfer.
    /// `intensityScale` mirrors the master intensity slider so the global grade
    /// tracks it like the overlay does. Returns nil on any GPU failure (the caller
    /// then leaves the chain on the overlay path).
    ///
    /// - Important: This blocks the calling thread on GPU completion via `waitUntilCompleted`.
    func extract(chain: [ResolvedEffect], intensityScale: Float) -> DisplayGrade.LUT? {
        guard !chain.isEmpty,
              let ramp = ramp(), let readback = readback(),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return nil }

        var frame = FrameContext(time: 0, frameIndex: 0)
        frame.intensityScale = intensityScale
        let result = chainRenderer.encode(into: commandBuffer, input: ramp, chain: chain, frame: frame)

        // Color passes run at scale 1, so the output should match the ramp size. If
        // anything resized it, bail (the caller keeps the chain on the overlay).
        guard result.outputTexture.width == width, result.outputTexture.height == rows,
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            pool.release(result.transientTextures)
            return nil
        }
        // Copy the (private pool) output into a CPU-readable texture in the same buffer.
        blit.copy(from: result.outputTexture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: rows, depth: 1),
                  to: readback,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        pool.release(result.transientTextures)
        guard commandBuffer.status == .completed else { return nil }

        return readLUT(from: readback)
    }

    // MARK: - Textures

    private func ramp() -> MTLTexture? {
        if let rampTexture { return rampTexture }
        guard let tex = makeTexture(usage: [.shaderRead]) else { return nil }
        var pixels = [Float16](repeating: 0, count: width * rows * 4)
        for y in 0..<rows {
            for x in 0..<width {
                let v = Float16(Float(x) / Float(width - 1))
                let i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = Float16(1)
            }
        }
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, rows),
                        mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 4 * 2)
        }
        rampTexture = tex
        return tex
    }

    private func readback() -> MTLTexture? {
        if let readbackTexture { return readbackTexture }
        readbackTexture = makeTexture(usage: [])
        return readbackTexture
    }

    private func makeTexture(usage: MTLTextureUsage) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.workingPixelFormat, width: width, height: rows, mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        return context.device.makeTexture(descriptor: d)
    }

    private func readLUT(from tex: MTLTexture) -> DisplayGrade.LUT {
        var pixels = [Float16](repeating: 0, count: width * rows * 4)
        pixels.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: width * 4 * 2,
                         from: MTLRegionMake2D(0, 0, width, rows), mipmapLevel: 0)
        }
        var red = [CGGammaValue](repeating: 0, count: width)
        var green = [CGGammaValue](repeating: 0, count: width)
        var blue = [CGGammaValue](repeating: 0, count: width)
        let n = Float(rows)
        for x in 0..<width {
            var sr: Float = 0, sg: Float = 0, sb: Float = 0
            for y in 0..<rows {
                let i = (y * width + x) * 4
                sr += Float(pixels[i]); sg += Float(pixels[i + 1]); sb += Float(pixels[i + 2])
            }
            red[x]   = CGGammaValue(min(1, max(0, sr / n)))
            green[x] = CGGammaValue(min(1, max(0, sg / n)))
            blue[x]  = CGGammaValue(min(1, max(0, sb / n)))
        }
        return DisplayGrade.LUT(red: red, green: green, blue: blue)
    }
}
